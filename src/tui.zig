const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const document = @import("document.zig");
const file_icon = @import("file_icon.zig");
const review = @import("review.zig");
const raw_split = @import("raw_split.zig");
const terminal = @import("terminal.zig");
const text_selection = @import("text_selection.zig");

pub const Color = struct { r: u8, g: u8, b: u8 };

pub const Theme = struct {
    foreground: Color = .{ .r = 220, .g = 220, .b = 224 },
    background: Color = .{ .r = 20, .g = 19, .b = 28 },
    accent: Color = .{ .r = 176, .g = 169, .b = 255 },
    removed: Color = .{ .r = 255, .g = 112, .b = 122 },
    added: Color = .{ .r = 91, .g = 224, .b = 135 },
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: *std.process.Environ.Map, state: *review.Review, theme: Theme) !void {
    var buffer: [4096]u8 = undefined;
    var session = try terminal.Session.init(io, allocator, environ, &buffer);
    defer session.deinit();
    var view: View = .{ .state = state, .theme = theme, .session = &session };
    try session.app.run(view.widget(), .{});
}

const Focus = enum { tree, content };
const DialogChoice = enum { cancel, quit };
const ScrollbarAxis = enum { vertical, horizontal };
const Divider = enum { outer, inner };
const stats_row: u16 = 2;
const body_top: u16 = stats_row + 2;
const min_tree_content: u16 = 10;
const min_diff_content: u16 = 14;
// A raw side needs five cells for its line-number gutter and one for source text.
const min_raw_side: u16 = 6;
const SelectionSource = enum { before, after, fallback, document };
const ContentSelection = struct {
    source: SelectionSource,
    origin: text_selection.Cell,
    target: text_selection.Cell,
    active: bool = false,
    dragging: bool = true,
};
const SelectionArea = struct {
    x: usize,
    width: usize,
    vertical: usize,
    horizontal: usize,
};
const Layout = struct {
    outer: u16,
    right_start: u16,
    right_width: u16,
    before_width: u16,
    inner: u16,
    after_start: u16,
    after_width: u16,
};

