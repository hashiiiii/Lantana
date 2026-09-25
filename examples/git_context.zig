const std = @import("std");
const lantana = @import("lantana");

const max_file_bytes = 8 * 1024 * 1024;

pub const GitContext = struct {
    io: std.Io,

    pub fn load(context: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!?lantana.FileText {
        const self: *GitContext = @ptrCast(@alignCast(context orelse return null));
        const before = if (file.old_path != null)
            (try self.blob(arena, file.old_blob orelse return null) orelse return null)
        else
            "";
        const after = if (file.new_path != null)
            (try self.blob(arena, file.new_blob orelse return null) orelse
                try self.worktreeFile(arena, file.new_path.?, file.new_blob.?) orelse return null)
        else
            "";
        return .{ .before = before, .after = after };
    }

    fn blob(self: *GitContext, arena: std.mem.Allocator, oid: []const u8) !?[]const u8 {
        if (!validObjectId(oid)) return null;
        const result = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "cat-file", "blob", oid },
            .stdout_limit = .limited(max_file_bytes),
            .stderr_limit = .limited(1024),
        }) catch return null;
        if (result.term != .exited or result.term.exited != 0) return null;
        return result.stdout;
    }

    fn worktreeFile(self: *GitContext, arena: std.mem.Allocator, path: []const u8, oid: []const u8) !?[]const u8 {
        if (!validObjectId(oid) or !safeGitPath(path)) return null;
        const root = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel" },
            .stdout_limit = .limited(std.Io.Dir.max_path_bytes),
            .stderr_limit = .limited(1024),
        }) catch return null;
        if (root.term != .exited or root.term.exited != 0) return null;
        const directory = std.mem.trimEnd(u8, root.stdout, "\r\n");
        const full_path = try std.fs.path.join(arena, &.{ directory, path });
        const filter_path = try std.fmt.allocPrint(arena, "--path={s}", .{path});
        const hash = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "hash-object", filter_path, "--", full_path },
            .stdout_limit = .limited(128),
            .stderr_limit = .limited(1024),
        }) catch return null;
        if (hash.term != .exited or hash.term.exited != 0 or !std.mem.startsWith(u8, hash.stdout, oid)) return null;
        return std.Io.Dir.cwd().readFileAlloc(self.io, full_path, arena, .limited(max_file_bytes)) catch null;
    }
};

fn validObjectId(oid: []const u8) bool {
    if (oid.len < 4 or oid.len > 64) return false;
    var nonzero = false;
    for (oid) |byte| {
        if (!std.ascii.isHex(byte)) return false;
        if (byte != '0') nonzero = true;
    }
    return nonzero;
}

fn safeGitPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, 0) != null) return false;
    }
    return true;
}
