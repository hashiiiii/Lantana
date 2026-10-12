const std = @import("std");
const lantana = @import("lantana");

const max_file_bytes = 8 * 1024 * 1024;

pub const GitContext = struct {
    io: std.Io,
    directory: ?[]const u8 = null,
    root_path: ?[]const u8 = null,
    sha256: bool = false,
    snapshots: std.StringHashMapUnmanaged(?lantana.FileText) = .empty,

    pub fn load(context: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!?lantana.FileText {
        const self: *GitContext = @ptrCast(@alignCast(context orelse return null));
        if (self.snapshots.get(file.patch)) |cached| return cached;
        const text = try self.read(arena, file);
        try self.snapshots.put(arena, file.patch, text);
        return text;
    }

    fn read(self: *GitContext, arena: std.mem.Allocator, file: lantana.FileMetadata) !?lantana.FileText {
        _ = try self.root(arena) orelse return null;
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

    pub fn root(self: *GitContext, arena: std.mem.Allocator) !?[]const u8 {
        if (self.root_path) |path| return path;
        const result = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "rev-parse", "--show-toplevel", "--show-object-format" },
            .cwd = if (self.directory) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(std.Io.Dir.max_path_bytes + 32),
            .stderr_limit = .limited(1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
        }) catch return null;
        if (result.term != .exited or result.term.exited != 0) return null;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        const path = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
        const format = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
        if (path.len == 0 or (!std.mem.eql(u8, format, "sha1") and !std.mem.eql(u8, format, "sha256"))) return null;
        self.root_path = path;
        self.sha256 = std.mem.eql(u8, format, "sha256");
        return path;
    }

    fn blob(self: *GitContext, arena: std.mem.Allocator, oid: []const u8) !?[]const u8 {
        if (!validObjectId(oid)) return null;
        const result = std.process.run(arena, self.io, .{
            .argv = &.{ "git", "cat-file", "blob", oid },
            .cwd = .{ .path = self.root_path.? },
            .stdout_limit = .limited(max_file_bytes),
            .stderr_limit = .limited(1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
        }) catch return null;
        if (result.term != .exited or result.term.exited != 0) return null;
        return result.stdout;
    }

    fn worktreeFile(self: *GitContext, arena: std.mem.Allocator, path: []const u8, oid: []const u8) !?[]const u8 {
        if (!validObjectId(oid) or !safeGitPath(path)) return null;
        const directory = try self.root(arena) orelse return null;
        const full_path = try std.fs.path.join(arena, &.{ directory, path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, full_path, arena, .limited(max_file_bytes)) catch return null;
        if (self.matchesBlob(bytes, oid)) return bytes;
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
        const normalized = try std.mem.replaceOwned(u8, arena, bytes, "\r\n", "\n");
        return if (self.matchesBlob(normalized, oid)) normalized else null;
    }

    fn matchesBlob(self: *const GitContext, bytes: []const u8, oid: []const u8) bool {
        var buffer: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&buffer, "blob {d}\x00", .{bytes.len}) catch return false;
        if (self.sha256) {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(header);
            hash.update(bytes);
            return std.mem.startsWith(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower), oid);
        }
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(header);
        hash.update(bytes);
        return std.mem.startsWith(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower), oid);
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

fn testGit(arena: std.mem.Allocator, directory: []const u8, args: []const []const u8) ![]const u8 {
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ "git", "-c", "core.autocrlf=false", "-C", directory }, args });
    const result = try std.process.run(arena, std.testing.io, .{ .argv = argv, .stdout_limit = .limited(max_file_bytes), .stderr_limit = .limited(4096) });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    return result.stdout;
}

test "snapshot recovery rejects stale worktrees and retains already captured sources" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    _ = try testGit(arena, directory, &.{ "init", "-q" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Example.txt", .data = "before\n" });
    _ = try testGit(arena, directory, &.{ "add", "Example.txt" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Example.txt", .data = "after\n" });
    const patch = try lantana.git_patch.parse(arena, try testGit(arena, directory, &.{ "diff", "--no-color" }));
    const entry = patch.files[0];
    const file: lantana.FileMetadata = .{ .patch = entry.raw, .old_path = entry.old_path, .new_path = entry.new_path, .old_blob = entry.old_blob, .new_blob = entry.new_blob };
    var context: GitContext = .{ .io = std.testing.io, .directory = directory };
    const first = (try GitContext.load(&context, arena, file)).?;
    try std.testing.expectEqualStrings("before\n", first.before);
    try std.testing.expectEqualStrings("after\n", first.after);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Example.txt", .data = "unrelated edit\n" });
    // Changing files after git diff must neither replace the snapshot nor render unrelated content.
    const cached = try GitContext.load(&context, arena, file);
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings("after\n", cached.?.after);
    var later: GitContext = .{ .io = std.testing.io, .directory = directory };
    try std.testing.expect(try GitContext.load(&later, arena, file) == null);
    _ = try testGit(arena, directory, &.{ "add", "Example.txt" });
    const staged = try lantana.git_patch.parse(arena, try testGit(arena, directory, &.{ "diff", "--cached", "--no-color" }));
    // A staged addition has an empty before side and comes from the object database.
    const added = staged.files[0];
    const staged_text = (try GitContext.load(&later, arena, .{ .patch = added.raw, .old_path = added.old_path, .new_path = added.new_path, .old_blob = added.old_blob, .new_blob = added.new_blob })).?;
    try std.testing.expectEqualStrings("", staged_text.before);
    try std.testing.expectEqualStrings("unrelated edit\n", staged_text.after);
}

test "SHA256 snapshots normalize CRLF only when the captured blob verifies" {
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    _ = try testGit(arena, directory, &.{ "init", "-q", "--object-format=sha256" });
    _ = try testGit(arena, directory, &.{ "config", "core.autocrlf", "input" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Example.txt", .data = "before\n" });
    _ = try testGit(arena, directory, &.{ "add", "Example.txt" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Example.txt", .data = "after\r\n" });
    const patch = try lantana.git_patch.parse(arena, try testGit(arena, directory, &.{ "-c", "core.autocrlf=input", "diff", "--no-color" }));
    const entry = patch.files[0];
    var context: GitContext = .{ .io = std.testing.io, .directory = directory };
    // A valid line-ending conversion must retain semantic viewing in Windows-style worktrees.
    const text = (try GitContext.load(&context, arena, .{ .patch = entry.raw, .old_path = entry.old_path, .new_path = entry.new_path, .old_blob = entry.old_blob, .new_blob = entry.new_blob })).?;
    try std.testing.expectEqualStrings("before\n", text.before);
    try std.testing.expectEqualStrings("after\n", text.after);
}