const View = struct {
    state: *review.Review,
    theme: Theme,
    session: *terminal.Session,
    focus: Focus = .tree,
    tree_scroll: usize = 0,
    reveal_selection: bool = true,
    dialog: bool = false,
    dialog_choice: DialogChoice = .cancel,
    scrollbar_visible: bool = false,
    horizontal_scrollbar_visible: bool = false,
    scrollbar_hide_ticks: u8 = 0,
    scrollbar_dragging: ?ScrollbarAxis = null,
    divider_dragging: ?Divider = null,
    outer_divider: ?u16 = null,
    inner_width: ?u16 = null,
    selection: ?ContentSelection = null,
    width: u16 = 80,
    height: u16 = 24,

    fn layout(self: *const View) Layout {
        const outer = std.math.clamp(self.outer_divider orelse treeWidth(self.width) + 1, min_tree_content + 1, self.width - min_diff_content - 2);
        const right_start = outer + 1;
        const right_width = self.width - right_start - 1;
        const before_width = std.math.clamp(self.inner_width orelse right_width / 2, min_raw_side, right_width - min_raw_side - 1);
        const inner = right_start + before_width;
        return .{
            .outer = outer,
            .right_start = right_start,
            .right_width = right_width,
            .before_width = before_width,
            .inner = inner,
            .after_start = inner + 1,
            .after_width = right_width - before_width - 1,
        };
    }

    fn resizeDivider(self: *View, divider: Divider, column: usize) void {
        const layout_now = self.layout();
        switch (divider) {
            .outer => self.outer_divider = @intCast(std.math.clamp(column, min_tree_content + 1, @as(usize, self.width - min_diff_content - 2))),
            .inner => self.inner_width = @intCast(std.math.clamp(column -| layout_now.right_start, min_raw_side, @as(usize, layout_now.right_width - min_raw_side - 1))),
        }
    }

    fn widget(self: *View) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(userdata: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *View = @ptrCast(@alignCast(userdata));
        if (self.dialog and std.meta.activeTag(value) != .tick) return self.handleDialog(ctx, value);
        switch (value) {
            .key_press => |key| {
                if (key.matches('q', .{})) return self.quit(ctx);
                if (key.matches(vaxis.Key.escape, .{})) {
                    if (self.focus == .content) {
                        self.focus = .tree;
                    } else {
                        self.dialog = true;
                        self.dialog_choice = .cancel;
                    }
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.focus = if (self.focus == .tree) .content else .tree;
                } else if (key.matches('m', .{})) {
                    self.state.toggleMode();
                    self.selection = null;
                    self.focus = .content;
                } else if (self.focus == .tree) {
                    self.selection = null;
                    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                        try self.state.moveDown();
                        self.reveal_selection = true;
                    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                        try self.state.moveUp();
                        self.reveal_selection = true;
                    } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
                        try self.collapseOrFocusParent();
                    } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
                        try self.expandFolder();
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (self.state.currentNode()) |node| {
                            if (node.kind == .folder) try self.toggleSelectedFolder() else self.focus = .content;
                        }
                    } else if (key.matches('c', .{})) {
                        try self.toggleSelectedFolder();
                    } else return;
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{}) or key.matches(vaxis.Key.page_down, .{})) {
                    self.state.scrollDown(if (key.matches(vaxis.Key.page_down, .{})) 10 else 1);
                    try self.revealScrollbar(ctx, .vertical);
                } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{}) or key.matches(vaxis.Key.page_up, .{})) {
                    self.state.scrollUp(if (key.matches(vaxis.Key.page_up, .{})) 10 else 1);
                    try self.revealScrollbar(ctx, .vertical);
                } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
                    self.state.panRight(1);
                    try self.revealScrollbar(ctx, .horizontal);
                } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
                    self.state.panLeft(1);
                    try self.revealScrollbar(ctx, .horizontal);
                } else return;
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| try self.handleMouse(ctx, mouse),
            .tick => self.expireScrollbar(ctx),
            .winsize => ctx.consumeAndRedraw(),
            else => {},
        }
    }

    fn toggleSelectedFolder(self: *View) !void {
        const node = self.state.currentNode() orelse return;
        if (node.kind == .folder) {
            try self.state.toggleFolder(self.state.cursor.?);
            self.reveal_selection = true;
            return;
        }
        const index = self.parentFolder(self.state.cursor.?) orelse return;
        try self.state.toggleFolder(index);
        self.reveal_selection = true;
    }

    fn parentFolder(self: *View, child_index: usize) ?usize {
        const child = self.state.nodes[child_index];
        var parent: ?usize = null;
        for (self.state.nodes, 0..) |node, index| {
            if (node.kind != .folder) continue;
            if (child.path.len > node.path.len and
                std.mem.startsWith(u8, child.path, node.path) and
                child.path[node.path.len] == '/')
            {
                if (parent == null or node.depth > self.state.nodes[parent.?].depth) parent = index;
            }
        }
        return parent;
    }

    fn collapseOrFocusParent(self: *View) !void {
        const node = self.state.currentNode() orelse return;
        if (node.kind == .folder and node.expanded) {
            try self.state.toggleFolder(self.state.cursor.?);
        } else if (self.parentFolder(self.state.cursor.?)) |parent| {
            try self.state.focusNode(parent);
        }
        self.reveal_selection = true;
    }

    fn expandFolder(self: *View) !void {
        const node = self.state.currentNode() orelse return;
        if (node.kind == .folder and !node.expanded) try self.state.toggleFolder(self.state.cursor.?);
        self.reveal_selection = true;
    }

    fn quit(self: *View, ctx: *vxfw.EventContext) !void {
        ctx.quit = true;
        try self.session.wakeInputOnQuit();
    }

    fn handleDialog(self: *View, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        switch (value) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.escape, .{}) or key.matches('n', .{})) {
                    self.dialog = false;
                } else if (key.matches('y', .{})) {
                    self.dialog = false;
                    return self.quit(ctx);
                } else if (key.matches(vaxis.Key.left, .{})) {
                    self.dialog_choice = .cancel;
                } else if (key.matches(vaxis.Key.right, .{})) {
                    self.dialog_choice = .quit;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.dialog_choice == .quit) {
                        self.dialog = false;
                        return self.quit(ctx);
                    }
                    self.dialog = false;
                } else return ctx.consumeEvent();
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| {
                if (mouse.type != .press or mouse.button != .left or mouse.col < 0 or mouse.row < 0) return ctx.consumeEvent();
                const choice = dialogGeometry(self.width, self.height);
                const x: u16 = @intCast(mouse.col);
                const y: u16 = @intCast(mouse.row);
                if (y == choice.buttons_row and x >= choice.cancel and x < choice.cancel + 8) {
                    self.dialog = false;
                } else if (y == choice.buttons_row and x >= choice.confirm and x < choice.confirm + 6) {
                    self.dialog = false;
                    return self.quit(ctx);
                }
                ctx.consumeAndRedraw();
            },
            else => {},
        }
    }

    fn handleMouse(self: *View, ctx: *vxfw.EventContext, value: vaxis.Mouse) !void {
        if (self.width < 32 or self.height < 8) return;
        // Drag events need temporary row data without retaining it for the viewer's lifetime.
        var memory = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        if (value.button == .left and (value.type == .press or value.type == .drag or value.type == .release)) {
            if (self.divider_dragging) |divider| {
                self.resizeDivider(divider, if (value.col < 0) 0 else @intCast(value.col));
                if (value.type == .release) self.divider_dragging = null;
                ctx.consumeAndRedraw();
                return;
            }
            if (value.type == .press and value.col >= 0 and value.row >= 1 and value.row < self.height - 1) {
                const x: u16 = @intCast(value.col);
                const geometry = self.layout();
                if (x == geometry.outer) {
                    self.divider_dragging = .outer;
                } else if (x == geometry.inner and value.row >= body_top and !self.onHorizontalScrollbar(value)) {
                    if (self.state.currentState()) |state| {
                        if (state.mode == .raw) {
                            const rows = try self.state.visibleRows(arena);
                            if (rows.len != 0 and rows[0].kind != .fallback) self.divider_dragging = .inner;
                        }
                    }
                }
                if (self.divider_dragging != null) {
                    self.selection = null;
                    if (self.divider_dragging == .inner) self.focus = .content;
                    ctx.consumeAndRedraw();
                    return;
                }
            }
        }
        if (value.button == .left and (value.type == .drag or value.type == .release)) {
            if (self.selection) |*selection| {
                if (selection.dragging) {
                    try self.updateSelection(ctx, arena, value);
                    ctx.consumeAndRedraw();
                    return;
                }
            }
        }
        if (value.button == .left and (value.type == .press or value.type == .drag or value.type == .release) and
            (self.scrollbar_dragging == .horizontal or (value.type == .press and self.onHorizontalScrollbar(value))))
        {
            const column: usize = if (value.col < 0) 0 else @intCast(value.col);
            try self.scrollFromHorizontalScrollbar(ctx, column);
            self.scrollbar_dragging = if (value.type == .release) null else .horizontal;
            self.focus = .content;
            ctx.consumeAndRedraw();
            return;
        }
        if (value.button == .left and (value.type == .press or value.type == .drag or value.type == .release) and
            (self.scrollbar_dragging == .vertical or (value.type == .press and value.col >= 0 and @as(usize, @intCast(value.col)) == self.width - 2 and self.scrollbar_visible)))
        {
            const row: usize = if (value.row < body_top) body_top else @min(@as(usize, @intCast(value.row)), self.height - 2);
            try self.scrollFromScrollbar(ctx, row);
            self.scrollbar_dragging = if (value.type == .release) null else .vertical;
            self.focus = .content;
            ctx.consumeAndRedraw();
            return;
        }
        if (value.col < 0 or value.row < 0) return;
        const x: usize = @intCast(value.col);
        const y: usize = @intCast(value.row);
        const outer = self.layout().outer;
        if (value.button == .wheel_down or value.button == .wheel_up) {
            if (x <= outer) {
                if (value.button == .wheel_down) self.tree_scroll +|= 1 else self.tree_scroll -|= 1;
                self.focus = .tree;
                self.reveal_selection = false;
            } else {
                if (value.button == .wheel_down) self.state.scrollDown(1) else self.state.scrollUp(1);
                self.focus = .content;
                try self.revealScrollbar(ctx, .vertical);
            }
            ctx.consumeAndRedraw();
            return;
        }
        if ((value.button == .wheel_left or value.button == .wheel_right) and x > outer) {
            if (value.button == .wheel_left) self.state.panRight(3) else self.state.panLeft(3);
            self.focus = .content;
            try self.revealScrollbar(ctx, .horizontal);
            ctx.consumeAndRedraw();
            return;
        }
        if (value.type != .press or value.button != .left) return;
        self.selection = null;
        if (x < outer and y >= 1 and y < self.height - 1) {
            const visible = try self.state.visibleNodes(arena);
            const index = self.tree_scroll + y - 1;
            if (index < visible.len) {
                const node_index = visible[index];
                const node = self.state.nodes[node_index];
                if (node.kind == .folder) {
                    try self.state.toggleFolder(node_index);
                } else try self.state.focusNode(node_index);
                self.reveal_selection = true;
            }
            self.focus = .tree;
        } else if (x > outer) {
            self.focus = .content;
            if (y >= body_top and y < self.height - 1) {
                if (self.state.currentState()) |state| {
                    if (state.mode == .raw and try self.state.toggleFold(state.raw_scroll.vertical + y - body_top)) {
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
                if (try self.selectionSourceAt(arena, x)) |source| {
                    if (try self.selectionHit(arena, source, x, y, false)) |point| {
                        self.selection = .{ .source = source, .origin = point, .target = point };
                    }
                }
            }
        }
        ctx.consumeAndRedraw();
    }

    fn onHorizontalScrollbar(self: *View, mouse: vaxis.Mouse) bool {
        if (!self.horizontal_scrollbar_visible or self.width < 32 or self.height < 8 or mouse.col < 0 or mouse.row < 0) return false;
        const x: usize = @intCast(mouse.col);
        const y: usize = @intCast(mouse.row);
        return x >= self.layout().right_start and x < self.width - 1 and y == self.height - 2;
    }

    fn selectionSourceAt(self: *View, arena: std.mem.Allocator, x: usize) !?SelectionSource {
        const state = self.state.currentState() orelse return null;
        const source: SelectionSource = if (state.mode == .document and state.document != null)
            .document
        else blk: {
            const rows = try self.state.visibleRows(arena);
            if (rows.len == 0 or rows[0].kind == .fallback) break :blk .fallback;
            const after = self.selectionArea(.after) orelse return null;
            break :blk if (x >= after.x) .after else .before;
        };
        const area = self.selectionArea(source) orelse return null;
        if (x < area.x or x >= area.x + area.width) return null;
        return source;
    }

    fn selectionArea(self: *View, source: SelectionSource) ?SelectionArea {
        if (self.width < 32 or self.height < 8) return null;
        const state = self.state.currentState() orelse return null;
        const geometry = self.layout();
        const raw = state.raw_scroll;
        return switch (source) {
            .document => .{ .x = geometry.right_start, .width = geometry.right_width, .vertical = state.document_scroll.vertical, .horizontal = state.document_scroll.horizontal },
            .fallback => .{ .x = geometry.right_start, .width = geometry.right_width, .vertical = raw.vertical, .horizontal = raw.horizontal },
            .before => .{ .x = geometry.right_start + 5, .width = geometry.before_width -| 5, .vertical = raw.vertical, .horizontal = raw.horizontal },
            .after => .{ .x = geometry.after_start + 5, .width = geometry.after_width -| 5, .vertical = raw.vertical, .horizontal = raw.horizontal },
        };
    }

    fn selectionLines(self: *View, arena: std.mem.Allocator, source: SelectionSource) std.mem.Allocator.Error!?[]const ?[]const u8 {
        const state = self.state.currentState() orelse return null;
        if (source == .document) {
            const data = state.document orelse return null;
            if (state.mode != .document) return null;
            const parsed = document.parse(arena, data) catch |err| switch (err) {
                error.InvalidDocumentText => return null,
                else => return error.OutOfMemory,
            };
            const lines = try arena.alloc(?[]const u8, parsed.lines.len);
            for (parsed.lines, 0..) |line, index| {
                var joined: std.ArrayList(u8) = .empty;
                for (line.spans) |span| try joined.appendSlice(arena, span.text);
                lines[index] = try joined.toOwnedSlice(arena);
            }
            return lines;
        }
        if (state.mode != .raw) return null;
        const rows = self.state.visibleRows(arena) catch |err| switch (err) {
            error.NoSelectedFile => return null,
            else => return error.OutOfMemory,
        };
        const is_fallback = rows.len == 0 or rows[0].kind == .fallback;
        if ((source == .fallback) != is_fallback) return null;
        const lines = try arena.alloc(?[]const u8, rows.len);
        for (rows, 0..) |row, index| {
            const side = switch (source) {
                .before, .fallback => row.before,
                .after => row.after,
                .document => unreachable,
            };
            lines[index] = if (side) |value| try safeDisplay(arena, value.text) else null;
        }
        return lines;
    }

    fn selectionHit(self: *View, arena: std.mem.Allocator, source: SelectionSource, x: usize, y: usize, clamp: bool) !?text_selection.Cell {
        const area = self.selectionArea(source) orelse return null;
        if (area.width == 0) return null;
        const lines = (try self.selectionLines(arena, source)) orelse return null;
        if (lines.len == 0) return null;
        const screen_row = @max(@as(usize, body_top), @min(y, self.height - 2));
        const index = area.vertical + screen_row - body_top;
        if (index >= lines.len and !clamp) return null;
        const row = @min(index, lines.len - 1);
        const line = lines[row] orelse return null;
        const column = area.horizontal + @min(x -| area.x, area.width - 1);
        return text_selection.hit(line, row, column);
    }

    fn updateSelection(self: *View, ctx: *vxfw.EventContext, arena: std.mem.Allocator, mouse: vaxis.Mouse) !void {
        const selection = if (self.selection) |*value| value else return;
        const x: usize = if (mouse.col < 0) 0 else @intCast(mouse.col);
        const y: usize = if (mouse.row < 0) 0 else @intCast(mouse.row);
        if (try self.selectionHit(arena, selection.source, x, y, true)) |target| {
            const lines = (try self.selectionLines(arena, selection.source)) orelse return;
            const selected = text_selection.range(selection.origin, target);
            if ((try text_selection.extract(arena, lines, selected)) != null) {
                selection.target = target;
                selection.active = selection.origin.row != target.row or selection.origin.start != target.start;
            } else selection.active = false;
        } else selection.active = false;
        if (mouse.type == .release) {
            selection.dragging = false;
            if (selection.active) {
                const lines = (try self.selectionLines(arena, selection.source)) orelse return;
                if (try text_selection.extract(arena, lines, text_selection.range(selection.origin, selection.target))) |text_value| {
                    try ctx.copyToClipboard(text_value);
                }
            }
        }
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *View = @ptrCast(@alignCast(userdata));
        const size: vxfw.Size = .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height orelse ctx.min.height };
        self.width = size.width;
        self.height = size.height;
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.width < 32 or size.height < 8) {
            try putText(ctx.arena, surface, 1, @min(size.height -| 1, 2), size.width -| 2, 0, "Terminal too small", .{ .fg = rgb(self.theme.accent) });
            return surface;
        }
        // Resizing a pane or selecting another file can shrink the valid horizontal range.
        try self.clampHorizontalScroll(ctx.arena);
        const geometry = self.layout();
        const foreground: vaxis.Style = .{ .fg = rgb(self.theme.foreground) };
        const accent: vaxis.Style = .{ .fg = rgb(self.theme.accent), .bold = true };
        const inactive: vaxis.Style = .{ .fg = rgb(self.theme.foreground), .dim = true };
        drawBox(surface, 0, geometry.outer, 0, size.height - 1, if (self.focus == .tree and !self.dialog) accent else inactive);
        drawBox(surface, geometry.outer, size.width - 1, 0, size.height - 1, if (self.focus == .content and !self.dialog) accent else inactive);
        const divider_style: vaxis.Style = if (self.divider_dragging == .outer)
            .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true }
        else
            accent;
        for (1..size.height - 1) |row| surface.writeCell(geometry.outer, @intCast(row), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = divider_style });
        surface.writeCell(geometry.outer, 0, .{ .char = .{ .grapheme = "┬", .width = 1 }, .style = accent });
        surface.writeCell(geometry.outer, size.height - 1, .{ .char = .{ .grapheme = "┴", .width = 1 }, .style = accent });
        try self.drawTree(ctx.arena, surface, geometry.outer - 1);
        if (self.state.currentFile()) |file| {
            try putText(ctx.arena, surface, geometry.right_start, 0, geometry.right_width, 0, file.display_path, if (self.focus == .content) accent else foreground);
            const added = try std.fmt.allocPrint(ctx.arena, "+{d}", .{file.added_lines});
            const removed = try std.fmt.allocPrint(ctx.arena, "-{d}", .{file.removed_lines});
            try putText(ctx.arena, surface, geometry.right_start, stats_row, geometry.right_width, 0, added, .{ .fg = rgb(self.theme.added), .bold = true });
            const stats_offset: u16 = @intCast(@min(added.len + 1, geometry.right_width));
            try putText(ctx.arena, surface, geometry.right_start + stats_offset, stats_row, geometry.right_width - stats_offset, 0, removed, .{ .fg = rgb(self.theme.removed), .bold = true });
            try self.drawBody(ctx.arena, surface, geometry, foreground, accent);
            try self.paintSelection(ctx.arena, surface);
        } else {
            try putText(ctx.arena, surface, geometry.right_start, body_top, geometry.right_width, 0, "No changed files", foreground);
        }
        if (self.dialog) {
            for (surface.buffer) |*cell| cell.style.dim = true;
            try self.drawDialog(ctx.arena, surface);
        }
        if (!self.dialog) {
            try self.paintScrollbar(ctx.arena, surface);
            try self.paintHorizontalScrollbar(ctx.arena, surface);
        }
        return surface;
    }

    fn contentLength(self: *View, arena: std.mem.Allocator) std.mem.Allocator.Error!usize {
        const state = self.state.currentState() orelse return 0;
        if (state.mode == .document and state.document != null) {
            const parsed = document.parse(arena, state.document.?) catch |err| switch (err) {
                error.InvalidDocumentText => return 0,
                else => return error.OutOfMemory,
            };
            return parsed.lines.len;
        }
        return (self.state.visibleRows(arena) catch |err| switch (err) {
            error.NoSelectedFile => return 0,
            else => return error.OutOfMemory,
        }).len;
    }

    fn revealScrollbar(self: *View, ctx: *vxfw.EventContext, axis: ScrollbarAxis) !void {
        switch (axis) {
            .vertical => self.scrollbar_visible = true,
            .horizontal => self.horizontal_scrollbar_visible = true,
        }
        self.scrollbar_hide_ticks +|= 1;
        try ctx.tick(900, self.widget());
    }

    fn expireScrollbar(self: *View, ctx: *vxfw.EventContext) void {
        if (self.scrollbar_hide_ticks > 0) self.scrollbar_hide_ticks -= 1;
        if (self.scrollbar_hide_ticks != 0 or self.scrollbar_dragging != null) return;
        if (!self.scrollbar_visible and !self.horizontal_scrollbar_visible) return;
        self.scrollbar_visible = false;
        self.horizontal_scrollbar_visible = false;
        ctx.consumeAndRedraw();
    }

    fn scrollFromScrollbar(self: *View, ctx: *vxfw.EventContext, row: usize) !void {
        const viewport: usize = self.height - body_top - 1;
        const count = try self.contentLength(ctx.alloc);
        if (count <= viewport or viewport <= 1) return;
        const offset = ((@min(row - body_top, viewport - 1)) * (count - viewport)) / (viewport - 1);
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.vertical = offset;
        try self.revealScrollbar(ctx, .vertical);
    }

    const HorizontalMetrics = struct { viewport: usize, max_offset: usize };

    fn clampHorizontalScroll(self: *View, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        if (scroll.horizontal == 0) return;
        scroll.horizontal = @min(scroll.horizontal, (try self.horizontalMetrics(arena)).max_offset);
    }

    fn horizontalMetrics(self: *View, arena: std.mem.Allocator) std.mem.Allocator.Error!HorizontalMetrics {
        if (self.width < 32) return .{ .viewport = 0, .max_offset = 0 };
        const state = self.state.currentState() orelse return .{ .viewport = 0, .max_offset = 0 };
        const geometry = self.layout();
        const right_width: usize = geometry.right_width;
        if (state.mode == .document and state.document != null) {
            const parsed = document.parse(arena, state.document.?) catch |err| switch (err) {
                error.InvalidDocumentText => return .{ .viewport = right_width, .max_offset = 0 },
                else => return error.OutOfMemory,
            };
            var longest: usize = 0;
            for (parsed.lines) |line| {
                var width: usize = 0;
                for (line.spans) |span| width += text_selection.width(span.text);
                longest = @max(longest, width);
            }
            return .{ .viewport = right_width, .max_offset = longest -| right_width };
        }
        const rows = self.state.visibleRows(arena) catch |err| switch (err) {
            error.NoSelectedFile => return .{ .viewport = 0, .max_offset = 0 },
            else => return error.OutOfMemory,
        };
        const fallback = rows.len == 0 or rows[0].kind == .fallback;
        if (fallback) {
            var longest: usize = 0;
            for (rows) |row| {
                if (row.before) |side| longest = @max(longest, text_selection.width(try safeDisplay(arena, side.text)));
            }
            return .{ .viewport = right_width, .max_offset = longest -| right_width };
        }
        const before_viewport: usize = geometry.before_width -| 5;
        const after_viewport: usize = geometry.after_width -| 5;
        var before_longest: usize = 0;
        var after_longest: usize = 0;
        for (rows) |row| {
            if (row.before) |side| {
                var width = text_selection.width(try safeDisplay(arena, side.text));
                if (side.no_newline) width += "[no newline]".len + @intFromBool(side.text.len != 0);
                before_longest = @max(before_longest, width);
            }
            if (row.after) |side| {
                var width = text_selection.width(try safeDisplay(arena, side.text));
                if (side.no_newline) width += "[no newline]".len + @intFromBool(side.text.len != 0);
                after_longest = @max(after_longest, width);
            }
        }
        const before_offset = before_longest -| before_viewport;
        const after_offset = after_longest -| after_viewport;
        return if (before_offset >= after_offset)
            .{ .viewport = before_viewport, .max_offset = before_offset }
        else
            .{ .viewport = after_viewport, .max_offset = after_offset };
    }

    fn scrollFromHorizontalScrollbar(self: *View, ctx: *vxfw.EventContext, column: usize) !void {
        const metrics = try self.horizontalMetrics(ctx.alloc);
        if (metrics.max_offset == 0) return;
        const geometry = self.layout();
        const start: usize = geometry.right_start;
        const width: usize = geometry.right_width;
        if (width <= 1) return;
        const offset = (@min(column -| start, width - 1) * metrics.max_offset) / (width - 1);
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.horizontal = offset;
        try self.revealScrollbar(ctx, .horizontal);
    }

    fn paintScrollbar(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        if (!self.scrollbar_visible) return;
        const viewport: usize = self.height - body_top - 1;
        const count = try self.contentLength(arena);
        if (count <= viewport or viewport == 0) return;
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) state.document_scroll else state.raw_scroll;
        const thumb = @max(@as(usize, 1), (viewport * viewport) / count);
        const start = (@min(scroll.vertical, count - viewport) * (viewport - thumb)) / (count - viewport);
        const column = self.width - 2;
        for (start..start + thumb) |position| {
            const row: u16 = @intCast(position + body_top);
            var cell = surface.readCell(column, row);
            cell.style.bg = .{ .rgb = .{ 96, 97, 115 } };
            cell.default = false;
            surface.writeCell(column, row, cell);
        }
    }

    fn paintHorizontalScrollbar(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        if (!self.horizontal_scrollbar_visible) return;
        const metrics = try self.horizontalMetrics(arena);
        if (metrics.max_offset == 0 or metrics.viewport == 0) return;
        const geometry = self.layout();
        const start: usize = geometry.right_start;
        const width: usize = geometry.right_width;
        const content_width = metrics.viewport + metrics.max_offset;
        const thumb = @max(@as(usize, 1), (width * metrics.viewport) / content_width);
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) state.document_scroll else state.raw_scroll;
        const thumb_start = (@min(scroll.horizontal, metrics.max_offset) * (width - thumb)) / metrics.max_offset;
        const row = self.height - 2;
        for (0..width) |position| {
            const active = position >= thumb_start and position < thumb_start + thumb;
            surface.writeCell(@intCast(start + position), row, .{
                .char = .{ .grapheme = if (active) "━" else "─", .width = 1 },
                .style = .{
                    .fg = if (active) rgb(self.theme.accent) else .{ .rgb = .{ 96, 97, 115 } },
                    .bg = .{ .rgb = .{ 36, 35, 48 } },
                },
            });
        }
    }

    fn paintSelection(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        const selection = self.selection orelse return;
        if (!selection.active) return;
        const area = self.selectionArea(selection.source) orelse return;
        const lines = (try self.selectionLines(arena, selection.source)) orelse return;
        const selected = text_selection.range(selection.origin, selection.target);
        for (body_top..self.height - 1) |screen_row| {
            const row = area.vertical + screen_row - body_top;
            if (row < selected.start.row or row > selected.end.row or row >= lines.len) continue;
            const line = lines[row] orelse continue;
            const start = if (row == selected.start.row) selected.start.column else 0;
            const end = if (row == selected.end.row) selected.end.column else text_selection.width(line);
            const visible_start = @max(start, area.horizontal);
            const visible_end = @min(end, area.horizontal + area.width);
            for (visible_start..visible_end) |column| {
                const x: u16 = @intCast(area.x + column - area.horizontal);
                const y: u16 = @intCast(screen_row);
                var cell = surface.readCell(x, y);
                cell.style.reverse = true;
                cell.default = false;
                surface.writeCell(x, y, cell);
            }
        }
    }

    fn drawTree(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, width: u16) !void {
        const visible = try self.state.visibleNodes(arena);
        const viewport: usize = self.height - 2;
        if (self.reveal_selection) {
            for (visible, 0..) |node_index, position| {
                if (self.state.cursor != null and node_index == self.state.cursor.?) {
                    if (position < self.tree_scroll) self.tree_scroll = position;
                    if (position >= self.tree_scroll + viewport) self.tree_scroll = position - viewport + 1;
                }
            }
            self.reveal_selection = false;
        }
        self.tree_scroll = @min(self.tree_scroll, visible.len -| viewport);
        for (visible, 0..) |node_index, position| {
            if (position < self.tree_scroll or position >= self.tree_scroll + viewport) continue;
            const node = self.state.nodes[node_index];
            const row: u16 = @intCast(position - self.tree_scroll + 1);
            const selected = self.state.cursor != null and node_index == self.state.cursor.?;
            const style: vaxis.Style = if (selected)
                .{ .fg = if (self.focus == .tree) rgb(self.theme.background) else rgb(self.theme.foreground), .bg = if (self.focus == .tree) rgb(self.theme.accent) else .{ .rgb = .{ 48, 46, 68 } }, .bold = true }
            else if (node.kind == .folder)
                .{ .fg = rgb(self.theme.accent), .bold = true }
            else
                .{ .fg = rgb(self.theme.foreground) };
            if (selected) fill(surface, 1, row, width, style);
            var label: std.ArrayList(u8) = .empty;
            for (0..node.depth) |depth| {
                const ancestor = ancestorPosition(self.state.nodes, visible, position, depth) orelse continue;
                try label.appendSlice(arena, if (hasNextSibling(self.state.nodes, visible, ancestor)) "│ " else "  ");
            }
            const branch = if (hasNextSibling(self.state.nodes, visible, position)) "├" else "└";
            const name = if (node.kind == .folder)
                try std.fmt.allocPrint(arena, "{s}─ {s} {s}", .{ branch, if (node.expanded) "" else "󰉋", node.name })
            else
                try std.fmt.allocPrint(arena, "{s}─ {s} {s} {s}", .{ branch, statusLetter(self.state.files[node.file_index.?].kind), file_icon.forName(node.name), node.name });
            try label.appendSlice(arena, name);
            try putText(arena, surface, 1, row, width, 0, label.items, style);
        }
    }

    fn drawBody(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, geometry: Layout, foreground: vaxis.Style, accent: vaxis.Style) !void {
        const state = self.state.currentState() orelse return;
        const x = geometry.right_start;
        const width = geometry.right_width;
        const viewport: usize = self.height - body_top - 1;
        if (state.mode == .document and state.document != null) {
            const parsed = document.parse(arena, state.document.?) catch |err| switch (err) {
                error.InvalidDocumentText => {
                    state.document = null;
                    state.mode = .raw;
                    state.unavailable_reason = "Invalid document text";
                    return self.drawBody(arena, surface, geometry, foreground, accent);
                },
                else => return error.OutOfMemory,
            };
            state.document_scroll.vertical = @min(state.document_scroll.vertical, parsed.lines.len -| viewport);
            for (parsed.lines, 0..) |line, index| {
                if (index < state.document_scroll.vertical or index >= state.document_scroll.vertical + viewport) continue;
                drawStyledLine(surface, x, @intCast(index - state.document_scroll.vertical + body_top), width, state.document_scroll.horizontal, line, self.theme);
            }
            return;
        }
        const rows = self.state.visibleRows(arena) catch |err| switch (err) {
            error.NoSelectedFile => return,
            else => return error.OutOfMemory,
        };
        state.raw_scroll.vertical = @min(state.raw_scroll.vertical, rows.len -| viewport);
        const fallback = rows.len == 0 or rows[0].kind == .fallback;
        if (fallback) {
            for (rows, 0..) |row, index| {
                if (index < state.raw_scroll.vertical or index >= state.raw_scroll.vertical + viewport) continue;
                if (row.before) |side| try putText(arena, surface, x, @intCast(index - state.raw_scroll.vertical + body_top), width, state.raw_scroll.horizontal, side.text, foreground);
            }
            return;
        }
        const divider_style: vaxis.Style = if (self.divider_dragging == .inner)
            .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true }
        else
            accent;
        for (body_top..self.height - 1) |screen_row| try putText(arena, surface, geometry.inner, @intCast(screen_row), 1, 0, "│", divider_style);
        for (rows, 0..) |row, index| {
            if (index < state.raw_scroll.vertical or index >= state.raw_scroll.vertical + viewport) continue;
            const y: u16 = @intCast(index - state.raw_scroll.vertical + body_top);
            if (row.kind == .fold) {
                const style: vaxis.Style = .{ .fg = rgb(self.theme.accent), .bg = .{ .rgb = .{ 36, 35, 48 } } };
                fill(surface, x, y, width, style);
                const label = try std.fmt.allocPrint(arena, "{s} {d} unchanged lines (click to toggle)", .{ if (row.expanded) "▾" else "▸", row.hidden.len });
                try putText(arena, surface, x + 1, y, width -| 1, 0, label, style);
                continue;
            }
            if (row.kind == .hunk) {
                try putText(arena, surface, x, y, width, 0, row.label, .{ .fg = rgb(self.theme.foreground), .dim = true });
                continue;
            }
            const before_style: vaxis.Style = if (row.kind == .change) .{ .fg = rgb(self.theme.foreground), .bg = rgb(mix(self.theme.background, self.theme.removed)) } else foreground;
            const after_style: vaxis.Style = if (row.kind == .change) .{ .fg = rgb(self.theme.foreground), .bg = rgb(mix(self.theme.background, self.theme.added)) } else foreground;
            drawSide(arena, surface, x, y, geometry.before_width, state.raw_scroll.horizontal, row.before, before_style) catch return error.OutOfMemory;
            drawSide(arena, surface, geometry.after_start, y, geometry.after_width, state.raw_scroll.horizontal, row.after, after_style) catch return error.OutOfMemory;
        }
    }

    fn drawDialog(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        const box = dialogGeometry(self.width, self.height);
        const background: vaxis.Style = .{ .fg = rgb(self.theme.foreground), .bg = .{ .rgb = .{ 36, 35, 48 } } };
        for (box.top..box.bottom + 1) |row| fill(surface, box.left, @intCast(row), box.right - box.left + 1, background);
        drawBox(surface, box.left, box.right, box.top, box.bottom, .{ .fg = rgb(self.theme.accent), .bg = background.bg });
        const prompt = "Quit Lantana?";
        const prompt_width: u16 = prompt.len;
        try putText(arena, surface, box.left + (box.right - box.left + 1 - prompt_width) / 2, box.top + 2, prompt_width, 0, prompt, .{ .fg = rgb(self.theme.foreground), .bg = background.bg, .bold = true });
        const cancel: vaxis.Style = if (self.dialog_choice == .cancel) .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true } else background;
        const confirm: vaxis.Style = if (self.dialog_choice == .quit) .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true } else background;
        try putText(arena, surface, box.cancel, box.buttons_row, 8, 0, "[Cancel]", cancel);
        try putText(arena, surface, box.confirm, box.buttons_row, 6, 0, "[Quit]", confirm);
    }
};

