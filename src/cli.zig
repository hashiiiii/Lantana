const std = @import("std");
const lantana = @import("lantana");
const git_config = @import("git_config.zig");
const version = @import("build_options").version;
const GitContext = @import("git_context.zig").GitContext;

const max_patch_bytes = 32 * 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try writeOutput(init.io, try std.fmt.allocPrint(arena, "lantana {s}\n", .{version}));
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeOutput(init.io,
            \\Usage: lantana [--version | --help | setup [--project | --local | --user] | unset [--project | --local | --user]]
            \\       git diff | lantana
            \\
            \\Read a Git patch from standard input and show it in the terminal.
            \\setup configures Git's diff pager; unset removes that setting.
            \\
        );
        return 0;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "setup") or std.mem.eql(u8, args[1], "unset"))) {
        const action: git_config.Action = if (std.mem.eql(u8, args[1], "setup")) .setup else .unset;
        const scope: git_config.Scope = if (args.len == 2 or (args.len == 3 and std.mem.eql(u8, args[2], "--local")))
            .local
        else if (args.len == 3 and std.mem.eql(u8, args[2], "--project"))
            .project
        else if (args.len == 3 and std.mem.eql(u8, args[2], "--user"))
            .user
        else {
            std.log.err("expected setup or unset with --project, --local, or --user", .{});
            return 2;
        };
        const result = git_config.apply(arena, init.io, action, scope) catch |err| {
            switch (err) {
                error.ExistingPager => std.log.err("pager.diff already has a setting in this scope", .{}),
                error.NotLantanaPager => std.log.err("pager.diff is not set to lantana in this scope", .{}),
                error.MultipleValues => std.log.err("Git configuration has multiple values for the same setting", .{}),
                error.RequiresRepository => std.log.err("project setup requires a Git working tree", .{}),
                else => std.log.err("Git configuration failed: {s}", .{@errorName(err)}),
            }
            return 2;
        };
        if (result == .changed) {
            const message = if (scope == .project)
                (if (action == .setup)
                    "Set pager.diff to lantana for this clone. Commit .lantana.gitconfig to share the choice.\n"
                else
                    "Removed the project setting and this clone's Lantana diff pager.\n")
            else if (action == .setup)
                try std.fmt.allocPrint(arena, "Set pager.diff to lantana in {s} Git configuration.\n", .{@tagName(scope)})
            else
                try std.fmt.allocPrint(arena, "Removed pager.diff from {s} Git configuration.\n", .{@tagName(scope)});
            try writeOutput(init.io, message);
        }
        return 0;
    }
    const demo_document = args.len == 2 and std.mem.eql(u8, args[1], "--demo-document");
    if (args.len > 2 or (args.len == 2 and !demo_document)) {
        std.log.err("unknown arguments; run lantana --help", .{});
        return 2;
    }
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

fn writeOutput(io: std.Io, message: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try output.interface.writeAll(message);
    try output.interface.flush();
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
