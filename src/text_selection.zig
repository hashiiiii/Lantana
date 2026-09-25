const std = @import("std");
const vaxis = @import("vaxis");

pub const Cell = struct {
    row: usize,
    start: usize,
    end: usize,
};

pub const Point = struct { row: usize, column: usize };
pub const Range = struct { start: Point, end: Point };

pub fn hit(text: []const u8, row: usize, column: usize) Cell {
    var logical: usize = 0;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const cells = cellWidth(bytes, logical);
        if (column < logical + cells) return .{ .row = row, .start = logical, .end = logical + cells };
        logical += cells;
    }
    return .{ .row = row, .start = logical, .end = logical };
}

pub fn width(text: []const u8) usize {
    var logical: usize = 0;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| logical += cellWidth(grapheme.bytes(text), logical);
    return logical;
}

pub fn range(origin: Cell, target: Cell) Range {
    if (target.row < origin.row or (target.row == origin.row and target.start < origin.start)) {
        return .{
            .start = .{ .row = target.row, .column = target.start },
            .end = .{ .row = origin.row, .column = origin.end },
        };
    }
    return .{
        .start = .{ .row = origin.row, .column = origin.start },
        .end = .{ .row = target.row, .column = target.end },
    };
}

pub fn extract(arena: std.mem.Allocator, lines: []const ?[]const u8, selected: Range) !?[]const u8 {
    if (selected.start.row > selected.end.row or selected.end.row >= lines.len) return null;
    var output: std.ArrayList(u8) = .empty;
    for (selected.start.row..selected.end.row + 1) |row| {
        const line = lines[row] orelse return null;
        if (row != selected.start.row) try output.append(arena, '\n');
        const from = if (row == selected.start.row) byteAt(line, selected.start.column, false) else 0;
        const to = if (row == selected.end.row) byteAt(line, selected.end.column, true) else line.len;
        if (from > to) return null;
        try output.appendSlice(arena, line[from..to]);
    }
    const value = try output.toOwnedSlice(arena);
    return value;
}

fn byteAt(text: []const u8, column: usize, end: bool) usize {
    var logical: usize = 0;
    var graphemes = vaxis.unicode.graphemeIterator(text);
    while (graphemes.next()) |grapheme| {
        if (column <= logical) return grapheme.start;
        const cells = cellWidth(grapheme.bytes(text), logical);
        if (column < logical + cells) return grapheme.start + @intFromBool(end) * grapheme.len;
        logical += cells;
    }
    return text.len;
}

fn cellWidth(bytes: []const u8, logical: usize) usize {
    return if (std.mem.eql(u8, bytes, "\t")) 4 - logical % 4 else vaxis.gwidth.gwidth(bytes, .unicode);
}

test "selection copies source graphemes without skipping folded rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const lines: []const ?[]const u8 = &.{ "a\t界b", "second" };
    const forward = range(hit(lines[0].?, 0, 2), hit(lines[1].?, 1, 1));
    // A partial click on a tab or wide glyph must copy the whole source grapheme.
    try std.testing.expectEqualStrings("\t界b\nse", (try extract(arena, lines, forward)).?);
    const backward = range(hit(lines[1].?, 1, 1), hit(lines[0].?, 0, 2));
    try std.testing.expectEqualStrings("\t界b\nse", (try extract(arena, lines, backward)).?);

    // A collapsed range cannot silently omit source lines from a copied selection.
    const folded: []const ?[]const u8 = &.{ "one", null, "three" };
    try std.testing.expect((try extract(arena, folded, .{
        .start = .{ .row = 0, .column = 0 },
        .end = .{ .row = 2, .column = 5 },
    })) == null);
}