const DialogGeometry = struct { left: u16, right: u16, top: u16, bottom: u16, buttons_row: u16, cancel: u16, confirm: u16 };

fn dialogGeometry(width: u16, height: u16) DialogGeometry {
    const box_width = @min(width -| 4, 28);
    const left = (width - box_width) / 2;
    const top = (height -| 6) / 2;
    const cancel = left + (box_width - 16) / 2;
    return .{
        .left = left,
        .right = left + box_width - 1,
        .top = top,
        .bottom = top + 5,
        .buttons_row = top + 4,
        .cancel = cancel,
        .confirm = cancel + 10,
    };
}

fn drawBox(surface: vxfw.Surface, left: u16, right: u16, top: u16, bottom: u16, style: vaxis.Style) void {
    for (top..bottom + 1) |row| {
        const y: u16 = @intCast(row);
        surface.writeCell(left, y, .{ .char = .{ .grapheme = if (y == top) "┌" else if (y == bottom) "└" else "│", .width = 1 }, .style = style });
        surface.writeCell(right, y, .{ .char = .{ .grapheme = if (y == top) "┐" else if (y == bottom) "┘" else "│", .width = 1 }, .style = style });
        if (y == top or y == bottom) for (left + 1..right) |column| {
            surface.writeCell(@intCast(column), y, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = style });
        };
    }
}

