const std = @import("std");
const tui = @import("tui.zig");

pub const git_patch = @import("git_patch.zig");
pub const raw_split = @import("raw_split.zig");
pub const review = @import("review.zig");
pub const document = @import("document.zig");

pub const Color = tui.Color;
pub const Theme = tui.Theme;

pub const FileMetadata = review.FileMetadata;
pub const Document = review.Document;
pub const DocumentRenderer = review.DocumentRenderer;

pub const Options = struct {
    io: std.Io,
    environ: *std.process.Environ.Map,
    theme: Theme = .{},
    renderer: ?DocumentRenderer = null,
};

/// The caller retains ownership of the captured patch and handles a terminal error.
pub fn run(allocator: std.mem.Allocator, patch: []const u8, options: Options) !void {
    if (patch.len == 0) return;
    var memory = std.heap.ArenaAllocator.init(allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const parsed = try git_patch.parse(arena, patch);
    var state = try review.Review.init(arena, parsed, options.renderer);
    try tui.run(options.io, arena, options.environ, &state, options.theme);
}
