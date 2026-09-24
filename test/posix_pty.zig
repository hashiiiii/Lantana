const std = @import("std");
const builtin = @import("builtin");
const Repo = @import("git_repo.zig").Repo;
const Screen = @import("screen.zig").Screen;
const pager_path = @import("test_options").pager_path;

const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    if (builtin.os.tag == .linux) @cInclude("pty.h") else @cInclude("util.h");
});

const Session = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    master: c_int,
    slave: c_int,
    child: c.pid_t,
    screen: Screen,
    transcript: std.ArrayList(u8) = .empty,
    replies: [3]usize = .{ 0, 0, 0 },
    finished: bool = false,

    fn start(arena: std.mem.Allocator, io: std.Io, repo: *Repo, wide_diff: bool) !Session {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        if (c.openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
        errdefer _ = c.close(master);
        errdefer _ = c.close(slave);
        const size: c.struct_winsize = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (c.ioctl(slave, c.TIOCSWINSZ, &size) != 0) return error.ResizeFailed;
        const repo_path = try arena.dupeZ(u8, repo.path);
        const screen = try Screen.init(arena, 80, 24);
        const child = c.fork();
        if (child < 0) return error.ForkFailed;
        if (child == 0) {
            _ = c.close(master);
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
            for (0..3) |fd| _ = c.dup2(slave, @intCast(fd));
            if (slave > 2) _ = c.close(slave);
            _ = c.chdir(repo_path.ptr);
            _ = c.unsetenv("GIT_PAGER");
            _ = c.unsetenv("PAGER");
            _ = c.setenv("TERM", "xterm-256color", 1);
            const command = if (wide_diff)
                "before=$(stty -g); git --paginate diff --unified=100; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\""
            else
                "before=$(stty -g); git --paginate diff; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\"";
            _ = c.execl("/bin/sh", "sh", "-c", command.ptr, @as(?*anyopaque, null));
            c._exit(127);
        }
        return .{ .arena = arena, .io = io, .master = master, .slave = slave, .child = child, .screen = screen };
    }

    fn abort(self: *Session) void {
        if (self.finished) return;
        _ = c.kill(self.child, c.SIGKILL);
        var status: c_int = undefined;
        _ = c.waitpid(self.child, &status, 0);
        _ = c.close(self.master);
        _ = c.close(self.slave);
        self.finished = true;
    }

    fn send(self: *Session, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = c.write(self.master, bytes.ptr + offset, bytes.len - offset);
            if (count <= 0) return error.PtyWriteFailed;
            offset += @intCast(count);
        }
    }

    fn pump(self: *Session) !void {
        var fd = c.struct_pollfd{ .fd = self.master, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&fd, 1, 100) <= 0) return;
        var bytes: [65536]u8 = undefined;
        const count = c.read(self.master, &bytes, bytes.len);
        if (count <= 0) return;
        try self.transcript.appendSlice(self.arena, bytes[0..@intCast(count)]);
        try self.screen.feed(bytes[0..@intCast(count)]);
        const queries = [_][]const u8{ "\x1b[6n", "\x1b[?u", "\x1b[5n" };
        const answers = [_][]const u8{ "\x1b[1;1R", "\x1b[?0u\x1b[?1;2c", "\x1b[0n" };
        for (queries, answers, 0..) |query, answer, index| {
            const found = std.mem.count(u8, self.transcript.items, query);
            while (self.replies[index] < found) : (self.replies[index] += 1) try self.send(answer);
        }
    }

    fn resize(self: *Session, width: usize, height: usize) !void {
        const size: c.struct_winsize = .{
            .ws_row = @intCast(height),
            .ws_col = @intCast(width),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.slave, c.TIOCSWINSZ, &size) != 0) return error.ResizeFailed;
        try self.screen.resize(width, height);
    }

    fn waitFrame(self: *Session, expected: []const u8, after: usize) ![]const u8 {
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            if (self.screen.frame > after) {
                const visible = try self.screen.text();
                if (std.mem.indexOf(u8, visible, expected) != null) return visible;
            }
        }
        std.log.err("missing frame text {s}; frame={d}; screen:\n{s}", .{ expected, self.screen.frame, try self.screen.text() });
        return error.MissingFrameText;
    }

    fn waitFor(self: *Session, expected: []const u8) !void {
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            if (std.mem.indexOf(u8, self.transcript.items, expected) != null) return;
        }
        std.log.err("missing {s}; terminal output: {s}", .{ expected, self.transcript.items });
        return error.MissingTerminalText;
    }

    fn finish(self: *Session) !void {
        try self.send("q");
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            var status: c_int = undefined;
            const done = c.waitpid(self.child, &status, c.WNOHANG);
            if (done == self.child) {
                self.finished = true;
                _ = c.close(self.master);
                _ = c.close(self.slave);
                try std.testing.expectEqual(@as(c_int, 0), status);
                try std.testing.expect(std.mem.indexOf(u8, self.transcript.items, "\x1b[?1049l") != null);
                return;
            }
        }
        return error.PagerTimedOut;
    }
};