fn hasNextSibling(nodes: []const review.Node, visible: []const usize, position: usize) bool {
    const node = nodes[visible[position]];
    const parent = std.fs.path.dirname(node.path) orelse "";
    for (visible[position + 1 ..]) |index| {
        const next = nodes[index];
        if (next.depth < node.depth) return false;
        if (next.depth == node.depth) return std.mem.eql(u8, parent, std.fs.path.dirname(next.path) orelse "");
    }
    return false;
}

fn ancestorPosition(nodes: []const review.Node, visible: []const usize, position: usize, depth: usize) ?usize {
    const child = nodes[visible[position]];
    var cursor = position;
    while (cursor > 0) {
        cursor -= 1;
        const ancestor = nodes[visible[cursor]];
        if (ancestor.kind == .folder and ancestor.depth == depth and child.path.len > ancestor.path.len and
            std.mem.startsWith(u8, child.path, ancestor.path) and child.path[ancestor.path.len] == '/') return cursor;
    }
    return null;
}

fn statusLetter(kind: @import("git_patch.zig").ChangeKind) []const u8 {
    return switch (kind) {
        .modified => "M",
        .added => "A",
        .deleted => "D",
        .renamed => "R",
        .binary => "B",
        .mode_only => "T",
        .unsupported => "?",
    };
}

