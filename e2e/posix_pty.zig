const std = @import("std");
const Repo = @import("git_repo").Repo;
const pager_path = @import("test_options").pager_path;
const document_pager_path = @import("test_options").document_pager_path;
const pty = @import("posix_pty_support.zig");
const Session = pty.Session;
const runDetached = pty.runDetached;
const bodyRows = pty.bodyRows;

fn changedRepo(arena: std.mem.Allocator, name: []const u8, before: []const u8, after: []const u8) !Repo {
    var repo = try Repo.init(arena, std.testing.io);
    errdefer repo.deinit();
    try repo.setPager(pager_path);
    try repo.write(name, before);
    try repo.commit();
    try repo.write(name, after);
    return repo;
}

fn expectUnchanged(repo: *Repo, status: []const u8, config: []const u8) !void {
    try std.testing.expectEqualStrings(status, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config, try repo.read(".git/config"));
}

fn cellColumn(frame: []const u8, needle: []const u8) !usize {
    var lines = std.mem.splitScalar(u8, frame, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, needle)) |position|
            return std.unicode.utf8CountCodepoints(line[0..position]);
    }
    return error.MissingFrameText;
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
    try session.waitFor("before");
    try session.finish();
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "Example.cs") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "\x1b[?1049h") != null);
    try expectUnchanged(&repo, status_before, config_before);
}

test "setup makes plain git diff launch Lantana" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.write("Example.cs", "before\n");
    try repo.commit();
    try repo.write("Example.cs", "after\n");
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, pager_path, arena);
    const result = try std.process.run(arena, std.testing.io, .{
        .argv = &.{ executable, "setup", "--local" },
        .cwd = .{ .dir = repo.temp.dir },
    });
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expectEqualStrings("lantana\n", try repo.git(&.{ "config", "--local", "--get", "pager.diff" }));
    const config = try repo.read(".git/config");
    var session = try Session.startPlainDiff(arena, std.testing.io, &repo);
    defer session.abort();
    try session.waitFor("before");
    try session.finish();
    try std.testing.expect(std.mem.indexOf(u8, session.transcript.items, "\x1b[?1049h") != null);
    // Running the configured pager must leave the Git settings and working file intact.
    try std.testing.expectEqualStrings(config, try repo.read(".git/config"));
    try std.testing.expectEqualStrings("after\n", try repo.read("Example.cs"));
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
    const frame = try session.waitFrame("before", 0);
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
    const frame = try session.waitFrame("end [no newline]", 0);
    try std.testing.expect(std.mem.indexOf(u8, frame, "end [no newline]") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "tab indentation remains distinct from spaces after horizontal panning" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "A.cs", "\tbefore() with enough text to pan\n", "\tafter() with enough text to pan\n");
    defer repo.deinit();
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const frame = try session.waitFrame("→   after()", 0);
    // The arrow marks a source tab even when its remaining cells are spaces.
    try std.testing.expect(std.mem.indexOf(u8, frame, "→   after()") != null);
    const mark = session.screen.frame;
    try session.send("\rl");
    const panned = try session.waitFrame("after()", mark);
    try std.testing.expect(std.mem.indexOf(u8, panned, "   after()") != null);
    try std.testing.expect(std.mem.indexOf(u8, panned, "→") == null);
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
    _ = try session.waitFrame("after", 0);
    var mark = session.screen.frame;
    try session.send("c");
    _ = try session.waitFrame("No changed files", mark);
    mark = session.screen.frame;
    try session.send("c");
    const reopened = try session.waitFrame("after", mark);
    try std.testing.expect(std.mem.indexOf(u8, reopened, "A.cs") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "folder focus and pane keys keep the quit dialog cancellable" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var before: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    for (0..60) |index| {
        try before.appendSlice(arena, try std.fmt.allocPrint(arena, "old line {d:0>2}\n", .{index}));
        try after.appendSlice(arena, try std.fmt.allocPrint(arena, "new line {d:0>2}\n", .{index}));
    }
    var repo = try changedRepo(arena, "Assets/A.cs", before.items, after.items);
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("new line 00", 0);

    var mark = session.screen.frame;
    try session.send("\x1b[A\x1b[D");
    _ = try session.waitFrame("󰉋 Assets", mark);
    mark = session.screen.frame;
    try session.send("\x1b[C");
    _ = try session.waitFrame(" Assets", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B\r\x1b[6~");
    _ = try session.waitFrame("new line 30", mark);
    mark = session.screen.frame;
    try session.send("\x1b");
    _ = try session.waitFrame("A.cs", mark);
    mark = session.screen.frame;
    try session.send("\x1b");
    const dialog = try session.waitFrame("Quit Lantana?", mark);
    // The prompt belongs at the terminal center without a second, unrelated explanation.
    try std.testing.expectEqual(@as(usize, 33), try cellColumn(dialog, "Quit Lantana?"));
    try std.testing.expect(std.mem.indexOf(u8, dialog, "Review is read-only.") == null);
    mark = session.screen.frame;
    try session.send("\r");
    const restored = try session.waitFrame("A.cs", mark);
    try std.testing.expect(std.mem.indexOf(u8, restored, "Quit Lantana?") == null);
    // Confirm must end the real pager; a direct q would hide a broken dialog choice.
    mark = session.screen.frame;
    try session.send("\x1b");
    _ = try session.waitFrame("Quit Lantana?", mark);
    try session.finishAfterInput("\x1b[C\r");
}

test "file change counts and draggable pane dividers stay aligned" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "Example.cs", "before-one\n", "after-one\n");
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const initial = try session.waitFrame("after-one", 0);
    var lines = std.mem.splitScalar(u8, initial, '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "Example.cs") != null);
    // Adjacent counts and source rows keep the file header compact.
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "+1 -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "after-one") != null);
    const original_before = try cellColumn(initial, "before-one");
    const original_after = try cellColumn(initial, "after-one");

    // Dragging the shared outer border changes both source columns.
    var mark = session.screen.frame;
    try session.drag(.{ .col = 28, .row = 10 }, .{ .col = 36, .row = 10 });
    const wider_tree = try session.waitFrame("after-one", mark);
    const moved_before = try cellColumn(wider_tree, "before-one");
    const moved_after = try cellColumn(wider_tree, "after-one");
    try std.testing.expect(moved_before > original_before);
    try std.testing.expect(moved_after > original_after);

    // The inner border changes only the After column; Before remains anchored.
    mark = session.screen.frame;
    try session.drag(.{ .col = 58, .row = 10 }, .{ .col = 64, .row = 10 });
    const wider_before = try session.waitFrame("after-one", mark);
    try std.testing.expectEqual(moved_before, try cellColumn(wider_before, "before-one"));
    const final_after = try cellColumn(wider_before, "after-one");
    try std.testing.expect(final_after > moved_after);
    // Selection must follow the moved source column rather than the old split position.
    try session.drag(.{ .col = final_after + 1, .row = 3 }, .{ .col = final_after + 5, .row = 3 });
    try session.waitClipboard("after");
    // Extreme drags and a narrow terminal must leave the header and both panes usable.
    mark = session.screen.frame;
    try session.drag(.{ .col = 36, .row = 10 }, .{ .col = 80, .row = 10 });
    _ = try session.waitFrame("+1 -1", mark);
    mark = session.screen.frame;
    try session.resize(32, 8);
    const narrow = try session.waitFrame("+1 -1", mark);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "Example.cs") != null);
    try session.finish();
}

