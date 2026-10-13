const std = @import("std");
const user_config = @import("user_config");
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
    const path = try user_config.path(allocator, env, "keymap.json") orelse return loadDefaults(allocator);
    defer allocator.free(path);
    const text = user_config.readOrCreate(io, allocator, path, default_json) catch |err| {
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