fn treeWidth(width: u16) u16 {
    return @min(@max(@as(u16, 18), width / 3), 28);
}

fn rgb(color: Color) vaxis.Color {
    return .{ .rgb = .{ color.r, color.g, color.b } };
}

fn mix(background: Color, foreground: Color) Color {
    return .{
        .r = @intCast((@as(u16, background.r) * 4 + foreground.r) / 5),
        .g = @intCast((@as(u16, background.g) * 4 + foreground.g) / 5),
        .b = @intCast((@as(u16, background.b) * 4 + foreground.b) / 5),
    };
}

fn fill(surface: vxfw.Surface, x: u16, y: u16, width: u16, style: vaxis.Style) void {
    for (0..width) |column| surface.writeCell(x + @as(u16, @intCast(column)), y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
}

fn putText(arena: std.mem.Allocator, surface: vxfw.Surface, x: u16, y: u16, width: u16, offset: usize, value: []const u8, style: vaxis.Style) std.mem.Allocator.Error!void {
    if (width == 0) return;
    const safe = try safeDisplay(arena, value);
    var graphemes = vaxis.unicode.graphemeIterator(safe);
    var logical: usize = 0;
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(safe);
        if (std.mem.eql(u8, bytes, "\t")) {
            const advance = 4 - logical % 4;
            for (0..advance) |column| {
                const position = logical + column;
                if (position < offset or position - offset >= width) continue;
                surface.writeCell(x + @as(u16, @intCast(position - offset)), y, .{
                    .char = .{ .grapheme = if (column == 0) "→" else " ", .width = 1 },
                    .style = style,
                });
            }
            logical += advance;
            continue;
        }
        const cells = vaxis.gwidth.gwidth(bytes, .unicode);
        if (logical + cells <= offset) {
            logical += cells;
            continue;
        }
        if (logical < offset) {
            logical += cells;
            continue;
        }
        const visible = logical - offset;
        if (visible + cells > width) break;
        surface.writeCell(x + @as(u16, @intCast(visible)), y, .{ .char = .{ .grapheme = bytes, .width = @intCast(cells) }, .style = style });
        logical += cells;
    }
}

