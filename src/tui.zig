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
    var view: View = .{ .state = state, .theme = theme };
    try session.app.run(view.widget(), .{});
}

const Focus = enum { tree, content };

const View = struct {
    state: *review.Review,
    theme: Theme,
    focus: Focus = .tree,
    tree_scroll: usize = 0,
    reveal_selection: bool = true,
    last_collapsed_folder: ?usize = null,
    width: u16 = 80,
    height: u16 = 24,

    fn widget(self: *View) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(userdata: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        const self: *View = @ptrCast(@alignCast(userdata));
        switch (value) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    try self.state.moveDown();
                    self.focus = .tree;
                    self.reveal_selection = true;
                } else if (key.matches(vaxis.Key.up, .{})) {
                    try self.state.moveUp();
                    self.focus = .tree;
                    self.reveal_selection = true;
                } else if (key.matches('m', .{})) {
                    self.state.toggleMode();
                    self.focus = .content;
                } else if (key.matches('j', .{}) or key.matches(vaxis.Key.page_down, .{})) {
                    self.state.scrollDown(if (key.matches('j', .{})) 1 else 10);
                    self.focus = .content;
                } else if (key.matches('k', .{}) or key.matches(vaxis.Key.page_up, .{})) {
                    self.state.scrollUp(if (key.matches('k', .{})) 1 else 10);
                    self.focus = .content;
                } else if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                    self.state.panRight(1);
                    self.focus = .content;
                } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                    self.state.panLeft(1);
                    self.focus = .content;
                } else if (key.matches('c', .{})) {
                    try self.toggleSelectedFolder();
                    self.focus = .tree;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    self.focus = if (self.focus == .tree) .content else .tree;
                } else return;
                ctx.consumeAndRedraw();
            },
            .mouse => |mouse| try self.handleMouse(ctx, mouse),
            .winsize => ctx.consumeAndRedraw(),
            else => {},
        }
    }

    fn toggleSelectedFolder(self: *View) !void {
        if (self.last_collapsed_folder) |index| {
            if (!self.state.nodes[index].expanded) {
                try self.state.toggleFolder(index);
                self.last_collapsed_folder = null;
                self.reveal_selection = true;
                return;
            }
            self.last_collapsed_folder = null;
        }
        const file = self.state.currentFile() orelse return;
        var parent: ?usize = null;
        for (self.state.nodes, 0..) |node, index| {
            if (node.kind != .folder) continue;
            if (file.display_path.len > node.path.len and
                std.mem.startsWith(u8, file.display_path, node.path) and
                file.display_path[node.path.len] == '/')
            {
                if (parent == null or node.depth > self.state.nodes[parent.?].depth) parent = index;
            }
        }
        if (parent) |index| {
            try self.state.toggleFolder(index);
            if (!self.state.nodes[index].expanded) self.last_collapsed_folder = index;
            self.reveal_selection = true;
        }
    }

    fn handleMouse(self: *View, ctx: *vxfw.EventContext, value: vaxis.Mouse) !void {
        if (value.col < 0 or value.row < 0) return;
        const x: usize = @intCast(value.col);
        const y: usize = @intCast(value.row);
        const tree_width = treeWidth(self.width);
        if (value.button == .wheel_down or value.button == .wheel_up) {
            if (x < tree_width) {
                if (value.button == .wheel_down) self.tree_scroll +|= 1 else self.tree_scroll -|= 1;
                self.focus = .tree;
                self.reveal_selection = false;
            } else {
                if (value.button == .wheel_down) self.state.scrollDown(1) else self.state.scrollUp(1);
                self.focus = .content;
            }
            ctx.consumeAndRedraw();
            return;
        }
        if (value.type != .press or value.button != .left) return;
        if (x < tree_width and y >= 2) {
            const visible = try self.state.visibleNodes(ctx.alloc);
            const index = self.tree_scroll + y - 2;
            if (index < visible.len) {
                const node_index = visible[index];
                const node = self.state.nodes[node_index];
                if (node.kind == .folder) {
                    try self.state.toggleFolder(node_index);
                    if (self.state.nodes[node_index].expanded) {
                        if (self.last_collapsed_folder == node_index) self.last_collapsed_folder = null;
                    } else self.last_collapsed_folder = node_index;
                } else try self.state.selectFile(node.file_index.?);
                self.reveal_selection = true;
            }
            self.focus = .tree;
        } else if (x > tree_width) {
            if (y == 1 and self.state.currentState() != null and self.state.currentState().?.document != null) self.state.toggleMode();
            self.focus = .content;
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
        const right_width = size.width - right_start;
        const foreground: vaxis.Style = .{ .fg = rgb(self.theme.foreground) };
        const accent: vaxis.Style = .{ .fg = rgb(self.theme.accent), .bold = true };
        try putText(ctx.arena, surface, 1, 0, tree_width - 1, 0, if (self.focus == .tree) "Files *" else "Files", accent);
        for (0..size.height) |row| try putText(ctx.arena, surface, tree_width, @intCast(row), 1, 0, "│", accent);
        try self.drawTree(ctx.arena, surface, tree_width);
        if (self.state.currentFile()) |file| {
            try putText(ctx.arena, surface, right_start, 0, right_width, 0, file.display_path, accent);
            try self.drawBody(ctx.arena, surface, right_start, right_width, foreground, accent);
            try self.drawModeBar(ctx.arena, surface, right_start, right_width, foreground, accent);
        } else {
            try putText(ctx.arena, surface, right_start, 2, right_width, 0, "No changed files", foreground);
        }
        return surface;
    }

    fn drawTree(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, width: u16) !void {
        const visible = try self.state.visibleNodes(arena);
        const viewport: usize = self.height - 2;
        if (self.reveal_selection) {
            for (visible, 0..) |node_index, position| {
                const node = self.state.nodes[node_index];
                if (node.file_index != null and self.state.selected != null and node.file_index.? == self.state.selected.?) {
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
            const row: u16 = @intCast(position - self.tree_scroll + 2);
            const selected = node.file_index != null and self.state.selected != null and node.file_index.? == self.state.selected.?;
            const style: vaxis.Style = if (selected)
                .{ .fg = rgb(self.theme.background), .bg = rgb(self.theme.accent), .bold = true }
            else if (node.kind == .folder)
                .{ .fg = rgb(self.theme.accent), .bold = true }
            else
                .{ .fg = rgb(self.theme.foreground) };
            if (selected) fill(surface, 0, row, width, style);
            const indent: u16 = @intCast(@min(node.depth * 2 + 1, width -| 1));
            const prefix: []const u8 = if (node.kind == .folder) (if (node.expanded) "v " else "> ") else switch (self.state.files[node.file_index.?].kind) {
                .modified => "M ",
                .added => "A ",
                .deleted => "D ",
                .renamed => "R ",
                .binary => "B ",
                .mode_only => "T ",
                .unsupported => "? ",
            };
            const label = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, node.name });
            try putText(arena, surface, indent, row, width -| indent, 0, label, style);
        }
    }

    fn drawBody(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, x: u16, width: u16, foreground: vaxis.Style, accent: vaxis.Style) !void {
        const state = self.state.currentState() orelse return;
        const viewport: usize = self.height - 3;
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
            try putText(arena, surface, x, 2, width, 0, "Document", accent);
            for (parsed.lines, 0..) |line, index| {
                if (index < state.document_scroll.vertical or index >= state.document_scroll.vertical + viewport) continue;
                drawStyledLine(surface, x, @intCast(index - state.document_scroll.vertical + 3), width, state.document_scroll.horizontal, line, self.theme);
            }
            return;
        }
        const rows = self.state.currentRows() catch |err| switch (err) {
            error.NoSelectedFile => return,
            else => return error.OutOfMemory,
        };
        state.raw_scroll.vertical = @min(state.raw_scroll.vertical, rows.len -| viewport);
        const fallback = rows.len == 0 or rows[0].kind == .fallback;
        if (fallback) {
            try putText(arena, surface, x, 2, width, 0, "Captured patch", accent);
            for (rows, 0..) |row, index| {
                if (index < state.raw_scroll.vertical or index >= state.raw_scroll.vertical + viewport) continue;
                if (row.before) |side| try putText(arena, surface, x, @intCast(index - state.raw_scroll.vertical + 3), width, state.raw_scroll.horizontal, side.text, foreground);
            }
            return;
        }
        const half = width / 2;
        try putText(arena, surface, x, 2, half, 0, "Before (-)", .{ .fg = rgb(self.theme.removed), .bold = true });
        try putText(arena, surface, x + half + 1, 2, width -| half -| 1, 0, "After (+)", .{ .fg = rgb(self.theme.added), .bold = true });
        for (3..self.height) |screen_row| try putText(arena, surface, x + half, @intCast(screen_row), 1, 0, "│", accent);
        for (rows, 0..) |row, index| {
            if (index < state.raw_scroll.vertical or index >= state.raw_scroll.vertical + viewport) continue;
            const y: u16 = @intCast(index - state.raw_scroll.vertical + 3);
            if (row.kind == .hunk) {
                try putText(arena, surface, x, y, width, 0, row.label, accent);
                continue;
            }
            drawSide(arena, surface, x, y, half, state.raw_scroll.horizontal, row.before, if (row.kind == .change) .{ .fg = rgb(self.theme.removed) } else foreground) catch return error.OutOfMemory;
            drawSide(arena, surface, x + half + 1, y, width -| half -| 1, state.raw_scroll.horizontal, row.after, if (row.kind == .change) .{ .fg = rgb(self.theme.added) } else foreground) catch return error.OutOfMemory;
        }
    }

    fn drawModeBar(self: *View, arena: std.mem.Allocator, surface: vxfw.Surface, x: u16, width: u16, foreground: vaxis.Style, accent: vaxis.Style) !void {
        const state = self.state.currentState() orelse return;
        const scroll = if (state.mode == .document) state.document_scroll else state.raw_scroll;
        const mode = if (state.document != null)
            (if (state.mode == .document) "[Document]  Raw" else "Document  [Raw]")
        else
            "[Raw]";
        const label = try std.fmt.allocPrint(arena, "{s} x:{d} y:{d}", .{ mode, scroll.horizontal, scroll.vertical });
        try putText(arena, surface, x, 1, width, 0, label, if (self.focus == .content) accent else foreground);
        if (state.unavailable_reason) |reason| {
            const start: u16 = @intCast(@min(label.len + 2, width));
            try putText(arena, surface, x + start, 1, width -| start, 0, reason, foreground);
        }
    }
};

fn treeWidth(width: u16) u16 {
    return @min(@max(@as(u16, 18), width / 3), 28);
}

fn rgb(color: Color) vaxis.Color {
    return .{ .rgb = .{ color.r, color.g, color.b } };
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