test "horizontal panning stops when the longest source reaches its pane edge" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const padding = [_]u8{'x'} ** 40;
    const before = try std.fmt.allocPrint(arena, "before-{s}-END\n", .{padding});
    var repo = try changedRepo(arena, "WideBefore.cs", before, "after\n");
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("before-", 0);

    // Unequal pane widths require each side's visible width when finding the end position.
    var mark = session.screen.frame;
    try session.drag(.{ .col = 54, .row = 10 }, .{ .col = 65, .row = 10 });
    _ = try session.waitFrame("before-", mark);
    mark = session.screen.frame;
    try session.send("\r\x1b[<67;70;10M");
    _ = try session.waitFrame("━", mark);
    mark = session.screen.frame;
    try session.send("\x1b[<0;79;23M\x1b[<0;79;23m");
    const end = try session.waitFrame("-END", mark);
    try std.testing.expectEqual(@as(usize, 64), (try cellColumn(end, "END")) + 3);

    // Repeated Right input must not reveal blank space beyond the last source column.
    mark = session.screen.frame;
    try session.send("l");
    const at_limit = try session.waitFrame("-END", mark);
    try std.testing.expectEqual(@as(usize, 64), (try cellColumn(at_limit, "END")) + 3);
    try session.finish();
}

test "a folded unchanged range reveals real file lines when clicked" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var before: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    for (0..60) |index| {
        try before.appendSlice(arena, try std.fmt.allocPrint(arena, "line {d:0>2}\n", .{index}));
        try after.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} {d:0>2}\n", .{ if (index == 2 or index == 49) "changed" else "line", index }));
    }
    var repo = try changedRepo(arena, "A.cs", before.items, after.items);
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    const initial = try session.waitFrame("unchanged lines", 0);
    try std.testing.expect(std.mem.indexOf(u8, initial, "line 07") == null);
    const position = std.mem.indexOf(u8, initial, "unchanged lines") orelse return error.MissingFold;
    const row = std.mem.count(u8, initial[0..position], "\n") + 1;
    const click = try std.fmt.allocPrint(arena, "\x1b[<0;40;{d}M\x1b[<0;40;{d}m", .{ row, row });
    const mark = session.screen.frame;
    try session.send(click);
    _ = try session.waitFrame("line 07", mark);
    try session.finish();
}

