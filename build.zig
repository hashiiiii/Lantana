const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const lantana = b.addModule("lantana", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
    });
    const example = b.addExecutable(.{
        .name = "git-pager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/git-pager.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lantana", .module = lantana }},
        }),
    });
    const install_example = b.addInstallArtifact(example, .{});
    const example_step = b.step("example", "Install the optional Git pager example");
    example_step.dependOn(&install_example.step);
    const check_step = b.step("check", "Compile the pager without running terminal tests");
    check_step.dependOn(&example.step);
    const tests = b.addTest(.{
        .name = "lantana-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
        }),
    });
    const test_step = b.step("test", "Run unit and terminal integration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const terminal_options = b.addOptions();
    terminal_options.addOptionPath("pager_path", example.getEmittedBin());
    const terminal_tests = b.addTest(.{
        .name = "terminal-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/terminal.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
        }),
    });
    terminal_tests.root_module.addImport("git_repo", b.createModule(.{
        .root_source_file = b.path("tools/git_repo.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const terminal_screen = b.createModule(.{
        .root_source_file = b.path("tools/terminal_screen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
    });
    terminal_tests.root_module.addImport("terminal_screen", terminal_screen);
    terminal_tests.root_module.addOptions("test_options", terminal_options);
    if (target.result.os.tag == .linux) terminal_tests.root_module.linkSystemLibrary("util", .{});
    check_step.dependOn(&terminal_tests.step);
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);
    const test_binaries_step = b.step("test-bins", "Install test executables for direct Windows runs");
    test_binaries_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    test_binaries_step.dependOn(&b.addInstallArtifact(terminal_tests, .{}).step);
    if (target.result.os.tag != .windows) {
        // The screen emulator backs POSIX PTY assertions; Windows uses ConPTY output directly.
        const screen_tests = b.addTest(.{ .name = "terminal-screen-test", .root_module = terminal_screen });
        check_step.dependOn(&screen_tests.step);
        test_step.dependOn(&b.addRunArtifact(screen_tests).step);
    }

    if (target.result.os.tag != .windows) {
        const fixture_generator = b.addExecutable(.{
            .name = "fixture-generator",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/create_git_fixtures.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const fixtures_step = b.step("fixtures", "Regenerate Git patch fixtures using Zig");
        fixtures_step.dependOn(&b.addRunArtifact(fixture_generator).step);
    }

    const demo_generator = b.addExecutable(.{
        .name = "create-demo-repo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/create_demo_repo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const demo_step = b.step("demo", "Create a local Git repository with varied changes");
    demo_step.dependOn(&install_example.step);
    demo_step.dependOn(&b.addRunArtifact(demo_generator).step);
    const scroll_demo = b.addRunArtifact(demo_generator);
    scroll_demo.addArg("--scroll");
    const scroll_demo_step = b.step("demo-scroll", "Create a local Git repository with a tall and wide diff");
    scroll_demo_step.dependOn(&install_example.step);
    scroll_demo_step.dependOn(&scroll_demo.step);
}
