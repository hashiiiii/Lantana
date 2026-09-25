const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const WinInput = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn WriteConsoleInputW(
        input: std.os.windows.HANDLE,
        records: *const vaxis.tty.WindowsTty.INPUT_RECORD,
        count: std.os.windows.DWORD,
        written: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

pub const Session = struct {
    app: vaxis.vxfw.App,
    console: ConsoleRedirect,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, environ: *std.process.Environ.Map, buffer: []u8) !Session {
        var console = try ConsoleRedirect.init(io);
        errdefer console.abort(io);
        const tty = try vaxis.Tty.init(io, buffer);
        console.transferred = true;
        const vx = vaxis.init(io, allocator, environ, .{}) catch |err| {
            tty.deinit();
            return err;
        };
        return .{ .app = .{
            .io = io,
            .allocator = allocator,
            .tty = tty,
            .vx = vx,
            .timers = .empty,
            .wants_focus = null,
        }, .console = console };
    }

    pub fn deinit(self: *Session) void {
        self.app.deinit();
        self.console.restore();
    }

    pub fn wakeInputOnQuit(self: *Session) !void {
        if (builtin.os.tag == .windows) {
            // Vaxis waits for its blocking console reader after a quit event.
            // A focus record wakes it without leaving a character for the shell.
            var record: vaxis.tty.WindowsTty.INPUT_RECORD = std.mem.zeroes(vaxis.tty.WindowsTty.INPUT_RECORD);
            record.EventType = 0x0010;
            record.Event.FocusEvent.bSetFocus = std.os.windows.BOOL.TRUE;
            var written: std.os.windows.DWORD = 0;
            if (WinInput.WriteConsoleInputW(self.console.input.?.handle, &record, 1, &written) == .FALSE or written != 1)
                return error.ConsoleWakeFailed;
        }
    }
};

const ConsoleRedirect = struct {
    active: bool = false,
    transferred: bool = false,
    original_input: ?std.os.windows.HANDLE = null,
    original_output: ?std.os.windows.HANDLE = null,
    input: ?std.Io.File = null,
    output: ?std.Io.File = null,

    fn init(io: std.Io) !ConsoleRedirect {
        if (builtin.os.tag != .windows) return .{};
        // Zig's Windows path conversion does not resolve bare console device names.
        const input = try std.Io.Dir.cwd().openFile(io, "\\\\.\\CONIN$", .{ .mode = .read_write });
        errdefer input.close(io);
        const output = try std.Io.Dir.cwd().openFile(io, "\\\\.\\CONOUT$", .{ .mode = .read_write });
        const parameters = std.os.windows.peb().ProcessParameters;
        const self: ConsoleRedirect = .{
            .active = true,
            .original_input = parameters.hStdInput,
            .original_output = parameters.hStdOutput,
            .input = input,
            .output = output,
        };
        parameters.hStdInput = input.handle;
        parameters.hStdOutput = output.handle;
        return self;
    }

    fn abort(self: *ConsoleRedirect, io: std.Io) void {
        if (!self.active) return;
        self.restore();
        if (!self.transferred) {
            self.input.?.close(io);
            self.output.?.close(io);
        }
    }

    fn restore(self: *ConsoleRedirect) void {
        if (!self.active) return;
        const parameters = std.os.windows.peb().ProcessParameters;
        parameters.hStdInput = self.original_input.?;
        parameters.hStdOutput = self.original_output.?;
        self.active = false;
    }
};