test "the floating scrollbar can jump to the end of a long diff" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var before: std.ArrayList(u8) = .empty;
    var after: std.ArrayList(u8) = .empty;
    for (0..80) |index| {
        try before.appendSlice(arena, try std.fmt.allocPrint(arena, "old line {d:0>2}\n", .{index}));
        try after.appendSlice(arena, try std.fmt.allocPrint(arena, "new line {d:0>2}\n", .{index}));
    }
    var repo = try changedRepo(arena, "A.cs", before.items, after.items);
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("new line 00", 0);
    try session.send("\r\x1b[<65;70;10M");
    const mark = session.screen.frame;
    try session.send("\x1b[<0;79;23M\x1b[<0;79;23m");
    _ = try session.waitFrame("new line 79", mark);
    const drag_mark = session.screen.frame;
    // Dragging continues after the pointer leaves the narrow scrollbar column.
    try session.send("\x1b[<0;79;23M\x1b[<32;75;2M\x1b[<0;75;2m");
    _ = try session.waitFrame("new line 00", drag_mark);
    try session.finish();
}

test "horizontal trackpad scrolling reveals a draggable bottom scrollbar" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const padding = [_]u8{'x'} ** 100;
    const before = try std.fmt.allocPrint(arena, "before-{s}-END\n", .{padding});
    const after = try std.fmt.allocPrint(arena, "after-{s}-END\n", .{padding});
    var repo = try changedRepo(arena, "Wide.cs", before, after);
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("after-", 0);

    // A real SGR wheel event catches missing mouse handling that keyboard panning cannot.
    const mark = session.screen.frame;
    try session.send("\r\x1b[<67;70;10M");
    const panned = try session.waitFrame("━", mark);
    try std.testing.expect(std.mem.indexOf(u8, panned, "er-") != null);
    try std.testing.expect(std.mem.indexOf(u8, panned, "after-") == null);

    // The bar must reach the end and return to the start through real mouse input.
    var next = session.screen.frame;
    try session.send("\x1b[<0;79;23M\x1b[<0;79;23m");
    _ = try session.waitFrame("-END", next);
    next = session.screen.frame;
    try session.send("\x1b[<0;79;23M\x1b[<32;29;23M\x1b[<0;29;23m");
    _ = try session.waitFrame("after-", next);
    try session.finish();
}

test "dragging diff text copies source lines without line numbers" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try changedRepo(arena, "Example.cs", "before α\tend\nsecond old\n", "after α\tend\nsecond new\n");
    defer repo.deinit();
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("after α", 0);

    // The selected source retains its tab and newline without the line-number gutter.
    try session.drag(.{ .col = 60, .row = 3 }, .{ .col = 64, .row = 4 });
    try session.waitClipboard("after α\tend\nsecon");
    try session.finish();
}

test "mouse wheel scroll can move the selected file outside the visible tree" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path);
    for (0..30) |index| try repo.write(try std.fmt.allocPrint(arena, "{d:0>2}.cs", .{index}), "before\n");
    try repo.commit();
    for (0..30) |index| try repo.write(try std.fmt.allocPrint(arena, "{d:0>2}.cs", .{index}), "after\n");
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("after", 0);
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

