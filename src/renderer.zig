const std = @import("std");
const builtin = @import("builtin");
const lantana = @import("lantana");
const GitContext = @import("git_context.zig").GitContext;
const process = @import("renderer_process.zig");
const user_config = @import("user_config");

pub const Rule = struct {
    patterns: []const []const u8,
    command: []const []const u8,
    timeout_ms: u32 = 10_000,
};

pub const Config = struct {
    parsed: std.json.Parsed([]const Rule),

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Config {
        const parsed = std.json.parseFromSlice([]const Rule, allocator, text, .{ .allocate = .alloc_always }) catch return error.InvalidRendererConfig;
        errdefer parsed.deinit();
        for (parsed.value) |rule| {
            if (rule.patterns.len == 0 or rule.command.len == 0 or rule.command[0].len == 0 or rule.timeout_ms == 0 or rule.timeout_ms > 60_000)
                return error.InvalidRendererConfig;
            for (rule.patterns) |pattern| {
                if (pattern.len == 0 or std.mem.indexOfScalar(u8, pattern, 0) != null) return error.InvalidRendererConfig;
            }
            for (rule.command, 0..) |arg, index| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidRendererConfig;
                const placeholder = std.mem.eql(u8, arg, "{before}") or std.mem.eql(u8, arg, "{after}") or
                    std.mem.eql(u8, arg, "{path}") or std.mem.eql(u8, arg, "{repo}");
                if (placeholder and index == 0) return error.InvalidRendererConfig;
                if (!placeholder and placeholderSyntax(arg))
                    return error.InvalidRendererConfig;
                if (!placeholder and (std.mem.indexOf(u8, arg, "{before}") != null or std.mem.indexOf(u8, arg, "{after}") != null or
                    std.mem.indexOf(u8, arg, "{path}") != null or std.mem.indexOf(u8, arg, "{repo}") != null)) return error.InvalidRendererConfig;
            }
        }
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Config) void {
        self.parsed.deinit();
    }
};

fn placeholderSyntax(arg: []const u8) bool {
    if (arg.len < 3 or arg[0] != '{' or arg[arg.len - 1] != '}') return false;
    for (arg[1 .. arg.len - 1]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

pub const Renderer = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    git: *GitContext,
    config: Config,

    pub fn load(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, git: *GitContext, stderr: *std.Io.Writer) !Renderer {
        const config_path = try user_config.path(arena, env, "renderers.json");
        defer if (config_path) |value| arena.free(value);
        const text = if (config_path) |value| user_config.readOrCreate(io, arena, value, "[]\n") catch |err| {
            try stderr.print("{s}: could not load renderers ({s})\n", .{ value, @errorName(err) });
            return error.InvalidRendererConfig;
        } else try arena.dupe(u8, "[]");
        defer arena.free(text);
        const config = Config.parse(arena, text) catch |err| {
            try stderr.print("{s}: invalid renderer configuration ({s})\n", .{ config_path orelse "renderers.json", @errorName(err) });
            return error.InvalidRendererConfig;
        };
        return .{ .io = io, .environ = env, .git = git, .config = config };
    }

    pub fn deinit(self: *Renderer) void {
        self.config.deinit();
    }

    pub fn render(context: ?*anyopaque, arena: std.mem.Allocator, file: lantana.FileMetadata) anyerror!lantana.Document {
        const self: *Renderer = @ptrCast(@alignCast(context orelse return error.MissingRenderer));
        const path = file.new_path orelse file.old_path orelse return .{ .unavailable = "No file path" };
        const rule = for (self.config.parsed.value) |*rule| {
            for (rule.patterns) |pattern| {
                if (matches(pattern, path)) break;
            } else continue;
            break rule;
        } else return .{ .unavailable = "No matching renderer" };
        const sources = try GitContext.load(self.git, arena, file) orelse return .{ .unavailable = "Original file contents unavailable" };
        const repo = try self.git.root(arena) orelse return .{ .unavailable = "Repository unavailable" };
        var temp = try Snapshot.init(self.io, arena, self.environ, path, sources);
        defer temp.deinit(self.io);
        const argv = try arena.alloc([]const u8, rule.command.len);
        for (rule.command, argv) |arg, *expanded| {
            expanded.* = if (std.mem.eql(u8, arg, "{before}")) temp.before else if (std.mem.eql(u8, arg, "{after}")) temp.after else if (std.mem.eql(u8, arg, "{path}")) path else if (std.mem.eql(u8, arg, "{repo}")) repo else arg;
        }
        const result = try process.run(arena, self.io, .{
            .argv = argv,
            .cwd = .{ .path = repo },
            .environ_map = self.environ,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .deadline = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .clock = .awake, .raw = .fromMilliseconds(rule.timeout_ms) }) },
        });
        if (result.term != .exited or result.term.exited != 0) return error.RendererFailed;
        if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0) return .{ .unavailable = "Renderer returned no text" };
        _ = try lantana.document.parse(arena, result.stdout);
        return .{ .text = result.stdout };
    }
};

