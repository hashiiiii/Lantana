const std = @import("std");
const pager_path = @import("test_options").pager_path;

const io = std.testing.io;
const RunResult = std.process.RunResult;

fn path(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(arena, parts);
}

fn isolatedEnvironment(arena: std.mem.Allocator, root: []const u8) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(arena);
    var base = try std.testing.environ.createMap(arena);
    defer base.deinit();
    for (base.keys(), base.values()) |key, value| {
        // Repository overrides can redirect subprocesses outside the temporary test repository.
        if (std.mem.startsWith(u8, key, "GIT_")) continue;
        try environment.put(key, value);
    }
    try environment.put("GIT_CONFIG_GLOBAL", try path(arena, &.{ root, "global" }));
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("XDG_CONFIG_HOME", try path(arena, &.{ root, "xdg" }));
    return environment;
}

fn run(
    arena: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    argv: []const []const u8,
) !RunResult {
    return std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
}

fn git(
    arena: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    args: []const []const u8,
) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, args);
    return run(arena, environment, cwd, argv.items);
}

fn cli(
    arena: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    executable: []const u8,
    args: []const []const u8,
) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, executable);
    try argv.appendSlice(arena, args);
    return run(arena, environment, cwd, argv.items);
}

fn expectExit(result: RunResult, code: u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, result.term);
}

fn expectGit(
    arena: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    args: []const []const u8,
) ![]const u8 {
    const result = try git(arena, environment, cwd, args);
    try expectExit(result, 0);
    return result.stdout;
}

fn expectCli(
    arena: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
    cwd: []const u8,
    executable: []const u8,
    args: []const []const u8,
) ![]const u8 {
    const result = try cli(arena, environment, cwd, executable, args);
    try expectExit(result, 0);
    return result.stdout;
}

fn exists(absolute_path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, absolute_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "CLI configuration commands preserve Git settings in isolated environments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try scratch.dir.realPath(io, &root_buffer);
    const root = try arena.dupe(u8, root_buffer[0..root_len]);
    // Real subprocesses must use an isolated Git environment so this scope test cannot leak into the developer's config.
    var environment = try isolatedEnvironment(arena, root);
    defer environment.deinit();
    try scratch.dir.createDirPath(io, "xdg");

    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, pager_path, arena);
    try std.testing.expectEqualStrings("lantana " ++ @import("build_options").version ++ "\n", try expectCli(arena, &environment, root, executable, &.{"--version"}));
    try std.testing.expectEqualStrings("", try expectCli(arena, &environment, root, executable, &.{}));

    const local = try path(arena, &.{ root, "local" });
    _ = try expectGit(arena, &environment, root, &.{ "init", "-q", local });
    try std.testing.expectEqualStrings("Set pager.diff to lantana in local Git configuration.\n", try expectCli(arena, &environment, local, executable, &.{"set"}));
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, local, &.{ "config", "--local", "--get", "pager.diff" }));
    _ = try expectCli(arena, &environment, local, executable, &.{ "set", "--local" });
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, local, &.{ "config", "--local", "--get-all", "pager.diff" }));
    _ = try expectCli(arena, &environment, local, executable, &.{"unset"});
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, local, &.{ "config", "--local", "--get", "pager.diff" })).term.exited);
    _ = try expectGit(arena, &environment, local, &.{ "config", "--local", "pager.diff", "less" });
    try std.testing.expectEqual(@as(u8, 2), (try cli(arena, &environment, local, executable, &.{ "set", "--local" })).term.exited);
    try std.testing.expectEqual(@as(u8, 2), (try cli(arena, &environment, local, executable, &.{ "unset", "--local" })).term.exited);
    try std.testing.expectEqualStrings("less\n", try expectGit(arena, &environment, local, &.{ "config", "--local", "--get", "pager.diff" }));

    _ = try expectCli(arena, &environment, root, executable, &.{ "set", "--user" });
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, root, &.{ "config", "--global", "--get", "pager.diff" }));
    _ = try expectCli(arena, &environment, root, executable, &.{ "unset", "--user" });
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, root, &.{ "config", "--global", "--get", "pager.diff" })).term.exited);

    const project = try path(arena, &.{ root, "project" });
    const nested = try path(arena, &.{ project, "nested" });
    try scratch.dir.createDirPath(io, "project/nested");
    _ = try expectGit(arena, &environment, project, &.{ "init", "-q" });
    _ = try expectCli(arena, &environment, nested, executable, &.{ "set", "--project" });
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, project, &.{ "config", "--local", "--get", "pager.diff" }));
    const project_config = try path(arena, &.{ project, ".lantana.gitconfig" });
    try std.testing.expect(try exists(project_config));
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, project, &.{ "config", "--file", project_config, "--get", "pager.diff" }));
    _ = try expectGit(arena, &environment, project, &.{ "add", ".lantana.gitconfig" });
    _ = try expectGit(arena, &environment, project, &.{ "-c", "user.name=Lantana", "-c", "user.email=lantana@example.com", "commit", "-qm", "Record project pager" });

    const clone = try path(arena, &.{ root, "clone" });
    _ = try expectGit(arena, &environment, root, &.{ "clone", "-q", project, clone });
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, clone, &.{ "config", "--local", "--get", "pager.diff" })).term.exited);
    _ = try expectCli(arena, &environment, clone, executable, &.{ "set", "--project" });
    try std.testing.expectEqualStrings("lantana\n", try expectGit(arena, &environment, clone, &.{ "config", "--local", "--get", "pager.diff" }));
    _ = try expectCli(arena, &environment, clone, executable, &.{ "unset", "--project" });
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, clone, &.{ "config", "--local", "--get", "pager.diff" })).term.exited);
    try std.testing.expect(!(try exists(try path(arena, &.{ clone, ".lantana.gitconfig" }))));

    _ = try expectGit(arena, &environment, project, &.{ "config", "--file", project_config, "core.abbrev", "12" });
    _ = try expectCli(arena, &environment, project, executable, &.{ "unset", "--project" });
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, project, &.{ "config", "--local", "--get", "pager.diff" })).term.exited);
    try std.testing.expectEqual(@as(u8, 1), (try git(arena, &environment, project, &.{ "config", "--file", project_config, "--get", "pager.diff" })).term.exited);
    try std.testing.expectEqualStrings("12\n", try expectGit(arena, &environment, project, &.{ "config", "--file", project_config, "--get", "core.abbrev" }));
}
