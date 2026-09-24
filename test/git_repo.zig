const std = @import("std");

// The fixture generator is an executable, so this helper cannot use std.testing.tmpDir.
const TempDir = struct {
    io: std.Io,
    dir: std.Io.Dir,
    parent: std.Io.Dir,
    sub_path: [std.base64.url_safe.Encoder.calcSize(12)]u8,

    fn init(io: std.Io) !TempDir {
        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{});
        errdefer parent.close(io);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);
        const dir = try parent.createDirPathOpen(io, &sub_path, .{});
        return .{ .io = io, .dir = dir, .parent = parent, .sub_path = sub_path };
    }

    fn cleanup(self: *TempDir) void {
        self.dir.close(self.io);
        self.parent.deleteTree(self.io, &self.sub_path) catch {};
        self.parent.close(self.io);
    }
};

pub const Repo = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    temp: TempDir,
    path: []const u8,

    pub fn init(arena: std.mem.Allocator, io: std.Io) !Repo {
        var temp = try TempDir.init(io);
        errdefer temp.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const count = try temp.dir.realPath(io, &path_buffer);
        var self: Repo = .{
            .arena = arena,
            .io = io,
            .temp = temp,
            .path = try arena.dupe(u8, path_buffer[0..count]),
        };
        _ = try self.git(&.{ "init", "-q" });
        _ = try self.git(&.{ "config", "user.name", "Lantana Test" });
        _ = try self.git(&.{ "config", "user.email", "test@example.invalid" });
        _ = try self.git(&.{ "config", "commit.gpgsign", "false" });
        _ = try self.git(&.{ "config", "color.ui", "false" });
        return self;
    }

    pub fn deinit(self: *Repo) void {
        self.temp.cleanup();
    }

    pub fn git(self: *Repo, args: []const []const u8) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.arena, "git");
        try argv.appendSlice(self.arena, args);
        const result = try std.process.run(self.arena, self.io, .{
            .argv = argv.items,
            .cwd = .{ .dir = self.temp.dir },
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("git failed: {s}", .{result.stderr});
            return error.GitFailed;
        }
        return result.stdout;
    }

    pub fn write(self: *Repo, name: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(name)) |parent| try self.temp.dir.createDirPath(self.io, parent);
        try self.temp.dir.writeFile(self.io, .{ .sub_path = name, .data = data });
    }

    pub fn read(self: *Repo, name: []const u8) ![]const u8 {
        return self.temp.dir.readFileAlloc(self.io, name, self.arena, .limited(16 * 1024 * 1024));
    }

    pub fn commit(self: *Repo) !void {
        _ = try self.git(&.{ "add", "-A" });
        _ = try self.git(&.{ "commit", "-qm", "initial" });
    }

    pub fn setPager(self: *Repo, pager_path: []const u8, demo: bool) !void {
        const absolute_path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, pager_path, self.arena);
        var command: std.ArrayList(u8) = .empty;
        try command.append(self.arena, '\'');
        for (absolute_path) |byte| switch (byte) {
            '\'' => try command.appendSlice(self.arena, "'\\''"),
            '\\' => try command.append(self.arena, '/'),
            else => try command.append(self.arena, byte),
        };
        try command.append(self.arena, '\'');
        if (demo) try command.appendSlice(self.arena, " --demo-document");
        _ = try self.git(&.{ "config", "core.pager", command.items });
        _ = try self.git(&.{ "config", "pager.diff", "true" });
    }
};
