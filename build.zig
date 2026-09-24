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
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lantana", .module = lantana }},
        }),
    });
    const test_step = b.step("test", "Run unit and terminal integration tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (target.result.os.tag != .windows) {
        const pager_test = b.addSystemCommand(&.{ "python3", b.pathFromRoot("test/pager_pty.py") });
        pager_test.addArtifactArg(example);
        test_step.dependOn(&pager_test.step);
        const viewer_test = b.addSystemCommand(&.{ "python3", b.pathFromRoot("test/viewer_pty.py") });
        viewer_test.addArtifactArg(example);
        test_step.dependOn(&viewer_test.step);
        const edges_test = b.addSystemCommand(&.{ "python3", b.pathFromRoot("test/viewer_edges_pty.py") });
        edges_test.addArtifactArg(example);
        test_step.dependOn(&edges_test.step);
    }
}
