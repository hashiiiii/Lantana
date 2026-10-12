const std = @import("std");
const Repo = @import("git_repo").Repo;
const pager_path = @import("test_options").pager_path;
const runConPty = @import("windows_conpty_support.zig").runConPty;

test "Git pager opens and closes a native ConPTY without changing the repository" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.write("Example.cs", "before\n");
    try repo.commit();
    try repo.write("Example.cs", "after\n");
    try repo.setPager(pager_path);
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    const result = try runConPty(arena, std.testing.io, &repo, "q");
    try std.testing.expect(result.sent_quit);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049l") != null);
    // Scoop and manually extracted executables need the same editable first-run configuration.
    var keymap = try std.json.parseFromSlice(std.json.Value, arena, try repo.read(".git/xdg/lantana/keymap.json"), .{});
    defer keymap.deinit();
    try std.testing.expect(keymap.value.object.contains("global"));
    try std.testing.expect(keymap.value.object.contains("tree"));
    try std.testing.expect(keymap.value.object.contains("content"));
    try std.testing.expect(keymap.value.object.contains("dialog"));
    try std.testing.expectEqualStrings(status_before, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config_before, try repo.read(".git/config"));
    try std.testing.expectEqualStrings("after\n", try repo.read("Example.cs"));
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, pager_path, arena);
    const empty = try std.process.run(arena, std.testing.io, .{ .argv = &.{executable} });
    try std.testing.expectEqual(@as(u8, 0), empty.term.exited);
    try std.testing.expectEqualStrings("", empty.stdout);
}

test "ConPTY loads a quit sequence from keymap.json" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path);
    try repo.write("Example.cs", "before\n");
    try repo.commit();
    try repo.write("Example.cs", "after\n");
    try repo.write(".git/xdg/lantana/keymap.json",
        \\{"global": {"quit": ["x x"]}}
    );
    // Both presses must reach the viewer before the sequence can quit.
    const result = try runConPty(arena, std.testing.io, &repo, "xx");
    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    try std.testing.expect(result.sent_quit);
}

test "ConPTY initially displays a real external command view" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path);
    try repo.write("Example.cs", "before-renderer\n");
    try repo.commit();
    try repo.write("Example.cs", "after-renderer\n");
    try repo.write(".git/xdg/lantana/renderers.json",
        \\[{"patterns":["*.cs"],"command":["git","hash-object","{before}","{after}"]}]
    );
    // Windows must exercise command launch and document display, not just compile the plugin code.
    const result = try @import("windows_conpty_support.zig").runConPtyWithExpected(arena, std.testing.io, &repo, "q", "e54b134d78723b029c3a968a4526f6715e57721b");
    try std.testing.expect(result.sent_quit);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "56ab913d6909e97bdd76f652f1431a2c49304120") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "before-renderer") == null);
}
