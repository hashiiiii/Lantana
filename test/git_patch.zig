const std = @import("std");
const parser = @import("lantana").git_patch;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn parseFixture(arena: std.mem.Allocator, comptime name: []const u8) !parser.Patch {
    return parser.parse(arena, @embedFile("fixtures/" ++ name));
}

test "ordinary Git sections retain exact bytes and do not split on hunk text" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const source = @embedFile("fixtures/ordinary.patch");
    const patch = try parseFixture(memory.allocator(), "ordinary.patch");
    try expectEqual(@as(usize, 2), patch.files.len);
    try expectEqualStrings("Assets/A.prefab", patch.files[0].display_path);
    try expectEqualStrings("Scripts/A.cs", patch.files[1].display_path);
    try expectEqual(parser.ChangeKind.modified, patch.files[0].kind);
    try expectEqualStrings("a869c28", patch.files[1].old_blob.?);
    try expectEqualStrings("0dad58b", patch.files[1].new_blob.?);
    // A source line with a Git header prefix must not become another file section.
    try expect(std.mem.indexOf(u8, patch.files[1].raw, "+  // diff --git a/fake b/fake") != null);
    try expectEqual(@as(usize, 0), patch.files[0].start);
    try expectEqual(source.len, patch.files[1].end);
    // Exact source slices keep the caller's raw fallback available after parsing.
    for (patch.files) |file| try expectEqualStrings(source[file.start..file.end], file.raw);
}

test "Git change kinds retain selectable additions deletions renames binary and mode changes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "kinds.patch");
    try expectEqual(@as(usize, 5), patch.files.len);
    try expectEqual(parser.ChangeKind.deleted, patch.files[0].kind);
    try expectEqual(@as(?[]const u8, null), patch.files[0].new_path);
    try expectEqual(parser.ChangeKind.mode_only, patch.files[1].kind);
    try expectEqual(parser.ChangeKind.added, patch.files[2].kind);
    try expectEqual(@as(?[]const u8, null), patch.files[2].old_path);
    try expectEqual(parser.ChangeKind.renamed, patch.files[3].kind);
    try expectEqualStrings("Assets/Rename.prefab", patch.files[3].old_path.?);
    try expectEqualStrings("Assets/Renamed.prefab", patch.files[3].new_path.?);
    try expectEqual(parser.ChangeKind.binary, patch.files[4].kind);
    try expectEqualStrings("Image.png", patch.files[4].display_path);
}

test "Git C quoted paths decode spaces quotes tabs and Unicode" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "paths.patch");
    try expectEqual(@as(usize, 4), patch.files.len);
    // Mode-only patches have no ---/+++ lines to correct a misread diff header.
    try expectEqualStrings("dir b/Mode.cs", patch.files[0].display_path);
    try expectEqualStrings("quote\"tab\t.cs", patch.files[1].display_path);
    try expectEqualStrings("space name.cs", patch.files[2].display_path);
    try expectEqualStrings("日本語.prefab", patch.files[3].display_path);
}

test "renamed Git path may quote only one side" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "mixed_rename.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    try expectEqual(parser.ChangeKind.renamed, patch.files[0].kind);
    try expectEqualStrings("日本語.cs", patch.files[0].old_path.?);
    try expectEqualStrings("Plain.cs", patch.files[0].new_path.?);
    const reverse = try parseFixture(memory.allocator(), "mixed_rename_reverse.patch");
    try expectEqual(@as(usize, 1), reverse.files.len);
    try expectEqual(parser.ChangeKind.renamed, reverse.files[0].kind);
    try expectEqualStrings("Plain.cs", reverse.files[0].old_path.?);
    try expectEqualStrings("日本語.cs", reverse.files[0].new_path.?);
}

test "rename metadata resolves an ambiguous unquoted diff header" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "ambiguous_rename.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    // The first b/ separator also occurs inside the old path, so the header alone is ambiguous.
    try expectEqualStrings("dir b/Old.cs", patch.files[0].old_path.?);
    try expectEqualStrings("New.cs", patch.files[0].new_path.?);
    try expectEqual(parser.ChangeKind.renamed, patch.files[0].kind);
}

test "hunk content cannot replace file metadata" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const patch = try parseFixture(memory.allocator(), "metadata_hunk.patch");
    try expectEqual(@as(usize, 1), patch.files.len);
    // Git prefixes source lines with -/+; source text can then look like ---/+++ headers.
    try expectEqualStrings("Actual.cs", patch.files[0].old_path.?);
    try expectEqualStrings("Actual.cs", patch.files[0].new_path.?);
    try expectEqualStrings("Actual.cs", patch.files[0].display_path);
}

test "colored Git headers parse without changing their original bytes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const source = @embedFile("fixtures/colored.patch");
    const patch = try parser.parse(memory.allocator(), source);
    try expectEqual(@as(usize, 2), patch.files.len);
    try expectEqualStrings("Assets/A.prefab", patch.files[0].display_path);
    try expect(std.mem.indexOf(u8, patch.files[0].raw, "\x1b[") != null);
    for (patch.files) |file| try expectEqualStrings(source[file.start..file.end], file.raw);
}

test "malformed and combined input remains available as raw text" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    for ([_][]const u8{ "not a patch\n", "diff --cc File.cs\n@@@ -1,1 -1,1 +1,1 @@@\n" }) |source| {
        const patch = try parser.parse(memory.allocator(), source);
        try expectEqual(@as(usize, 0), patch.files.len);
        try expectEqualStrings(source, patch.raw_fallback.?);
    }
}
