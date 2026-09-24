const std = @import("std");
const Repo = @import("git_repo.zig").Repo;
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
    try repo.setPager(pager_path, false);
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    const result = try runConPty(arena, std.testing.io, &repo);
    try std.testing.expect(result.sent_quit);
    try std.testing.expect(result.exit_code == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "\x1b[?1049l") != null);
    try std.testing.expectEqualStrings(status_before, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config_before, try repo.read(".git/config"));
    try std.testing.expectEqualStrings("after\n", try repo.read("Example.cs"));
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, pager_path, arena);
    const empty = try std.process.run(arena, std.testing.io, .{ .argv = &.{executable} });
    try std.testing.expectEqual(@as(u8, 0), empty.term.exited);
    try std.testing.expectEqualStrings("", empty.stdout);
}
