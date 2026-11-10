const std = @import("std");
const builtin = @import("builtin");
const Repo = @import("git_repo").Repo;
const Screen = @import("terminal_screen").Screen;
const pager_path = @import("test_options").pager_path;

const c = std.c;

extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, termios: ?*const c.termios, size: ?*const c.winsize) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn execl(path: [*:0]const u8, arg0: [*:0]const u8, ...) c_int;

const terminal = if (builtin.os.tag == .macos) struct {
    // Darwin's resize request sets bit 31 and ioctl takes an unsigned long.
    const set_window_size: c_ulong = 0x80087467;
    const set_controlling_terminal: c_ulong = 0x20007461;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
} else struct {
    const set_window_size = c.T.IOCSWINSZ;
    const set_controlling_terminal = c.T.IOCSCTTY;
    const ioctl = c.ioctl;
};

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
        return startWithPagination(arena, io, repo, wide_diff, true, false);
    }

    pub fn startPlainDiff(arena: std.mem.Allocator, io: std.Io, repo: *Repo) !Session {
        return startWithPagination(arena, io, repo, false, false, false);
    }

    pub fn startStagedDiff(arena: std.mem.Allocator, io: std.Io, repo: *Repo) !Session {
        return startWithPagination(arena, io, repo, false, false, true);
    }

    fn startWithPagination(arena: std.mem.Allocator, io: std.Io, repo: *Repo, wide_diff: bool, paginate: bool, staged: bool) !Session {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
        errdefer _ = c.close(master);
        errdefer _ = c.close(slave);
        const size: c.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        if (terminal.ioctl(slave, terminal.set_window_size, &size) != 0) return error.ResizeFailed;
        const repo_path = try arena.dupeSentinel(u8, repo.path, 0);
        const config_path = try arena.dupeSentinel(u8, try std.fs.path.join(arena, &.{ repo.path, ".git", "xdg" }), 0);
        const pager_executable = try std.Io.Dir.cwd().realPathFileAlloc(io, pager_path, arena);
        const pager_dir = std.fs.path.dirname(pager_executable) orelse return error.MissingPagerDirectory;
        const inherited_path: []const u8 = if (c.getenv("PATH")) |path| std.mem.span(path) else "";
        const pager_path_value = try arena.dupeSentinel(u8, try std.fmt.allocPrint(arena, "{s}:{s}", .{ pager_dir, inherited_path }), 0);
        const screen = try Screen.init(arena, 80, 24);
        const child = c.fork();
        if (child < 0) return error.ForkFailed;
        if (child == 0) {
            _ = c.close(master);
            _ = c.setsid();
            _ = terminal.ioctl(slave, terminal.set_controlling_terminal, @as(c_int, 0));
            for (0..3) |fd| _ = c.dup2(slave, @intCast(fd));
            if (slave > 2) _ = c.close(slave);
            _ = c.chdir(repo_path.ptr);
            _ = unsetenv("GIT_PAGER");
            _ = unsetenv("PAGER");
            _ = setenv("PATH", pager_path_value.ptr, 1);
            _ = setenv("TERM", "xterm-256color", 1);
            // User remappings must not affect default-key regression cases.
            _ = setenv("XDG_CONFIG_HOME", config_path.ptr, 1);
            const command = if (staged)
                "before=$(stty -g); git diff --cached; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\""
            else if (wide_diff)
                "before=$(stty -g); git --paginate diff --unified=100; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\""
            else if (!paginate)
                "before=$(stty -g); git diff; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\""
            else
                "before=$(stty -g); git --paginate diff; code=$?; after=$(stty -g); [ \"$before\" = \"$after\" ] || exit 94; exit \"$code\"";
            _ = execl("/bin/sh", "sh", "-c", command.ptr, @as(?*anyopaque, null));
            c._exit(127);
        }
        return .{ .arena = arena, .io = io, .master = master, .slave = slave, .child = child, .screen = screen };
    }

    pub fn abort(self: *Session) void {
        if (self.finished) return;
        // The shell, Git, and pager share the session group; killing only the shell leaves a pager behind.
        if (c.kill(-self.child, .KILL) != 0) _ = c.kill(self.child, .KILL);
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
        var fd = c.pollfd{ .fd = self.master, .events = c.POLL.IN, .revents = 0 };
        if (c.poll(@ptrCast(&fd), 1, 100) <= 0) return;
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
        const size: c.winsize = .{
            .row = @intCast(height),
            .col = @intCast(width),
            .xpixel = 0,
            .ypixel = 0,
        };
        if (terminal.ioctl(self.slave, terminal.set_window_size, &size) != 0) return error.ResizeFailed;
        try self.screen.resize(width, height);
    }

    pub fn waitFrame(self: *Session, expected: []const u8, after: usize) ![]const u8 {
        return self.waitFrameAtColumn(expected, null, after);
    }

    pub fn waitFrameAtColumn(self: *Session, expected: []const u8, column: ?usize, after: usize) ![]const u8 {
        const deadline = std.Io.Clock.now(.awake, self.io).nanoseconds + 8 * std.time.ns_per_s;
        while (std.Io.Clock.now(.awake, self.io).nanoseconds < deadline) {
            try self.pump();
            if (self.screen.frame > after) {
                const visible = try self.screen.text();
                if (column) |wanted| {
                    var lines = std.mem.splitScalar(u8, visible, '\n');
                    while (lines.next()) |line| {
                        const position = std.mem.indexOf(u8, line, expected) orelse continue;
                        if (try std.unicode.utf8CountCodepoints(line[0..position]) == wanted) return visible;
                    }
                } else if (std.mem.indexOf(u8, visible, expected) != null) return visible;
            }
        }
        std.log.err("missing frame text {s}; column={any}; frame={d}; screen:\n{s}", .{ expected, column, self.screen.frame, try self.screen.text() });
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
            const done = c.waitpid(self.child, &status, c.W.NOHANG);
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
    var config = std.testing.tmpDir(.{});
    defer config.cleanup();
    const config_path = try arena.dupeSentinel(u8, try config.dir.realPathFileAlloc(io, ".", arena), 0);
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
        // Detached fallback tests must not create first-run files in the developer's configuration.
        _ = setenv("XDG_CONFIG_HOME", config_path.ptr, 1);
        _ = c.close(stdin_pipe[1]);
        _ = c.close(stdout_pipe[0]);
        _ = c.dup2(stdin_pipe[0], 0);
        _ = c.dup2(stdout_pipe[1], 1);
        const null_output = c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (null_output >= 0) {
            _ = c.dup2(null_output, 2);
            _ = c.close(null_output);
        }
        _ = c.close(stdin_pipe[0]);
        _ = c.close(stdout_pipe[1]);
        _ = execl(executable.ptr, executable.ptr, @as(?*anyopaque, null));
        c._exit(127);
    }
    var reaped = false;
    errdefer if (!reaped) {
        _ = c.kill(child, .KILL);
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
        var fd = c.pollfd{ .fd = stdout_pipe[0], .events = c.POLL.IN, .revents = 0 };
        if (c.poll(@ptrCast(&fd), 1, 100) <= 0) continue;
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