test "Git pager shows added deleted renamed binary mode and quoted path changes" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(pager_path);
    _ = try repo.git(&.{ "config", "core.quotePath", "true" });
    _ = try repo.git(&.{ "config", "diff.renames", "true" });
    try repo.write("Assets/Delete.prefab", "deleted\n");
    try repo.write("Assets/Variant.prefab", "same content\n");
    try repo.write("Assets/Launch.sh", "#!/bin/sh\n");
    try repo.write("Images/Preview.png", "\x89PNG\x00before");
    try repo.write("Notes/日本語 file.cs", "before\n");
    try repo.commit();

    // A single real Git patch checks that metadata-only and quoted sections reach the live viewer.
    try repo.temp.dir.deleteFile(repo.io, "Assets/Delete.prefab");
    try repo.temp.dir.rename("Assets/Variant.prefab", repo.temp.dir, "Assets/Alternate.prefab", repo.io);
    _ = try repo.git(&.{ "add", "-N", "Assets/Alternate.prefab" });
    {
        var script = try repo.temp.dir.openFile(repo.io, "Assets/Launch.sh", .{ .mode = .read_write });
        defer script.close(repo.io);
        try script.setPermissions(repo.io, .executable_file);
    }
    try repo.write("Assets/New.meta", "guid: new\n");
    _ = try repo.git(&.{ "add", "-N", "Assets/New.meta" });
    try repo.write("Images/Preview.png", "\x89PNG\x00after");
    try repo.write("Notes/日本語 file.cs", "after\n");
    const status = try repo.git(&.{ "status", "--porcelain=v1" });
    const config = try repo.read(".git/config");

    var session = try Session.start(arena, std.testing.io, &repo, false);
    defer session.abort();
    _ = try session.waitFrame("rename from Assets/Variant.prefab", 0);
    var mark = session.screen.frame;
    try session.send("\x1b[B");
    _ = try session.waitFrame("deleted", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B");
    _ = try session.waitFrame("old mode", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B");
    _ = try session.waitFrame("guid: new", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B\x1b[B");
    _ = try session.waitFrame("Binary files", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B\x1b[B");
    const quoted = try session.waitFrame("after", mark);
    try std.testing.expect(std.mem.indexOf(u8, quoted, "file.cs") != null);
    try session.finish();
    try expectUnchanged(&repo, status, config);
}

test "Git viewer navigates document raw tree mouse and resize without changing the repository" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.setPager(document_pager_path);
    var many_lines: std.ArrayList(u8) = .empty;
    for (0..30) |index| try many_lines.appendSlice(arena, try std.fmt.allocPrint(arena, "value {d}\n", .{index}));
    try repo.write("Assets/A.prefab", many_lines.items);
    try repo.write("Assets/B.meta", "guid: before\n");
    try repo.write("Scripts/C.cs", "class C { int value = 1; }\n");
    try repo.write("Image.png", "\x89PNG\x00before");
    try repo.commit();
    many_lines.clearRetainingCapacity();
    for (0..30) |index| try many_lines.appendSlice(arena, try std.fmt.allocPrint(arena, "value {d} after with enough text to pan\n", .{index}));
    try repo.write("Assets/A.prefab", many_lines.items);
    try repo.write("Assets/B.meta", "guid: after\n");
    try repo.write("Scripts/C.cs", "class C { int value = 2; }\n");
    try repo.write("Image.png", "\x89PNG\x00after");
    const status_before = try repo.git(&.{ "status", "--porcelain=v1" });
    const config_before = try repo.read(".git/config");
    var session = try Session.start(arena, std.testing.io, &repo, true);
    defer session.abort();

    const initial = try session.waitFrame("   1│value 0", 0);
    try std.testing.expect(std.mem.indexOf(u8, initial, "Document for") == null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "Scripts") != null);
    var mark = session.screen.frame;
    try session.send("m");
    _ = try session.waitFrame("Document for Assets/A.prefab", mark);
    // Document text must copy without its SGR styles or the surrounding pane.
    try session.drag(.{ .col = 29, .row = 3 }, .{ .col = 36, .row = 3 });
    try session.waitClipboard("Document");
    mark = session.screen.frame;
    try session.send("m");
    _ = try session.waitFrame("   1│value 0", mark);
    mark = session.screen.frame;
    try session.send("jj");
    const before_pan = try session.waitFrame("value 22 after", mark);
    mark = session.screen.frame;
    try session.send("ll");
    const after_pan = try session.waitFrame("lue 22 after", mark);
    // A changed offset label alone would not prove that the source columns moved.
    try std.testing.expect(!std.mem.eql(u8, bodyRows(before_pan), bodyRows(after_pan)));
    mark = session.screen.frame;
    try session.send("\x1b");
    _ = try session.waitFrame("A.prefab", mark);
    mark = session.screen.frame;
    try session.send("\x1b[B");
    const metadata = try session.waitFrame("Assets/B.meta", mark);
    // Missing optional documents must not add unrelated text beneath the raw diff.
    try std.testing.expect(std.mem.indexOf(u8, metadata, "No document for this file") == null);
    mark = session.screen.frame;
    try session.send("c");
    const binary = try session.waitFrame("Image.png", mark);
    try std.testing.expect(std.mem.indexOf(u8, binary, "Binary files") != null);
    mark = session.screen.frame;
    try session.send("\x1b[B\x1b[B\x1b[B");
    _ = try session.waitFrame("Scripts/C.cs", mark);
    mark = session.screen.frame;
    try session.send("\x1b[<0;8;2M\x1b[<0;8;2m\x1b[<0;8;3M\x1b[<0;8;3m");
    _ = try session.waitFrame("A.prefab", mark);
    mark = session.screen.frame;
    try session.send("\x1b[<0;8;4M\x1b[<0;8;4m");
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
