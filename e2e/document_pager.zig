const std = @import("std");
const cli = @import("cli");
const lantana = @import("lantana");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--embedded-keymap")) {
        const arena = init.arena.allocator();
        var patch: std.ArrayList(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const count = std.Io.File.stdin().readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            try patch.appendSlice(arena, chunk[0..count]);
        }
        var bindings = (try lantana.Keymap.load(arena, lantana.keymap.specification, "[global]\nquit=[\"x\"]\n")).bindings;
        defer bindings.deinit();
        try lantana.run(arena, patch.items, .{
            .io = init.io,
            .environ = init.environ_map,
            .renderer = .{ .render = renderDocument },
            .keymap = &bindings,
        });
        return 0;
    }
    return cli.run(init, .{ .render = renderDocument });
}

fn renderDocument(_: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!lantana.Document {
    const path = file.new_path orelse file.old_path orelse return .{ .unavailable = "No path" };
    if (!std.mem.endsWith(u8, path, ".prefab")) return .{ .unavailable = "No document for this file" };
    return .{ .text = try std.fmt.allocPrint(
        arena,
        "\x1b[1;36mDocument for {s}\x1b[0m\nOld blob: {s}\nNew blob: {s}\n\n{s}",
        .{ path, file.old_blob orelse "unknown", file.new_blob orelse "unknown", file.patch },
    ) };
}
