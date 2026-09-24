const std = @import("std");
const lantana = @import("lantana");

const max_patch_bytes = 32 * 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bytes: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const count = std.Io.File.stdin().readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (bytes.items.len + count > max_patch_bytes) return error.PatchTooLarge;
        try bytes.appendSlice(arena, chunk[0..count]);
    }
    if (bytes.items.len == 0) return 0;

    lantana.run(arena, bytes.items, .{ .io = init.io, .environ = init.environ_map }) catch |err| {
        var output_buffer: [4096]u8 = undefined;
        var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
        try output.interface.writeAll(bytes.items);
        try output.interface.flush();
        std.log.err("terminal unavailable: {s}", .{@errorName(err)});
        return 2;
    };
    return 0;
}
