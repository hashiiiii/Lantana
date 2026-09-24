const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: *std.process.Environ.Map, patch_size: usize) !void {
    const label = try std.fmt.allocPrint(allocator, "PATCH BYTES: {d}", .{patch_size});
    defer allocator.free(label);

    var buffer: [4096]u8 = undefined;
    const tty = try vaxis.Tty.init(io, &buffer);
    const vx = vaxis.init(io, allocator, environ, .{}) catch |err| {
        tty.deinit();
        return err;
    };
    var app: vxfw.App = .{
        .io = io,
        .allocator = allocator,
        .tty = tty,
        .vx = vx,
        .timers = .empty,
        .wants_focus = null,
    };
    defer app.deinit();
    var view: View = .{ .label = label };
    try app.run(view.widget(), .{});
}

const View = struct {
    label: []const u8,

    fn widget(self: *View) vxfw.Widget {
        return .{ .userdata = self, .eventHandler = event, .drawFn = draw };
    }

    fn event(_: *anyopaque, ctx: *vxfw.EventContext, value: vxfw.Event) !void {
        switch (value) {
            .key_press => |key| {
                if (key.matches('q', .{})) ctx.quit = true;
            },
            else => {},
        }
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *View = @ptrCast(@alignCast(userdata));
        const size: vxfw.Size = .{ .width = ctx.max.width orelse ctx.min.width, .height = ctx.max.height orelse ctx.min.height };
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        if (size.height < 2 or size.width < 3) return surface;
        for (self.label, 0..) |_, index| {
            const column = index + 2;
            if (column >= size.width) break;
            surface.writeCell(@intCast(column), 1, .{ .char = .{ .grapheme = self.label[index .. index + 1], .width = 1 } });
        }
        return surface;
    }
};
