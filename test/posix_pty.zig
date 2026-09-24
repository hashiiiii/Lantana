const std = @import("std");
const Repo = @import("git_repo.zig").Repo;
const pager_path = @import("test_options").pager_path;
const pty = @import("posix_pty_support.zig");
const Session = pty.Session;
const runDetached = pty.runDetached;
const bodyRows = pty.bodyRows;

fn changedRepo(arena: std.mem.Allocator, name: []const u8, before: []const u8, after: []const u8) !Repo {
    var repo = try Repo.init(arena, std.testing.io);
    errdefer repo.deinit();
    try repo.setPager(pager_path, false);
    try repo.write(name, before);
    try repo.commit();
    try repo.write(name, after);
    return repo;
}

fn expectUnchanged(repo: *Repo, status: []const u8, config: []const u8) !void {
    try std.testing.expectEqualStrings(status, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config, try repo.read(".git/config"));
}

test "Git pager reads its pipe and restores the real terminal" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "Example.cs", "before\n", "after\n");
    defer repo.deinit();
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    try session.waitFor("Before (-)");
    try session.finish();
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "Example.cs") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "\x1b[?1049h") != null);
    try expectUnchanged(&repo, status_before, config_before);
}

test "invalid UTF-8 remains visible and the terminal can be restored" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "A.cs", "before\n", "\xff\xcc\x81\n");
    defer repo.deinit();
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const frame = try session.waitFrame("Before (-)", 0);
    // Invalid source bytes must reach the live screen as a replacement grapheme.
    try std.testing.expect(std.mem.indexOf(u8, frame, "�") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "a detached pager returns the exact captured patch and an empty patch exits cleanly" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "Example.cs", "before\n", "after\n");
    defer repo.deinit();
    const patch = try repo.git(&.{ "--no-pager", "diff" });
    const detached = try runDetached(arena, std.testing.io, patch);
    try std.testing.expectEqual(@as(c_int, 2 << 8), detached.status);
    try std.testing.expectEqualStrings(patch, detached.output);
    try std.testing.expect(std.mem.indexOf(u8, detached.output, "\x1b[?1049h") == null);
    const empty = try runDetached(arena, std.testing.io, "");
    try std.testing.expectEqual(@as(c_int, 0), empty.status);
    try std.testing.expectEqualStrings("", empty.output);
}

test "a line without a final newline keeps its visible marker" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "A.cs", "end", "end\n");
    defer repo.deinit();
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const frame = try session.waitFrame("Before (-)", 0);
    try std.testing.expect(std.mem.indexOf(u8, frame, "end [no newline]") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "tab indentation remains distinct from spaces after horizontal panning" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "A.cs", "\tbefore()\n", "\tafter()\n");
    defer repo.deinit();
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const frame = try session.waitFrame("Before (-)", 0);
    // The arrow marks a source tab even when its remaining cells are spaces.
    try std.testing.expect(std.mem.indexOf(u8, frame, "→   after()") != null);
    const mark = session.screen.frame;
    try session.send("l");
    const panned = try session.waitFrame("x:1", mark);
    try std.testing.expect(std.mem.indexOf(u8, panned, "   after()") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "the only collapsed folder can reopen through the keyboard" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "Assets/A.cs", "before\n", "after\n");
    defer repo.deinit();
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("Before (-)", 0);
    var mark = session.screen.frame;
    try session.send("c");
    _ = try session.waitFrame("No changed files", mark);
    mark = session.screen.frame;
    try session.send("c");
    const reopened = try session.waitFrame("Before (-)", mark);
    try std.testing.expect(std.mem.indexOf(u8, reopened, "A.cs") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "mouse wheel scroll can move the selected file outside the visible tree" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path, false);
    for (0..30) |index| try repo.write(try std.fmt.allocPrint(arena, "{d:0>2}.cs", .{index}), "before\n");
    try repo.commit();
    for (0..30) |index| try repo.write(try std.fmt.allocPrint(arena, "{d:0>2}.cs", .{index}), "after\n");
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("Before (-)", 0);
    const mark = session.screen.frame;
    for (0..15) |_| try session.send("\x1b[<65;8;5M");
    const visible = try session.waitFrame("29.cs", mark);
    var lines = std.mem.splitScalar(u8, visible, '\n');
    while (lines.next()) |line| {
        // Only the tree column counts; patch text may still mention the first file.
        try std.testing.expect(std.mem.indexOf(u8, line[0..@min(28, line.len)], "00.cs") == null);
    }
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "Git viewer navigates document raw tree mouse and resize without changing the repository" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path, true);
    var many_lines: std.ArrayList(u8) = .empty;
    for (0..30) |index| try many_lines.appendSlice(arena, try std.fmt.allocPrint(arena, "value {d}\n", .{index}));
    try repo.write("Assets/A.prefab", many_lines.items);
    try repo.write("Assets/B.meta", "guid: before\n");
    try repo.write("Scripts/C.cs", "class C { int value = 1; }\n");
    try repo.write("Image.png", "\x89PNG\x00before");
    try repo.commit();
    many_lines.clearRetainingCapacity();
    for (0..30) |index| try many_lines.appendSlice(arena, try std.fmt.allocPrint(arena, "value {d} after\n", .{index}));
    try repo.write("Assets/A.prefab", many_lines.items);
    try repo.write("Assets/B.meta", "guid: after\n");
    try repo.write("Scripts/C.cs", "class C { int value = 2; }\n");
    try repo.write("Image.png", "\x89PNG\x00after");
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, true);
    defer session.abort();

    const initial = try session.waitFrame("Document for Assets/A.prefab", 0);
    try std.testing.expect(std.mem.indexOf(u8, initial, "Before (-)") == null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "Scripts") != null);
    var mark = session.screen.frame;
    try session.send("m");
    _ = try session.waitFrame("Before (-)", mark);
    mark = session.screen.frame;
    try session.send("jj");
    const before_pan = try session.waitFrame("y:2", mark);
    mark = session.screen.frame;
    try session.send("ll");
    const after_pan = try session.waitFrame("x:2", mark);
    // A changed offset label alone would not prove that the source columns moved.
    try std.testing.expect(!std.mem.eql(u8, bodyRows(before_pan), bodyRows(after_pan)));
    mark = session.screen.frame;
    try session.send("\x1b[B");
    const metadata = try session.waitFrame("Assets/B.meta", mark);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "No document for this file") != null);
    mark = session.screen.frame;
    try session.send("c");
    const binary = try session.waitFrame("Image.png", mark);
    try std.testing.expect(std.mem.indexOf(u8, binary, "Binary files") != null);
    mark = session.screen.frame;
    try session.send("\x1b[B");
    _ = try session.waitFrame("Scripts/C.cs", mark);
    mark = session.screen.frame;
    try session.send("\x1b[<0;8;3M\x1b[<0;8;3m");
    _ = try session.waitFrame("A.prefab", mark);
    mark = session.screen.frame;
    try session.send("\x1b[<0;8;5M\x1b[<0;8;5m");
    _ = try session.waitFrame("Assets/B.meta", mark);
    mark = session.screen.frame;
    try session.resize(48, 16);
    _ = try session.waitFrame("Assets/B.meta", mark);
    mark = session.screen.frame;
    try session.resize(20, 6);
    _ = try session.waitFrame("Terminal too small", mark);
    mark = session.screen.frame;
    try session.resize(80, 24);
    _ = try session.waitFrame("Assets/B.meta", mark);
    try session.finish();
    try std.testing.expectEqualStrings(status_before, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config_before, try repo.read(".git/config"));
}
