const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

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
        const input = try std.Io.Dir.cwd().openFile(io, "CONIN$", .{ .mode = .read_write });
        errdefer input.close(io);
        const output = try std.Io.Dir.cwd().openFile(io, "CONOUT$", .{ .mode = .read_write });
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
