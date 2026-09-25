const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const document = @import("document.zig");
const review = @import("review.zig");
const raw_split = @import("raw_split.zig");
const terminal = @import("terminal.zig");

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
    scrollbar_hide_ticks: u8 = 0,
    scrollbar_dragging: bool = false,
    width: u16 = 80,
    height: u16 = 24,

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
                    self.focus = .content;
                } else if (self.focus == .tree) {
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
                    try self.revealScrollbar(ctx);
                } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{}) or key.matches(vaxis.Key.page_up, .{})) {
                    self.state.scrollUp(if (key.matches(vaxis.Key.page_up, .{})) 10 else 1);
                    try self.revealScrollbar(ctx);
                } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
                    self.state.panRight(1);
                } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
                    self.state.panLeft(1);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.state.currentState()) |state| {
                        if (state.mode == .raw) _ = try self.state.toggleFold(state.raw_scroll.vertical);
                    }
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
        if (value.button == .left and (value.type == .press or value.type == .drag or value.type == .release) and
            (self.scrollbar_dragging or (value.col >= 0 and @as(usize, @intCast(value.col)) == self.width - 2 and self.scrollbar_visible)))
        {
            const row: usize = if (value.row < 1) 1 else @min(@as(usize, @intCast(value.row)), self.height - 2);
            try self.scrollFromScrollbar(ctx, row);
            self.scrollbar_dragging = value.type != .release;
            self.focus = .content;
            ctx.consumeAndRedraw();
            return;
        }
        if (value.col < 0 or value.row < 0) return;
        const x: usize = @intCast(value.col);
        const y: usize = @intCast(value.row);
        const tree_width = treeWidth(self.width);
        if (value.button == .wheel_down or value.button == .wheel_up) {
            if (x <= tree_width) {
                if (value.button == .wheel_down) self.tree_scroll +|= 1 else self.tree_scroll -|= 1;
                self.focus = .tree;
                self.reveal_selection = false;
            } else {
                if (value.button == .wheel_down) self.state.scrollDown(1) else self.state.scrollUp(1);
                self.focus = .content;
                try self.revealScrollbar(ctx);
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (value.type != .press or value.button != .left) return;
        if (x < tree_width and y >= 1 and y < self.height - 1) {
            const visible = try self.state.visibleNodes(ctx.alloc);
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
        } else if (x > tree_width) {
            self.focus = .content;
            if (y >= 1 and y < self.height - 1) {
                if (self.state.currentState()) |state| {
                    if (state.mode == .raw) _ = try self.state.toggleFold(state.raw_scroll.vertical + y - 1);
                }
            }
        }
        ctx.consumeAndRedraw();
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
        const tree_width = treeWidth(size.width);
        const right_start = tree_width + 2;
        const right_width = size.width - right_start - 1;
        const foreground: vaxis.Style = .{ .fg = rgb(self.theme.foreground) };
        const accent: vaxis.Style = .{ .fg = rgb(self.theme.accent), .bold = true };
        const inactive: vaxis.Style = .{ .fg = rgb(self.theme.foreground), .dim = true };
        drawBox(surface, 0, tree_width, 0, size.height - 1, if (self.focus == .tree and !self.dialog) accent else inactive);
        drawBox(surface, tree_width + 1, size.width - 1, 0, size.height - 1, if (self.focus == .content and !self.dialog) accent else inactive);
        try self.drawTree(ctx.arena, surface, tree_width - 1);
        if (self.state.currentFile()) |file| {
            try putText(ctx.arena, surface, right_start, 0, right_width, 0, file.display_path, if (self.focus == .content) accent else foreground);
            try self.drawBody(ctx.arena, surface, right_start, right_width, foreground, accent);
            if (self.state.currentState().?.unavailable_reason) |reason| try putText(ctx.arena, surface, right_start, size.height - 1, right_width, 0, reason, foreground);
        } else {
            try putText(ctx.arena, surface, right_start, 2, right_width, 0, "No changed files", foreground);
        }
        if (self.dialog) try self.drawDialog(ctx.arena, surface);
        if (!self.dialog) try self.paintScrollbar(ctx.arena, surface);
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

    fn revealScrollbar(self: *View, ctx: *vxfw.EventContext) !void {
        self.scrollbar_visible = true;
        self.scrollbar_hide_ticks +|= 1;
        try ctx.tick(900, self.widget());
    }

    fn expireScrollbar(self: *View, ctx: *vxfw.EventContext) void {
        if (self.scrollbar_hide_ticks > 0) self.scrollbar_hide_ticks -= 1;
        if (self.scrollbar_hide_ticks != 0 or !self.scrollbar_visible or self.scrollbar_dragging) return;
        self.scrollbar_visible = false;
        self.scrollbar_dragging = false;
        ctx.consumeAndRedraw();
    }

    fn scrollFromScrollbar(self: *View, ctx: *vxfw.EventContext, row: usize) !void {
        const viewport: usize = self.height - 2;
        const count = try self.contentLength(ctx.alloc);
        if (count <= viewport or viewport <= 1) return;
        const offset = ((@min(row - 1, viewport - 1)) * (count - viewport)) / (viewport - 1);
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) &state.document_scroll else &state.raw_scroll;
        scroll.vertical = offset;
        try self.revealScrollbar(ctx);
    }

    fn paintScrollbar(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        if (!self.scrollbar_visible) return;
        const viewport: usize = self.height - 2;
        const count = try self.contentLength(arena);
        if (count <= viewport or viewport == 0) return;
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) state.document_scroll else state.raw_scroll;
        const thumb = @max(@as(usize, 1), (viewport * viewport) / count);
        const start = (@min(scroll.vertical, count - viewport) * (viewport - thumb)) / (count - viewport);
        const column = self.width - 2;
        for (start..start + thumb) |position| {
            const row: u16 = @intCast(position + 1);
            var cell = surface.readCell(column, row);
            cell.style.bg = .{ .rgb = .{ 96, 97, 115 } };
            cell.default = false;
            surface.writeCell(column, row, cell);
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
                try std.fmt.allocPrint(arena, "{s}─ {s}  {s}", .{ branch, statusLetter(self.state.files[node.file_index.?].kind), node.name });
            try label.appendSlice(arena, name);
            try putText(arena, surface, 1, row, width, 0, label.items, style);
        }
    }

    fn drawBody(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, x: u16, width: u16, foreground: vaxis.Style, accent: vaxis.Style) !void {
        const state = self.state.currentState() orelse return;
        const viewport: usize = self.height - 2;
        if (state.mode == .document and state.document != null) {
            const parsed = document.parse(arena, state.document.?) catch |err| switch (err) {
                error.InvalidDocumentText => {
                    state.document = null;
                    state.mode = .raw;
                    state.unavailable_reason = "Invalid document text";
                    return self.drawBody(arena, surface, x, width, foreground, accent);
                },
                else => return error.OutOfMemory,
            };
            state.document_scroll.vertical = @min(state.document_scroll.vertical, parsed.lines.len -| viewport);
            for (parsed.lines, 0..) |line, index| {
                if (index < state.document_scroll.vertical or index >= state.document_scroll.vertical + viewport) continue;
                drawStyledLine(surface, x, @intCast(index - state.document_scroll.vertical + 1), width, state.document_scroll.horizontal, line, self.theme);
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
                if (row.before) |side| try putText(arena, surface, x, @intCast(index - state.raw_scroll.vertical + 1), width, state.raw_scroll.horizontal, side.text, foreground);
            }
            return;
        }
        const half = width / 2;
        for (1..self.height - 1) |screen_row| try putText(arena, surface, x + half, @intCast(screen_row), 1, 0, "│", accent);
        for (rows, 0..) |row, index| {
            if (index < state.raw_scroll.vertical or index >= state.raw_scroll.vertical + viewport) continue;
            const y: u16 = @intCast(index - state.raw_scroll.vertical + 1);
            if (row.kind == .fold) {
                const style: vaxis.Style = .{ .fg = rgb(self.theme.accent), .bg = .{ .rgb = .{ 36, 35, 48 } } };
                fill(surface, x, y, width, style);
                const label = try std.fmt.allocPrint(arena, "{s} {d} unchanged lines (click or Enter)", .{ if (row.expanded) "▾" else "▸", row.hidden.len });
                try putText(arena, surface, x + 1, y, width -| 1, 0, label, style);
                continue;
            }
            if (row.kind == .hunk) {
                try putText(arena, surface, x, y, width, 0, row.label, .{ .fg = rgb(self.theme.foreground), .dim = true });
                continue;
            }
            const before_style: vaxis.Style = if (row.kind == .change) .{ .fg = rgb(self.theme.foreground), .bg = rgb(mix(self.theme.background, self.theme.removed)) } else foreground;
            const after_style: vaxis.Style = if (row.kind == .change) .{ .fg = rgb(self.theme.foreground), .bg = rgb(mix(self.theme.background, self.theme.added)) } else foreground;
            drawSide(arena, surface, x, y, half, state.raw_scroll.horizontal, row.before, before_style) catch return error.OutOfMemory;
            drawSide(arena, surface, x + half + 1, y, width -| half -| 1, state.raw_scroll.horizontal, row.after, after_style) catch return error.OutOfMemory;
        }
    }

    fn drawDialog(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface) !void {
        const box = dialogGeometry(self.width, self.height);
        const background: vaxis.Style = .{ .fg = rgb(self.theme.foreground), .bg = .{ .rgb = .{ 36, 35, 48 } } };
        for (box.top..box.bottom + 1) |row| fill(surface, box.left, @intCast(row), box.right - box.left + 1, background);
        drawBox(surface, box.left, box.right, box.top, box.bottom, .{ .fg = rgb(self.theme.accent), .bg = background.bg });
        try putText(arena, surface, box.left + 2, box.top + 2, box.right - box.left - 3, 0, "Quit Lantana?", .{ .fg = rgb(self.theme.foreground), .bg = background.bg, .bold = true });
        try putText(arena, surface, box.left + 2, box.top + 3, box.right - box.left - 3, 0, "Review is read-only.", background);
        const cancel: vaxis.Style = if (self.dialog_choice == .cancel) .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true } else background;
        const confirm: vaxis.Style = if (self.dialog_choice == .quit) .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true } else background;
        try putText(arena, surface, box.cancel, box.buttons_row, 8, 0, "[Cancel]", cancel);
        try putText(arena, surface, box.confirm, box.buttons_row, 6, 0, "[Quit]", confirm);
    }
};

const DialogGeometry = struct { left: u16, right: u16, top: u16, bottom: u16, buttons_row: u16, cancel: u16, confirm: u16 };

fn dialogGeometry(width: u16, height: u16) DialogGeometry {
    const box_width = @min(width -| 4, 38);
    const left = (width - box_width) / 2;
    const top = (height -| 7) / 2;
    return .{
        .left = left,
        .right = left + box_width - 1,
        .top = top,
        .bottom = top + 6,
        .buttons_row = top + 5,
        .cancel = left + 3,
        .confirm = left + box_width - 9,
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
    if (style.bg != .default) fill(surface, x, y, width, style);
    const number = try std.fmt.allocPrint(arena, "{d: >4} ", .{content.number});
    try putText(arena, surface, x, y, width, 0, number, style);
    if (width <= 5) return;
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