fn safeDisplay(arena: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    var needs_replacement = !std.unicode.utf8ValidateSlice(value);
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) needs_replacement = true;
    }
    if (!needs_replacement) return value;
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
            try output.appendSlice(arena, "�");
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length == 0 or index + length > value.len or
            (std.unicode.utf8Decode(value[index .. index + length]) catch null) == null)
        {
            try output.appendSlice(arena, "�");
            index += 1;
            continue;
        }
        try output.appendSlice(arena, value[index .. index + length]);
        index += length;
    }
    return output.toOwnedSlice(arena);
}

fn drawSide(arena: std.mem.Allocator, surface: vxfw.Surface, x: u16, y: u16, width: u16, offset: usize, side: ?raw_split.Side, style: vaxis.Style) !void {
    const content = side orelse return;
    const gutter: vaxis.Style = .{ .fg = style.fg, .dim = true };
    const number = try std.fmt.allocPrint(arena, "{d: >4}", .{content.number});
    try putText(arena, surface, x, y, @min(width, 4), 0, number, gutter);
    if (width > 4) try putText(arena, surface, x + 4, y, 1, 0, "│", gutter);
    if (width <= 5) return;
    if (style.bg != .default) fill(surface, x + 5, y, width - 5, style);
    const value = if (content.no_newline)
        try std.fmt.allocPrint(arena, "{s}{s}[no newline]", .{ content.text, if (content.text.len == 0) "" else " " })
    else
        content.text;
    try putText(arena, surface, x + 5, y, width - 5, offset, value, style);
}

