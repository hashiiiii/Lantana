const std = @import("std");
const cli = @import("cli");
const lantana = @import("lantana");

pub fn main(init: std.process.Init) !u8 {
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