fn matches(pattern: []const u8, path: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (s < path.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = s;
        } else if (p < pattern.len and pattern[p] == path[s]) {
            p += 1;
            s += 1;
        } else if (star) |position| {
            p = position + 1;
            retry += 1;
            s = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const Snapshot = struct {
    parent: std.Io.Dir,
    name: []const u8,
    before: []const u8,
    after: []const u8,

    fn init(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, path: []const u8, sources: lantana.FileText) !Snapshot {
        const base = user_config.nonempty(env, "TMPDIR") orelse user_config.nonempty(env, "TEMP") orelse
            user_config.nonempty(env, "TMP") orelse if (builtin.os.tag == .windows) return error.NoTemporaryDirectory else "/tmp";
        if (!std.fs.path.isAbsolute(base)) return error.InvalidTemporaryDirectory;
        const parent = try std.Io.Dir.cwd().openDir(io, base, .{});
        errdefer parent.close(io);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = try std.fmt.allocPrint(arena, "lantana-renderer-{s}", .{std.fmt.bytesToHex(random, .lower)});
        try parent.createDir(io, name, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        errdefer parent.deleteTree(io, name) catch {};
        var dir = try parent.openDir(io, name, .{});
        defer dir.close(io);
        // Viewers may choose their parser from the input filename's extension.
        const extension = std.fs.path.extension(path);
        const before_name = try std.fmt.allocPrint(arena, "before{s}", .{extension});
        const after_name = try std.fmt.allocPrint(arena, "after{s}", .{extension});
        try dir.writeFile(io, .{ .sub_path = before_name, .data = sources.before });
        try dir.writeFile(io, .{ .sub_path = after_name, .data = sources.after });
        return .{
            .parent = parent,
            .name = name,
            .before = try std.fs.path.join(arena, &.{ base, name, before_name }),
            .after = try std.fs.path.join(arena, &.{ base, name, after_name }),
        };
    }

    fn deinit(self: *Snapshot, io: std.Io) void {
        self.parent.deleteTree(io, self.name) catch {};
        self.parent.close(io);
    }
};

test "renderer rules reject commands that cannot use the snapshot contract" {
    // Invalid rules must fail before a pager starts or an unexpected executable is invoked.
    try std.testing.expectError(error.InvalidRendererConfig, Config.parse(std.testing.allocator, "[{\"patterns\":[\"*.prefab\"],\"command\":[]}]"));
    try std.testing.expectError(error.InvalidRendererConfig, Config.parse(std.testing.allocator, "[{\"patterns\":[\"*.prefab\"],\"command\":[\"tool\",\"{befroe}\"]}]"));
    try std.testing.expectError(error.InvalidRendererConfig, Config.parse(std.testing.allocator, "[{\"patterns\":[\"*.prefab\"],\"command\":[\"{before}\"]}]"));
    try std.testing.expectError(error.InvalidRendererConfig, Config.parse(std.testing.allocator, "[{\"patterns\":[\"*.prefab\"],\"command\":[\"tool\"],\"timeout_ms\":0}]"));
}

test "renderer rules retain JSON literals used as tool arguments" {
    // Tools may accept JSON options, whose braces must not be mistaken for placeholders.
    var config = try Config.parse(std.testing.allocator,
        \\[{"patterns":["*.json"],"command":["tool","{\"mode\":\"table\"}","{before}","{after}"]}]
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("{\"mode\":\"table\"}", config.parsed.value[0].command[1]);
}

test {
    _ = process;
}
