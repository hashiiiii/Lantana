const std = @import("std");
const builtin = @import("builtin");
const Repo = @import("git_repo").Repo;
const Screen = @import("terminal_screen").Screen;
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

pub const Session = struct {
    pub const Point = struct { col: usize, row: usize };

    arena: std.mem.Allocator,
    io: std.Io,
    master: c_int,
    slave: c_int,
    child: c.pid_t,
    screen: Screen,
    transcript: std.ArrayList(u8) = .empty,
    replies: [3]usize = .{ 0, 0, 0 },
    finished: bool = false,

    pub fn start(arena: std.mem.Allocator, io: std.Io, repo: *Repo, wide_diff: bool) !Session {
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

    pub fn abort(self: *Session) void {
        if (self.finished) return;
        // The shell, Git, and pager share the session group; killing only the shell leaves a pager behind.
        if (c.kill(-self.child, c.SIGKILL) != 0) _ = c.kill(self.child, c.SIGKILL);
        var status: c_int = undefined;
        _ = c.waitpid(self.child, &status, 0);
        _ = c.close(self.master);
        _ = c.close(self.slave);
        self.finished = true;
    }

    pub fn send(self: *Session, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = c.write(self.master, bytes.ptr + offset, bytes.len - offset);
            if (count <= 0) return error.PtyWriteFailed;
            offset += @intCast(count);
        }
    }

    pub fn drag(self: *Session, from: Point, to: Point) !void {
        const sequence = try std.fmt.allocPrint(self.arena, "\x1b[<0;{d};{d}M\x1b[<32;{d};{d}M\x1b[<0;{d};{d}m", .{
            from.col, from.row, to.col, to.row, to.col, to.row,
        });
        try self.send(sequence);
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

    pub fn resize(self: *Session, width: usize, height: usize) !void {
        const size: c.struct_winsize = .{
            .ws_row = @intCast(height),
            .ws_col = @intCast(width),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.slave, c.TIOCSWINSZ, &size) != 0) return error.ResizeFailed;
        try self.screen.resize(width, height);
    }

    pub fn waitFrame(self: *Session, expected: []const u8, after: usize) ![]const u8 {
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

    pub fn waitFor(self: *Session, expected: []const u8) !void {
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            if (std.mem.indexOf(u8, self.transcript.items, expected) != null) return;
        }
        std.log.err("missing {s}; terminal output: {s}", .{ expected, self.transcript.items });
        return error.MissingTerminalText;
    }

    pub fn waitClipboard(self: *Session, expected: []const u8) !void {
        const encoded = try self.arena.alloc(u8, std.base64.standard.Encoder.calcSize(expected.len));
        _ = std.base64.standard.Encoder.encode(encoded, expected);
        const sequence = try std.fmt.allocPrint(self.arena, "\x1b]52;c;{s}\x1b\\", .{encoded});
        try self.waitFor(sequence);
    }

    pub fn finish(self: *Session) !void {
        try self.finishAfterInput("q");
    }

    pub fn finishAfterInput(self: *Session, input: []const u8) !void {
        try self.send(input);
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            var status: c_int = undefined;
            const done = c.waitpid(self.child, &status, c.WNOHANG);
            if (done == self.child) {
                self.finished = true;
                _ = c.close(self.master);
                _ = c.close(self.slave);
                if (status != 0) return error.PagerFailed;
                if (std.mem.indexOf(u8, self.transcript.items, "\x1b[?1049l") == null)
                    return error.TerminalNotRestored;
                return;
            }
        }
        return error.PagerTimedOut;
    }
};

pub const DetachedResult = struct { status: c_int, output: []const u8 };

pub fn bodyRows(frame: []const u8) []const u8 {
    var position: usize = 0;
    for (0..2) |_| {
        const next = std.mem.indexOfScalarPos(u8, frame, position, '\n') orelse return "";
        position = next + 1;
    }
    return frame[position..];
}

pub fn runDetached(arena: std.mem.Allocator, io: std.Io, input: []const u8) !DetachedResult {
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
