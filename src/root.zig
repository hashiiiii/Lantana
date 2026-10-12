const std = @import("std");
const tui = @import("tui.zig");
const text_selection = @import("text_selection.zig");

pub const git_patch = @import("git_patch.zig");
pub const raw_split = @import("raw_split.zig");
pub const review = @import("review.zig");
pub const document = @import("document.zig");
pub const keymap = @import("keymap.zig");
pub const Bindings = keymap.Bindings;

pub const Color = tui.Color;
pub const Theme = tui.Theme;

pub const FileMetadata = review.FileMetadata;
pub const Document = review.Document;
pub const DocumentRenderer = review.DocumentRenderer;
pub const FileText = review.FileText;
pub const FileTextProvider = review.FileTextProvider;

pub const Options = struct {
    io: std.Io,
    environ: *std.process.Environ.Map,
    theme: Theme = .{},
    renderer: ?DocumentRenderer = null,
    file_text: ?FileTextProvider = null,
    /// The caller owns these bindings. Each terminal session clears pending input when it starts and ends.
    bindings: ?*Bindings = null,
};

/// The caller owns the captured patch and handles terminal errors.
pub fn run(allocator: std.mem.Allocator, patch: []const u8, options: Options) !void {
    if (patch.len == 0) return;
    var memory = std.heap.ArenaAllocator.init(allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const parsed = try git_patch.parse(arena, patch);
    var state = try review.Review.initWithFileText(arena, parsed, options.renderer, options.file_text);
    var owned: ?Bindings = null;
    defer if (owned) |*bindings| bindings.deinit();
    const bindings = options.bindings orelse blk: {
        owned = try keymap.loadDefaults(arena);
        break :blk &owned.?;
    };
    try tui.run(options.io, arena, options.environ, &state, options.theme, bindings);
}

test {
    _ = tui;
    _ = git_patch;
    _ = raw_split;
    _ = review;
    _ = document;
    _ = text_selection;
}
