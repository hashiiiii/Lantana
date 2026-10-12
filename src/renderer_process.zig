const std = @import("std");
const builtin = @import("builtin");

const WindowsJob = struct {
    const windows = std.os.windows;
    extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(windows.HANDLE, windows.UINT) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryInformationJobObject(windows.HANDLE, c_int, *anyopaque, windows.DWORD, ?*windows.DWORD) callconv(.winapi) windows.BOOL;

    const Accounting = extern struct {
        total_user_time: i64,
        total_kernel_time: i64,
        period_user_time: i64,
        period_kernel_time: i64,
        page_faults: u32,
        total_processes: u32,
        active_processes: u32,
        terminated_processes: u32,
    };

    fn terminate(job: windows.HANDLE) void {
        if (!TerminateJobObject(job, 1).toBool()) std.debug.panic("Could not terminate renderer job: {t}", .{windows.GetLastError()});
    }

    fn wait(job: windows.HANDLE) void {
        while (true) {
            var accounting: Accounting = undefined;
            if (!QueryInformationJobObject(job, 1, &accounting, @sizeOf(Accounting), null).toBool())
                std.debug.panic("Could not query renderer job: {t}", .{windows.GetLastError()});
            if (accounting.active_processes == 0) return;
            const interval: windows.LARGE_INTEGER = -10 * 10_000;
            _ = windows.ntdll.NtDelayExecution(.FALSE, &interval);
        }
    }
};

fn terminate(child_id: std.process.Child.Id, job: ?std.os.windows.HANDLE) void {
    if (builtin.os.tag == .windows) {
        WindowsJob.terminate(job.?);
    } else {
        std.posix.kill(-child_id, .KILL) catch {};
    }
}

pub fn run(arena: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) !std.process.RunResult {
    const job: ?std.os.windows.HANDLE = if (builtin.os.tag == .windows)
        WindowsJob.CreateJobObjectW(null, null) orelse return std.os.windows.unexpectedError(std.os.windows.GetLastError())
    else
        null;
    defer if (builtin.os.tag == .windows) std.os.windows.CloseHandle(job.?);
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
        .pgid = if (builtin.os.tag == .windows) null else 0,
        .start_suspended = builtin.os.tag == .windows,
    });
    errdefer child.kill(io);
    const child_id = child.id.?;
    if (builtin.os.tag == .windows and !WindowsJob.AssignProcessToJobObject(job.?, child_id).toBool())
        return std.os.windows.unexpectedError(std.os.windows.GetLastError());
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout.close(io);
    defer stderr.close(io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ stdout, stderr });
    defer reader.deinit();
    // Descendants may retain output pipes or snapshot files after their launcher exits.
    defer {
        terminate(child_id, job);
        child.kill(io);
        if (builtin.os.tag == .windows) WindowsJob.wait(job.?);
    }
    if (builtin.os.tag == .windows) {
        const resumed = std.os.windows.ntdll.NtResumeThread(child.thread_handle, null);
        if (resumed != .SUCCESS) return std.os.windows.unexpectedStatus(resumed);
    }
    while (reader.fill(64, options.timeout)) |_| {
        if (reader.reader(0).buffered().len > options.stdout_limit.toInt().? or reader.reader(1).buffered().len > options.stderr_limit.toInt().?) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const Event = union(enum) { exit: std.process.Child.WaitError!std.process.Child.Term, timeout: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    defer while (select.cancel()) |_| {};
    // A timeout must release the child wait before its cancellation is joined.
    errdefer terminate(child_id, job);
    try select.concurrent(.exit, std.process.Child.wait, .{ &child, io });
    try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ options.timeout, io });
    const term = switch (try select.await()) {
        .exit => |value| try value,
        .timeout => return error.Timeout,
    };
    return .{ .term = term, .stdout = try reader.toOwnedSlice(0), .stderr = try reader.toOwnedSlice(1) };
}

test "renderer processes enforce output and elapsed time limits" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    // Even a normal tool must not exceed the configured output allowance.
    try std.testing.expectError(error.StreamTooLong, run(arena, std.testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdout_limit = .limited(1),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{ .clock = .awake, .raw = .fromSeconds(5) }) },
    }));
    if (builtin.os.tag == .windows) return;
    // Closed output streams cannot bypass the deadline by moving the hang into child.wait.
    const started = std.Io.Clock.now(.awake, std.testing.io);
    try std.testing.expectError(error.Timeout, run(arena, std.testing.io, .{
        .argv = &.{ "sh", "-c", "exec 1>&- 2>&-; exec sleep 5" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .deadline = started.addDuration(.fromMilliseconds(50)).withClock(.awake) },
    }));
    try std.testing.expect(started.durationTo(std.Io.Clock.now(.awake, std.testing.io)).nanoseconds < 4 * std.time.ns_per_s);
}
