const std = @import("std");
const builtin = @import("builtin");
const release_targets = @import("release_targets.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ArchiveHashes = struct {
    values: [release_targets.targets.len][]const u8,

    fn get(self: *const @This(), asset: []const u8) ?[]const u8 {
        for (release_targets.targets, 0..) |target, index| {
            if (std.mem.eql(u8, asset, target.asset)) return self.values[index];
        }
        return null;
    }

    fn put(self: *@This(), asset: []const u8, hash: []const u8) !void {
        for (release_targets.targets, 0..) |target, index| {
            if (std.mem.eql(u8, asset, target.asset)) {
                self.values[index] = hash;
                return;
            }
        }
        return error.UnknownArchive;
    }
};

const RenderError = error{
    InvalidArguments,
    InvalidVersion,
    InvalidArchive,
    InvalidChecksumManifest,
    ChecksumMismatch,
    DuplicateChecksum,
    MissingChecksum,
    UnknownArchive,
    UnknownChecksumFile,
    UnrenderedPlaceholder,
    InvalidScoopManifest,
    InvalidRubyFormula,
    InvalidHostBinary,
    UnsupportedHost,
};

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if ((args.len != 7 and args.len != 8) or !std.mem.eql(u8, args[1], "render")) return RenderError.InvalidArguments;
    try render(
        arena,
        init.io,
        args[2],
        args[3],
        args[4],
        args[5],
        args[6],
        if (args.len == 8) args[7] else null,
    );
}

pub fn render(
    arena: Allocator,
    io: Io,
    version: []const u8,
    dist_path: []const u8,
    out_path: []const u8,
    ruby_template_path: []const u8,
    json_template_path: []const u8,
    checksum_path: ?[]const u8,
) !void {
    if (!validVersion(version)) return RenderError.InvalidVersion;

    var hashes: ArchiveHashes = undefined;
    for (release_targets.targets) |target| {
        const archive_path = try std.fs.path.join(arena, &.{ dist_path, try std.fmt.allocPrint(arena, "lantana-{s}.zip", .{target.asset}) });
        try validateArchive(arena, io, archive_path, target.binary);
        try hashes.put(target.asset, try sha256File(arena, io, archive_path));
    }

    const sums_path = try std.fs.path.join(arena, &.{ dist_path, "SHA256SUMS" });
    // The aggregate release step rewrites archives in its install directory, so its old sums file is stale input; downloaded packages still validate the supplied file.
    if (checksum_path == null) {
        if (try readOptional(arena, io, sums_path)) |existing_sums| {
            try validateChecksumManifest(existing_sums, &hashes);
        }
    }
    const sums = try checksumManifest(arena, &hashes);

    const ruby_template = try readRequired(arena, io, ruby_template_path);
    const json_template = try readRequired(arena, io, json_template_path);
    const ruby = try renderTemplate(arena, ruby_template, version, hashes);
    const json = try renderTemplate(arena, json_template, version, hashes);

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);
    try out_dir.writeFile(io, .{ .sub_path = "lantana.rb", .data = ruby });
    try out_dir.writeFile(io, .{ .sub_path = "lantana.json", .data = json });
    try out_dir.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = sums });

    try validateRuby(arena, io, try std.fs.path.join(arena, &.{ out_path, "lantana.rb" }));
    try validateScoop(arena, json, version, &hashes);
    try validateHostBinary(arena, io, dist_path, version);

    if (checksum_path) |path| {
        var checksum_dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
        defer checksum_dir.close(io);
        try checksum_dir.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = sums });
    }
}

pub fn renderTemplate(arena: Allocator, template: []const u8, version: []const u8, hashes: ArchiveHashes) ![]const u8 {
    var output = try replaceAll(arena, template, "{{VERSION}}", version);
    for (release_targets.targets) |target| {
        output = try replaceAll(arena, output, target.placeholder, hashes.get(target.asset).?);
    }
    if (std.mem.indexOf(u8, output, "{{")) |_| return RenderError.UnrenderedPlaceholder;
    return output;
}

pub fn validateChecksumManifest(contents: []const u8, hashes: *const ArchiveHashes) !void {
    var seen: u8 = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hash = fields.next() orelse return RenderError.InvalidChecksumManifest;
        var filename = fields.next() orelse return RenderError.InvalidChecksumManifest;
        if (filename.len > 0 and filename[0] == '*') filename = filename[1..];
        if (std.mem.startsWith(u8, filename, "./")) filename = filename[2..];
        if (fields.next() != null or !std.mem.startsWith(u8, filename, "lantana-") or !std.mem.endsWith(u8, filename, ".zip")) return RenderError.InvalidChecksumManifest;
        const asset = filename["lantana-".len .. filename.len - ".zip".len];
        const expected = hashes.get(asset) orelse return RenderError.UnknownChecksumFile;
        const bit = checksumBit(asset) orelse return RenderError.UnknownChecksumFile;
        if (seen & bit != 0) return RenderError.DuplicateChecksum;
        if (!std.mem.eql(u8, hash, expected)) return RenderError.ChecksumMismatch;
        seen |= bit;
    }
    if (seen != 0b111111) return RenderError.MissingChecksum;
}

fn validVersion(version: []const u8) bool {
    var parts = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part, 0..) |byte, index| {
            if (byte < '0' or byte > '9' or (index == 0 and part.len > 1 and byte == '0')) return false;
        }
        count += 1;
    }
    return count == 3;
}

