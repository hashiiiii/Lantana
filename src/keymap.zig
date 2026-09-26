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
pub const Bindings = shared.Keymap(Context, Action);
pub const specification: Bindings.Specification = .{
    .defaults = &.{
        .{ .context = .global, .action = .quit, .keys = &.{"q"} },
        .{ .context = .global, .action = .back, .keys = &.{"Escape"} },
        .{ .context = .global, .action = .focus_next, .keys = &.{"Tab"} },
        .{ .context = .global, .action = .toggle_render_mode, .keys = &.{"m"} },
        .{ .context = .tree, .action = .move_up, .keys = &.{ "Up", "k" } },
        .{ .context = .tree, .action = .move_down, .keys = &.{ "Down", "j" } },
        .{ .context = .tree, .action = .collapse_or_focus_parent, .keys = &.{ "Left", "h" } },
        .{ .context = .tree, .action = .expand_folder, .keys = &.{ "Right", "l" } },
        .{ .context = .tree, .action = .activate, .keys = &.{"Enter"} },
        .{ .context = .tree, .action = .toggle_folder, .keys = &.{"c"} },
        .{ .context = .content, .action = .scroll_up, .keys = &.{ "Up", "k" } },
        .{ .context = .content, .action = .scroll_down, .keys = &.{ "Down", "j" } },
        .{ .context = .content, .action = .page_up, .keys = &.{"PageUp"} },
        .{ .context = .content, .action = .page_down, .keys = &.{"PageDown"} },
        .{ .context = .content, .action = .pan_left, .keys = &.{ "Left", "h" } },
        .{ .context = .content, .action = .pan_right, .keys = &.{ "Right", "l" } },
        .{ .context = .dialog, .action = .cancel, .keys = &.{ "Escape", "n" } },
        .{ .context = .dialog, .action = .confirm, .keys = &.{"y"} },
        .{ .context = .dialog, .action = .choose_cancel, .keys = &.{"Left"} },
        .{ .context = .dialog, .action = .choose_quit, .keys = &.{"Right"} },
        .{ .context = .dialog, .action = .activate_choice, .keys = &.{"Enter"} },
    },
    .active_contexts = &.{ &.{ .global, .tree }, &.{ .global, .content }, &.{.dialog} },
};

pub fn defaults(allocator: std.mem.Allocator) !Bindings {
    return switch (try Bindings.load(allocator, specification, null)) {
        .bindings => |bindings| bindings,
        .invalid => unreachable,
    };
}

pub fn loadUser(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) !Bindings {
    const xdg = env.get("XDG_CONFIG_HOME");
    const base = if (xdg != null and xdg.?.len != 0)
        xdg.?
    else if (builtin.os.tag == .windows)
        env.get("APPDATA") orelse return defaults(allocator)
    else
        try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return defaults(allocator), ".config" });
    defer if (xdg == null or xdg.?.len == 0) {
        if (builtin.os.tag != .windows) allocator.free(base);
    };
    if (base.len == 0) return defaults(allocator);
    const path = try std.fs.path.join(allocator, &.{ base, "lantana", "keymap.toml" });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return defaults(allocator),
        else => {
            try stderr.print("{s}: {s}\n", .{ path, @errorName(err) });
            return error.InvalidKeymap;
        },
    };
    defer allocator.free(text);
    return switch (try Bindings.load(allocator, specification, text)) {
        .bindings => |bindings| bindings,
        .invalid => |diagnostic| {
            if (diagnostic.line) |line| {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, line, diagnostic.column orelse 1, diagnostic.message() });
            } else try stderr.print("{s}: {s}\n", .{ path, diagnostic.message() });
            return error.InvalidKeymap;
        },
    };
}
