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
    const example_step = b.step("example", "Install the optional Git pager example");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);
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
            .root_source_file = b.path("test/terminal.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    terminal_tests.root_module.addOptions("test_options", terminal_options);
    if (target.result.os.tag == .linux) terminal_tests.root_module.linkSystemLibrary("util", .{});
    check_step.dependOn(&terminal_tests.step);
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);

    if (target.result.os.tag != .windows) {
        const fixture_generator = b.addExecutable(.{
            .name = "fixture-generator",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/create_git_fixtures.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const fixtures_step = b.step("fixtures", "Regenerate Git patch fixtures using Zig");
        fixtures_step.dependOn(&b.addRunArtifact(fixture_generator).step);
    }
}