fn drawStyledLine(surface: vxfw.Surface, x: u16, y: u16, width: u16, offset: usize, line: document.Line, theme: Theme) void {
    var logical: usize = 0;
    for (line.spans) |span| {
        const style = styleFromDocument(span.style, theme);
        var graphemes = vaxis.unicode.graphemeIterator(span.text);
        while (graphemes.next()) |grapheme| {
            const bytes = grapheme.bytes(span.text);
            const cells = vaxis.gwidth.gwidth(bytes, .unicode);
            if (logical + cells <= offset or logical < offset) {
                logical += cells;
                continue;
            }
            const visible = logical - offset;
            if (visible + cells <= width) surface.writeCell(x + @as(u16, @intCast(visible)), y, .{ .char = .{ .grapheme = bytes, .width = @intCast(cells) }, .style = style });
            logical += cells;
        }
    }
}

fn styleFromDocument(input: document.Style, theme: Theme) vaxis.Style {
    return .{
        .fg = if (input.fg) |color| documentColor(color) else rgb(theme.foreground),
        .bg = if (input.bg) |color| documentColor(color) else .default,
        .bold = input.bold,
        .dim = input.dim,
        .ul_style = if (input.underline) .single else .off,
    };
}

fn documentColor(color: document.Color) vaxis.Color {
    return switch (color) {
        .indexed => |index| .{ .index = index },
        .rgb => |value| .{ .rgb = value },
    };
}

test "changed source highlights stop at the line-number separator" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const surface = try vxfw.Surface.init(arena, undefined, .{ .width = 16, .height = 1 });
    try drawSide(arena, surface, 0, 0, 16, 0, .{ .number = 7, .text = "changed" }, .{
        .fg = .{ .rgb = .{ 220, 220, 224 } },
        .bg = .{ .rgb = .{ 40, 30, 30 } },
    });

    // The gutter stays neutral so the color identifies source content only.
    try std.testing.expect(surface.readCell(3, 0).style.bg == .default);
    try std.testing.expectEqualStrings("│", surface.readCell(4, 0).char.grapheme);
    try std.testing.expect(surface.readCell(4, 0).style.bg == .default);
    try std.testing.expect(surface.readCell(5, 0).style.bg != .default);
}
