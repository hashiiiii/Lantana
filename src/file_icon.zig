const std = @import("std");

pub fn forName(name: []const u8) []const u8 {
    const extension = std.fs.path.extension(name);
    const entries = [_]struct { extension: []const u8, icon: []const u8 }{
        .{ .extension = ".prefab", .icon = "\u{e721}" },
        .{ .extension = ".unity", .icon = "\u{e721}" },
        .{ .extension = ".asset", .icon = "\u{e721}" },
        .{ .extension = ".mat", .icon = "\u{e721}" },
        .{ .extension = ".meta", .icon = "\u{e615}" },
        .{ .extension = ".cs", .icon = "\u{f031b}" },
        .{ .extension = ".zig", .icon = "\u{e6a9}" },
        .{ .extension = ".go", .icon = "\u{e65e}" },
        .{ .extension = ".rs", .icon = "\u{e68b}" },
        .{ .extension = ".py", .icon = "\u{e606}" },
        .{ .extension = ".js", .icon = "\u{e74e}" },
        .{ .extension = ".ts", .icon = "\u{e628}" },
        .{ .extension = ".json", .icon = "\u{e60b}" },
        .{ .extension = ".yaml", .icon = "\u{e6a8}" },
        .{ .extension = ".yml", .icon = "\u{e6a8}" },
        .{ .extension = ".toml", .icon = "\u{e6b2}" },
        .{ .extension = ".md", .icon = "\u{f48a}" },
        .{ .extension = ".txt", .icon = "\u{f15c}" },
        .{ .extension = ".png", .icon = "\u{f1c5}" },
        .{ .extension = ".jpg", .icon = "\u{f1c5}" },
        .{ .extension = ".svg", .icon = "\u{f0559}" },
        .{ .extension = ".sh", .icon = "\u{f489}" },
        .{ .extension = ".xml", .icon = "\u{f05c0}" },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry.extension)) return entry.icon;
    }
    return "";
}
