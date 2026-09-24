const std = @import("std");
const lantana = @import("lantana");
const parser = lantana.git_patch;
const raw_split = lantana.raw_split;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "real Git hunks align unequal changes and preserve line numbers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try parser.parse(arena, @embedFile("fixtures/hunks.patch"));
    const rows = try raw_split.rows(arena, patch.files[0]);
    try expectEqual(@as(usize, 10), rows.len);
    try expectEqual(raw_split.RowKind.hunk, rows[0].kind);
    try expectEqualStrings("zero", rows[1].before.?.text);
    try expectEqual(@as(usize, 1), rows[1].before.?.number);
    try expectEqual(@as(usize, 1), rows[1].after.?.number);
    try expectEqualStrings("one", rows[2].before.?.text);
    try expectEqualStrings("ONE", rows[2].after.?.text);
    try expectEqual(@as(usize, 2), rows[2].before.?.number);
    try expectEqual(@as(usize, 2), rows[2].after.?.number);
    try expect(rows[3].before == null);
    try expectEqualStrings("extra", rows[3].after.?.text);
    try expectEqual(@as(usize, 3), rows[3].after.?.number);
    try expectEqualStrings("", rows[5].before.?.text);
    try expectEqual(@as(usize, 4), rows[5].before.?.number);
    try expectEqual(@as(usize, 5), rows[5].after.?.number);
    try expectEqual(raw_split.RowKind.hunk, rows[6].kind);
    try expectEqualStrings("nine", rows[9].before.?.text);
    try expectEqualStrings("NINE", rows[9].after.?.text);
    try expectEqual(@as(usize, 10), rows[9].before.?.number);
    try expectEqual(@as(usize, 11), rows[9].after.?.number);
    // Git's no-newline marker describes the preceding line and consumes no line number.
    try expect(rows[9].before.?.no_newline);
    try expect(rows[9].after.?.no_newline);
}

test "binary mode-only and malformed hunks remain visible as raw rows" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const kinds = try parser.parse(arena, @embedFile("fixtures/kinds.patch"));
    for ([_]usize{ 1, 4 }) |index| {
        const rows = try raw_split.rows(arena, kinds.files[index]);
        try expect(rows.len > 0);
        try expectEqual(raw_split.RowKind.fallback, rows[0].kind);
        try expect(std.mem.startsWith(u8, rows[0].before.?.text, "diff --git"));
    }
    const malformed = try parser.parse(arena, "diff --git a/B.cs b/B.cs\n@@ -1 +1 @@\n+new\n");
    const rows = try raw_split.rows(arena, malformed.files[0]);
    try expectEqual(raw_split.RowKind.fallback, rows[0].kind);
}

fn renderPatchPath(_: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!lantana.Document {
    return .{ .text = try std.fmt.allocPrint(arena, "Document for {s}", .{file.new_path orelse file.old_path orelse "unknown"}) };
}

fn renderTextOnly(_: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!lantana.Document {
    if (std.mem.indexOf(u8, file.patch, "Binary files") != null) return error.BinaryDocumentUnavailable;
    return .{ .text = try std.fmt.allocPrint(arena, "{s}", .{file.new_path orelse file.old_path orelse "unknown"}) };
}

test "review tree skips folders and keeps each file mode and scroll position" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try parser.parse(arena, @embedFile("fixtures/ordinary.patch"));
    var view = try lantana.review.Review.init(arena, patch, .{ .render = renderPatchPath });
    try expectEqualStrings("Assets/A.prefab", view.currentFile().?.display_path);
    try expectEqual(lantana.review.Mode.document, view.currentState().?.mode);
    try expect(view.states[0].rendered);
    // Rendering the first selected file must not compute another file's document.
    try expect(!view.states[1].rendered);
    try expectEqualStrings("Assets", view.nodes[0].name);
    try expectEqual(lantana.review.NodeKind.folder, view.nodes[0].kind);

    view.scrollDown(3);
    view.panRight(2);
    view.toggleMode();
    view.scrollDown(5);
    try view.moveDown();
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
    try expect(view.states[1].rendered);
    try expectEqual(lantana.review.Mode.document, view.currentState().?.mode);
    try view.moveUp();
    try expectEqual(lantana.review.Mode.raw, view.currentState().?.mode);
    try expectEqual(@as(usize, 5), view.currentState().?.raw_scroll.vertical);
    try expectEqual(@as(usize, 3), view.currentState().?.document_scroll.vertical);
    try expectEqual(@as(usize, 2), view.currentState().?.document_scroll.horizontal);

    // Hiding the selected file must choose another visible file, not a folder heading.
    try view.toggleFolder(0);
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
    try view.moveUp();
    try expectEqualStrings("Scripts/A.cs", view.currentFile().?.display_path);
}

test "renderer error keeps the original binary patch in raw mode" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const patch = try parser.parse(arena, @embedFile("fixtures/kinds.patch"));
    var view = try lantana.review.Review.init(arena, patch, .{ .render = renderTextOnly });
    try view.selectFile(4);
    try expectEqual(lantana.review.Mode.raw, view.currentState().?.mode);
    try expectEqualStrings("BinaryDocumentUnavailable", view.currentState().?.unavailable_reason.?);
    const raw = try view.currentRows();
    try expectEqual(raw_split.RowKind.fallback, raw[0].kind);
    try expect(std.mem.indexOf(u8, view.currentFile().?.raw, "Binary files") != null);
}
