const std = @import("std");
const builtin = @import("builtin");

pub fn path(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]const u8 {
    if (nonempty(env, "XDG_CONFIG_HOME")) |base| return try std.fs.path.join(allocator, &.{ base, "lantana", name });
    if (builtin.os.tag == .windows) {
        const base = nonempty(env, "APPDATA") orelse return null;
        return try std.fs.path.join(allocator, &.{ base, "lantana", name });
    }
    const home = nonempty(env, "HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".config", "lantana", name });
}

pub fn nonempty(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len != 0) value else null;
}

pub fn readOrCreate(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, initial: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            var file = try std.Io.Dir.cwd().createFileAtomic(io, file_path, .{ .make_path = true });
            defer file.deinit(io);
            try file.file.writeStreamingAll(io, initial);
            file.link(io) catch |link_error| switch (link_error) {
                error.PathAlreadyExists => {},
                else => return link_error,
            };
            break :blk try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024));
        },
        else => return err,
    };
}
