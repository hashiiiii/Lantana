const std = @import("std");
const builtin = @import("builtin");

const DemoRepo = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    fn git(self: DemoRepo, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, "git");
        try argv.appendSlice(self.arena, args);
        const result = try std.process.run(self.arena, self.io, .{
            .argv = argv.items,
            .cwd = .{ .dir = self.dir },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("git failed: {s}", .{result.stderr});
            return error.GitFailed;
        }
    }

    fn write(self: DemoRepo, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try self.dir.createDirPath(self.io, parent);
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    fn executable(self: DemoRepo, path: []const u8) !void {
        var file = try self.dir.openFile(self.io, path, .{ .mode = .read_write });
        defer file.close(self.io);
        try file.setPermissions(self.io, .executable_file);
    }
};

fn hero(arena: std.mem.Allocator, changed: bool) ![]const u8 {
    var data: std.ArrayList(u8) = .empty;
    try data.appendSlice(
        arena,
        "%YAML 1.1\n" ++
            "%TAG !u! tag:unity3d.com,2011:\n" ++
            "--- !u!1 &100\n" ++
            "GameObject:\n" ++
            "  m_Name: Hero\n",
    );
    for (0..40) |index| {
        const value = if (changed and (index == 3 or index == 36)) index + 100 else index;
        try data.appendSlice(arena, try std.fmt.allocPrint(arena, "  m_Entry{d:0>2}: {d}\n", .{ index, value }));
    }
    return data.items;
}

fn scrollFile(arena: std.mem.Allocator, changed: bool) ![]const u8 {
    var data: std.ArrayList(u8) = .empty;
    const long_text = "abcdefghijklmnopqrstuvwxyz0123456789" ** 5;
    for (0..180) |index| {
        try data.appendSlice(arena, try std.fmt.allocPrint(arena, "line {d:0>3} {s} value={d:0>4}\n", .{
            index,
            long_text,
            if (changed) index + 1000 else index,
        }));
    }
    return data.items;
}

pub fn main(init: std.process.Init) !void {
    var memory = std.heap.ArenaAllocator.init(init.gpa);
    defer memory.deinit();
    const arena = memory.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const scroll = args.len == 2 and std.mem.eql(u8, args[1], "--scroll");
    if (args.len > 2 or (args.len == 2 and !scroll)) return error.InvalidArguments;
    const destination = if (scroll) "lantana-scroll-demo" else "lantana-demo";

    var cache = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache", .{});
    defer cache.close(io);
    cache.createDir(io, destination, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists)
            std.log.err(".zig-cache/{s} already exists; keep or remove it before creating a new demo", .{destination});
        return err;
    };
    errdefer cache.deleteTree(io, destination) catch {};
    var dir = try cache.openDir(io, destination, .{});
    defer dir.close(io);
    const repo: DemoRepo = .{ .arena = arena, .io = io, .dir = dir };

    try repo.git(&.{ "init", "-q" });
    try repo.git(&.{ "config", "user.name", "Lantana Demo" });
    try repo.git(&.{ "config", "user.email", "demo@example.invalid" });
    try repo.git(&.{ "config", "commit.gpgsign", "false" });
    try repo.git(&.{ "config", "color.ui", "false" });
    try repo.git(&.{ "config", "core.quotePath", "true" });
    try repo.git(&.{ "config", "diff.renames", "true" });

    if (scroll) {
        try repo.write("Long/WideAndTall.cs", try scrollFile(arena, false));
        try repo.git(&.{ "add", "-A" });
        try repo.git(&.{ "commit", "-qm", "baseline" });
        try repo.write("Long/WideAndTall.cs", try scrollFile(arena, true));
        try repo.git(&.{ "add", "-A" });
        std.log.info("scroll demo repository ready at .zig-cache/{s}", .{destination});
        return;
    }

    try repo.write("Assets/Characters/Hero.prefab", try hero(arena, false));
    try repo.write("Assets/Characters/Retired.prefab", "GameObject:\n  m_Name: Retired\n");
    try repo.write("Assets/Characters/Variant.prefab", "GameObject:\n  m_Name: Variant\n");
    try repo.write("Scripts/Actor.cs", "class Actor {\n\tint speed = 1;\n\tint level = 1;\n}\n");
    try repo.write("Scripts/Launch.sh", "#!/bin/sh\nprintf 'launch\\n'\n");
    try repo.write("Images/Preview.png", "\x89PNG\r\n\x1a\n\x00before");
    try repo.write("Notes/日本語 と space.txt", "before\n");
    try repo.write("Notes/quote\"tab\t.txt", "before\n");
    for (0..24) |index| {
        const path = try std.fmt.allocPrint(arena, "Samples/{d:0>2}.cs", .{index});
        try repo.write(path, "class Sample { int value = 1; }\n");
    }
    try repo.git(&.{ "add", "-A" });
    try repo.git(&.{ "commit", "-qm", "baseline" });

    try repo.write("Assets/Characters/Hero.prefab", try hero(arena, true));
    try repo.dir.deleteFile(io, "Assets/Characters/Retired.prefab");
    try repo.dir.rename("Assets/Characters/Variant.prefab", repo.dir, "Assets/Characters/Alternate.prefab", io);
    try repo.write("Assets/Characters/Hero.meta", "fileFormatVersion: 2\nguid: 1234567890abcdef\n");
    try repo.write("Scripts/Actor.cs", "class Actor {\n\tint speed = 2;\n\tint level = 1;\n\tint health = 100;\n}");
    if (builtin.os.tag != .windows) try repo.executable("Scripts/Launch.sh");
    try repo.write("Images/Preview.png", "\x89PNG\r\n\x1a\n\x00after");
    try repo.write("Notes/日本語 と space.txt", "after\n");
    try repo.write("Notes/quote\"tab\t.txt", "after\n");
    for (0..24) |index| {
        const path = try std.fmt.allocPrint(arena, "Samples/{d:0>2}.cs", .{index});
        try repo.write(path, try std.fmt.allocPrint(arena, "class Sample {{ int value = {d}; }}\n", .{index + 2}));
    }
    try repo.git(&.{ "add", "-A" });
    if (builtin.os.tag == .windows) try repo.git(&.{ "update-index", "--chmod=+x", "Scripts/Launch.sh" });
    std.log.info("demo repository ready at .zig-cache/lantana-demo", .{});
}
