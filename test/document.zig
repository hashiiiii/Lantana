const std = @import("std");
const document = @import("lantana").document;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "document parser retains SGR color while removing control effects" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const rendered = try document.parse(memory.allocator(), "\x1b[31mRed\x1b[0m safe\x1b[2J\x00\x1b]8;;https://invalid.example\x1b\\\nNext");
    try expectEqual(@as(usize, 2), rendered.lines.len);
    try expectEqualStrings("Red", rendered.lines[0].spans[0].text);
    try expectEqual(document.Color{ .indexed = 1 }, rendered.lines[0].spans[0].style.fg.?);
    try expectEqualStrings(" safe", rendered.lines[0].spans[1].text);
    try expect(rendered.lines[0].spans[1].style.fg == null);
    // OSC links and non-style CSI must not be able to write terminal controls.
    try expectEqual(@as(usize, 2), rendered.lines[0].spans.len);
    try expectEqualStrings("Next", rendered.lines[1].spans[0].text);
}

test "document parser handles RGB color and reset across lines" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const rendered = try document.parse(memory.allocator(), "\x1b[1;38;2;12;34;56mBlue\nStill\x1b[0m plain");
    try expectEqual(document.Color{ .rgb = .{ 12, 34, 56 } }, rendered.lines[0].spans[0].style.fg.?);
    try expect(rendered.lines[0].spans[0].style.bold);
    try expectEqual(document.Color{ .rgb = .{ 12, 34, 56 } }, rendered.lines[1].spans[0].style.fg.?);
    try expect(rendered.lines[1].spans[1].style.fg == null);
}

test "invalid document UTF-8 is rejected before it reaches terminal drawing" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    try std.testing.expectError(error.InvalidDocumentText, document.parse(memory.allocator(), "valid\xffinvalid"));
}
