const std = @import("std");
const terminal = @import("terminal.zig");

pub const git_patch = @import("git_patch.zig");

pub const Color = struct { r: u8, g: u8, b: u8 };

pub const Theme = struct {
    foreground: Color = .{ .r = 220, .g = 220, .b = 224 },
    background: Color = .{ .r = 20, .g = 19, .b = 28 },
    accent: Color = .{ .r = 176, .g = 169, .b = 255 },
    removed: Color = .{ .r = 255, .g = 112, .b = 122 },
    added: Color = .{ .r = 91, .g = 224, .b = 135 },
};

pub const FileMetadata = struct {
    patch: []const u8,
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    old_blob: ?[]const u8,
    new_blob: ?[]const u8,
};

pub const Document = union(enum) {
    text: []const u8,
    unavailable: []const u8,
};

pub const DocumentRenderer = struct {
    context: ?*anyopaque = null,
    render: *const fn (?*anyopaque, std.mem.Allocator, FileMetadata) anyerror!Document,
};

pub const Options = struct {
    io: std.Io,
    environ: *std.process.Environ.Map,
    theme: Theme = .{},
    renderer: ?DocumentRenderer = null,
};

/// The caller retains ownership of the captured patch and handles a terminal error.
pub fn run(allocator: std.mem.Allocator, patch: []const u8, options: Options) !void {
    if (patch.len == 0) return;
    try terminal.run(options.io, allocator, options.environ, patch.len);
}
