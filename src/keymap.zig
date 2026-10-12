const std = @import("std");
const builtin = @import("builtin");
const shared = @import("keymap");

pub const Context = enum { global, tree, content, dialog };
pub const Action = enum {
    quit,
    back,
    focus_next,
    toggle_render_mode,
    move_up,
    move_down,
    collapse_or_focus_parent,
    expand_folder,
    activate,
    toggle_folder,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
    pan_left,
    pan_right,
    cancel,
    confirm,
    choose_cancel,
    choose_quit,
    activate_choice,
};
pub const Bindings = shared.Bindings(Context, Action);
pub const default_json = @embedFile("keymap.json");

pub fn loadDefaults(allocator: std.mem.Allocator) !Bindings {
    return switch (try Bindings.load(allocator, default_json)) {
        .bindings => |bindings| bindings,
        .invalid => |value| blk: {
            var diagnostic = value;
            defer diagnostic.deinit();
            break :blk error.InvalidKeymap;
        },
    };
}

pub fn loadUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) !Bindings {
    const xdg = env.get("XDG_CONFIG_HOME");
    const base = if (xdg != null and xdg.?.len != 0)
        xdg.?
    else if (builtin.os.tag == .windows)
        env.get("APPDATA") orelse return loadDefaults(allocator)
    else
        try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return loadDefaults(allocator), ".config" });
    defer if (xdg == null or xdg.?.len == 0) {
        if (builtin.os.tag != .windows) allocator.free(base);
    };
    if (base.len == 0) return loadDefaults(allocator);
    const path = try std.fs.path.join(allocator, &.{ base, "lantana", "keymap.json" });
    defer allocator.free(path);
    const text = readOrCreateUserFile(io, allocator, path) catch |err| {
        try stderr.print("{s}: could not load key bindings ({s})\n", .{ path, @errorName(err) });
        return error.InvalidKeymap;
    };
    defer allocator.free(text);
    return switch (try Bindings.load(allocator, text)) {
        .bindings => |bindings| bindings,
        .invalid => |value| blk: {
            var diagnostic = value;
            defer diagnostic.deinit();
            if (diagnostic.position) |position| {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, position.line, position.column, diagnostic.message });
            } else {
                try stderr.print("{s}: {s}\n", .{ path, diagnostic.message });
            }
            break :blk error.InvalidKeymap;
        },
    };
}

fn readOrCreateUserFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try createDefaultFile(io, path);
            break :blk try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        },
        else => return err,
    };
}

fn createDefaultFile(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, default_json);
    file.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
