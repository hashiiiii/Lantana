const std = @import("std");

pub const Action = enum { setup, unset };
pub const Scope = enum { project, local, user };
pub const Result = enum { changed, unchanged };

const project_file = ".lantana.gitconfig";
const generated_project_config = "[pager]\n\tdiff = lantana\n";

pub fn apply(arena: std.mem.Allocator, io: std.Io, action: Action, scope: Scope) !Result {
    if (scope == .project) return applyProject(arena, io, action);
    const scope_arg: []const u8 = switch (scope) {
        .local => "--local",
        .user => "--global",
        .project => unreachable,
    };
    const direct = try single(try query(arena, io, &.{ "git", "config", scope_arg, "--no-includes", "--null", "--get-all", "pager.diff" }));
    switch (action) {
        .setup => {
            if (direct) |value| {
                if (std.mem.eql(u8, value, "lantana")) return .unchanged;
                return error.ExistingPager;
            }
            if (try query(arena, io, &.{ "git", "config", scope_arg, "--includes", "--null", "--get-all", "pager.diff" }) != null) {
                return error.ExistingPager;
            }
            try checked(arena, io, &.{ "git", "config", scope_arg, "pager.diff", "lantana" });
        },
        .unset => {
            if (direct) |value| {
                if (!std.mem.eql(u8, value, "lantana")) return error.NotLantanaPager;
            } else return .unchanged;
            try checked(arena, io, &.{ "git", "config", scope_arg, "--unset", "pager.diff" });
        },
    }
    return .changed;
}

fn applyProject(arena: std.mem.Allocator, io: std.Io, action: Action) !Result {
    const root_result = try std.process.run(arena, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    if (root_result.term != .exited or root_result.term.exited != 0) return error.RequiresRepository;
    const root = std.mem.trimEnd(u8, root_result.stdout, "\r\n");
    const path = try std.fs.path.join(arena, &.{ root, project_file });
    const project_pager = try single(try query(arena, io, &.{ "git", "config", "--file", path, "--no-includes", "--null", "--get-all", "pager.diff" }));
    const local_pager = try single(try query(arena, io, &.{ "git", "config", "--local", "--no-includes", "--null", "--get-all", "pager.diff" }));

    switch (action) {
        .setup => {
            if (project_pager) |value| {
                if (!std.mem.eql(u8, value, "lantana")) return error.ExistingPager;
            }
            if (local_pager) |value| {
                if (!std.mem.eql(u8, value, "lantana")) return error.ExistingPager;
            } else if (try query(arena, io, &.{ "git", "config", "--local", "--includes", "--null", "--get-all", "pager.diff" }) != null) {
                return error.ExistingPager;
            }
            if (project_pager != null and local_pager != null) return .unchanged;
            var added_local = false;
            errdefer if (added_local) checked(arena, io, &.{ "git", "config", "--local", "--unset", "pager.diff" }) catch {};
            if (local_pager == null) {
                try checked(arena, io, &.{ "git", "config", "--local", "pager.diff", "lantana" });
                added_local = true;
            }
            if (project_pager == null) try checked(arena, io, &.{ "git", "config", "--file", path, "pager.diff", "lantana" });
            return .changed;
        },
        .unset => {
            const value = project_pager orelse return .unchanged;
            if (!std.mem.eql(u8, value, "lantana")) return error.NotLantanaPager;
            if (local_pager) |local| {
                if (!std.mem.eql(u8, local, "lantana")) return error.NotLantanaPager;
            }
            const original = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
            var removed_local = false;
            errdefer if (removed_local) checked(arena, io, &.{ "git", "config", "--local", "pager.diff", "lantana" }) catch {};
            if (local_pager != null) {
                try checked(arena, io, &.{ "git", "config", "--local", "--unset", "pager.diff" });
                removed_local = true;
            }
            try checked(arena, io, &.{ "git", "config", "--file", path, "--unset", "pager.diff" });
            removed_local = false;
            if (std.mem.eql(u8, original, generated_project_config)) try std.Io.Dir.cwd().deleteFile(io, path);
            return .changed;
        },
    }
}

fn checked(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    if (result.term != .exited or result.term.exited != 0) return error.GitConfigFailed;
}

fn query(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
    });
    if (result.term != .exited) return error.GitConfigFailed;
    return switch (result.term.exited) {
        0 => result.stdout,
        1 => null,
        else => error.GitConfigFailed,
    };
}

fn single(values: ?[]const u8) !?[]const u8 {
    const bytes = values orelse return null;
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return error.GitConfigFailed;
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.GitConfigFailed;
    if (end != bytes.len - 1) return error.MultipleValues;
    return bytes[0..end];
}