fn checksumBit(asset: []const u8) ?u8 {
    for (release_targets.targets, 0..) |target, index| {
        if (std.mem.eql(u8, asset, target.asset)) return @as(u8, 1) << @intCast(index);
    }
    return null;
}

fn replaceAll(arena: Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, arena, input, needle, replacement);
}

fn readRequired(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
}

fn readOptional(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn validateArchive(arena: Allocator, io: Io, archive_path: []const u8, expected_binary: []const u8) !void {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "unzip", "-Z1", archive_path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) return RenderError.InvalidArchive;
    const actual = std.mem.trim(u8, result.stdout, "\r\n");
    if (!std.mem.eql(u8, actual, expected_binary)) return RenderError.InvalidArchive;
}

fn sha256File(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    const data = try readRequired(arena, io, path);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return try arena.dupe(u8, &encoded);
}

fn checksumManifest(arena: Allocator, hashes: *const ArchiveHashes) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (release_targets.targets) |target| {
        const hash = hashes.get(target.asset) orelse return RenderError.UnknownArchive;
        try output.appendSlice(arena, hash);
        try output.appendSlice(arena, "  ");
        try output.appendSlice(arena, try std.fmt.allocPrint(arena, "lantana-{s}.zip\n", .{target.asset}));
    }
    return output.items;
}

fn validateRuby(arena: Allocator, io: Io, path: []const u8) !void {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "ruby", "-c", path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) return RenderError.InvalidRubyFormula;
}

const ScoopArchive = struct {
    url: []const u8,
    hash: []const u8,
};

const ScoopArchitecture = struct {
    @"64bit": ScoopArchive,
    arm64: ScoopArchive,
};

const ScoopManifest = struct {
    version: []const u8,
    architecture: ScoopArchitecture,
    bin: []const u8,
    env_add_path: []const u8,
};

fn validateScoop(arena: Allocator, contents: []const u8, version: []const u8, hashes: *const ArchiveHashes) !void {
    const manifest = std.json.parseFromSliceLeaky(ScoopManifest, arena, contents, .{ .ignore_unknown_fields = true }) catch return RenderError.InvalidScoopManifest;
    if (!std.mem.eql(u8, manifest.version, version) or !std.mem.eql(u8, manifest.bin, "lantana.exe") or !std.mem.eql(u8, manifest.env_add_path, ".")) return RenderError.InvalidScoopManifest;
    const x64_url = try std.fmt.allocPrint(arena, "https://github.com/hashiiiii/Lantana/releases/download/v{s}/lantana-windows-x64.zip", .{version});
    const arm64_url = try std.fmt.allocPrint(arena, "https://github.com/hashiiiii/Lantana/releases/download/v{s}/lantana-windows-arm64.zip", .{version});
    if (!std.mem.eql(u8, manifest.architecture.@"64bit".url, x64_url) or !std.mem.eql(u8, manifest.architecture.@"64bit".hash, hashes.get("windows-x64").?)) return RenderError.InvalidScoopManifest;
    if (!std.mem.eql(u8, manifest.architecture.arm64.url, arm64_url) or !std.mem.eql(u8, manifest.architecture.arm64.hash, hashes.get("windows-arm64").?)) return RenderError.InvalidScoopManifest;
}

const TempDir = struct {
    parent: Io.Dir,
    dir: Io.Dir,
    name: [std.base64.url_safe.Encoder.calcSize(12)]u8,
    path: []const u8,

    fn init(arena: Allocator, io: Io) !TempDir {
        var parent = try Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/lantana-package", .{});
        errdefer parent.close(io);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const dir = try parent.createDirPathOpen(io, &name, .{});
        errdefer dir.close(io);
        var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try dir.realPath(io, &path_buffer);
        return .{ .parent = parent, .dir = dir, .name = name, .path = try arena.dupe(u8, path_buffer[0..path_len]) };
    }

    fn deinit(self: *TempDir, io: Io) void {
        self.dir.close(io);
        self.parent.deleteTree(io, &self.name) catch {};
        self.parent.close(io);
    }
};

fn validateHostBinary(arena: Allocator, io: Io, dist_path: []const u8, version: []const u8) !void {
    const target = release_targets.forTarget(builtin.target) orelse return RenderError.UnsupportedHost;
    const archive_path = try std.fs.path.join(arena, &.{ dist_path, try std.fmt.allocPrint(arena, "lantana-{s}.zip", .{target.asset}) });
    var temp = try TempDir.init(arena, io);
    defer temp.deinit(io);
    const unzip = try std.process.run(arena, io, .{
        .argv = &.{ "unzip", "-q", archive_path, target.binary, "-d", temp.path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (unzip.term != .exited or unzip.term.exited != 0) return RenderError.InvalidHostBinary;
    const binary_path = try std.fs.path.join(arena, &.{ temp.path, target.binary });
    if (builtin.os.tag != .windows) {
        var binary = try Io.Dir.openFileAbsolute(io, binary_path, .{ .mode = .read_write });
        defer binary.close(io);
        try binary.setPermissions(io, .executable_file);
    }
    const result = try std.process.run(arena, io, .{
        .argv = &.{ binary_path, "--version" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    const expected = try std.fmt.allocPrint(arena, "lantana {s}\n", .{version});
    if (result.term != .exited or result.term.exited != 0 or !std.mem.eql(u8, result.stdout, expected)) return RenderError.InvalidHostBinary;
}