test "Git pager reads its pipe and restores the real terminal" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var repo = try Repo.init(arena, std.testing.io);
    defer repo.deinit();
    try repo.write("Example.cs", "before\n");
    try repo.commit();
    try repo.write("Example.cs", "after\n");
    try repo.setPager(pager_path, false);
    const patch = try repo.git(&.{ "--no-pager", "diff" });
    try std.testing.expect(patch.len > 0);
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
    try std.testing.expectEqualStrings(status_before, try repo.git(&.{ "status", "--porcelain=v1" }));
    try std.testing.expectEqualStrings(config_before, try repo.read(".git/config"));
}

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

const DetachedResult = struct { status: c_int, output: []const u8 };

fn bodyRows(frame: []const u8) []const u8 {
    var position: usize = 0;
    for (0..3) |_| {
        const next = std.mem.indexOfScalarPos(u8, frame, position, '\n') orelse return "";
        position = next + 1;
    }
    return frame[position..];
}

fn runDetached(arena: std.mem.Allocator, io: std.Io, input: []const u8) !DetachedResult {
    var stdin_pipe: [2]c_int = .{ -1, -1 };
    var stdout_pipe: [2]c_int = .{ -1, -1 };
    if (c.pipe(&stdin_pipe) != 0) return error.PipeFailed;
    errdefer {
        for (stdin_pipe) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    if (c.pipe(&stdout_pipe) != 0) return error.PipeFailed;
    errdefer {
        for (stdout_pipe) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
    }
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, pager_path, arena);
    const child = c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = c.setsid();
        _ = c.close(stdin_pipe[1]);
        _ = c.close(stdout_pipe[0]);
        _ = c.dup2(stdin_pipe[0], 0);
        _ = c.dup2(stdout_pipe[1], 1);
        const null_output = c.open("/dev/null", c.O_WRONLY);
        if (null_output >= 0) {
            _ = c.dup2(null_output, 2);
            _ = c.close(null_output);
        }
        _ = c.close(stdin_pipe[0]);
        _ = c.close(stdout_pipe[1]);
        _ = c.execl(executable.ptr, executable.ptr, @as(?*anyopaque, null));
        c._exit(127);
    }
    var reaped = false;
    errdefer if (!reaped) {
        _ = c.kill(child, c.SIGKILL);
        var ignored: c_int = undefined;
        _ = c.waitpid(child, &ignored, 0);
    };
    _ = c.close(stdin_pipe[0]);
    stdin_pipe[0] = -1;
    _ = c.close(stdout_pipe[1]);
    stdout_pipe[1] = -1;
    // The child cannot finish reading until the writer closes its input pipe.
    var written: usize = 0;
    while (written < input.len) {
        const count = c.write(stdin_pipe[1], input.ptr + written, input.len - written);
        if (count <= 0) return error.PipeWriteFailed;
        written += @intCast(count);
    }
    _ = c.close(stdin_pipe[1]);
    stdin_pipe[1] = -1;
    var output: std.ArrayList(u8) = .empty;
    const deadline = std.Io.Clock.now(.awake, io).nanoseconds + 5 * std.time.ns_per_s;
    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        var fd = c.struct_pollfd{ .fd = stdout_pipe[0], .events = c.POLLIN, .revents = 0 };
        if (c.poll(&fd, 1, 100) <= 0) continue;
        var bytes: [8192]u8 = undefined;
        const count = c.read(stdout_pipe[0], &bytes, bytes.len);
        if (count == 0) {
            _ = c.close(stdout_pipe[0]);
            stdout_pipe[0] = -1;
            var status: c_int = undefined;
            if (c.waitpid(child, &status, 0) != child) return error.WaitFailed;
            reaped = true;
            return .{ .status = status, .output = try output.toOwnedSlice(arena) };
        }
        if (count < 0) return error.PipeReadFailed;
        try output.appendSlice(arena, bytes[0..@intCast(count)]);
    }
    return error.DetachedTimedOut;
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
