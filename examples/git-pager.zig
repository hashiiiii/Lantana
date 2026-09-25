const std = @import("std");
const lantana = @import("lantana");
const GitContext = @import("git_context.zig").GitContext;

const max_patch_bytes = 32 * 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const demo_document = args.len == 2 and std.mem.eql(u8, args[1], "--demo-document");
    if (args.len > 2 or (args.len == 2 and !demo_document)) return error.InvalidArguments;
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

    var git_context: GitContext = .{ .io = init.io };
    lantana.run(arena, bytes.items, .{
        .io = init.io,
        .environ = init.environ_map,
        .renderer = if (demo_document) .{ .render = renderDemoDocument } else null,
        .file_text = .{ .context = &git_context, .load = GitContext.load },
    }) catch |err| {
        var output_buffer: [4096]u8 = undefined;
        var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);
        try output.interface.writeAll(bytes.items);
        try output.interface.flush();
        std.log.err("terminal unavailable: {s}", .{@errorName(err)});
        return 2;
    };
    return 0;
}

fn renderDemoDocument(_: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!lantana.Document {
    const path = file.new_path orelse file.old_path orelse return .{ .unavailable = "No path" };
    if (!std.mem.endsWith(u8, path, ".prefab")) return .{ .unavailable = "No document for this file" };
    return .{ .text = try std.fmt.allocPrint(
        arena,
        "\x1b[1;36mDocument for {s}\x1b[0m\nOld blob: {s}\nNew blob: {s}\n\n{s}",
        .{ path, file.old_blob orelse "unknown", file.new_blob orelse "unknown", file.patch },
    ) };
}
