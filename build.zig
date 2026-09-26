const std = @import("std");
const zon = @import("build.zig.zon");
const release_targets = @import("tools/release_targets.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const lantana = b.addModule("lantana", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "vaxis", .module = vaxis_dep.module("vaxis") }},
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lantana", .module = lantana },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const cli = b.addExecutable(.{
        .name = "lantana",
        .root_module = cli_module,
    });
    b.installArtifact(cli);
    const check_step = b.step("check", "Compile the pager without running terminal tests");
    check_step.dependOn(&cli.step);
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
    terminal_options.addOptionPath("pager_path", cli.getEmittedBin());
    if (target.result.os.tag != .windows) {
        const document_pager = b.addExecutable(.{
            .name = "lantana-document-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("e2e/document_pager.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "cli", .module = cli_module },
                    .{ .name = "lantana", .module = lantana },
                },
            }),
        });
        terminal_options.addOptionPath("document_pager_path", document_pager.getEmittedBin());
    }
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
    terminal_tests.root_module.addImport("build_options", options.createModule());
    if (target.result.os.tag == .linux) terminal_tests.root_module.linkSystemLibrary("util", .{});
    check_step.dependOn(&terminal_tests.step);
    test_step.dependOn(&b.addRunArtifact(terminal_tests).step);
    const package_tests = b.addTest(.{
        .name = "package-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/package_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    check_step.dependOn(&package_tests.step);
    test_step.dependOn(&b.addRunArtifact(package_tests).step);
    const test_binaries_step = b.step("test-bins", "Install test executables for direct Windows runs");
    test_binaries_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    test_binaries_step.dependOn(&b.addInstallArtifact(terminal_tests, .{}).step);
    test_binaries_step.dependOn(&b.addInstallArtifact(package_tests, .{}).step);
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
    demo_step.dependOn(b.getInstallStep());
    demo_step.dependOn(&b.addRunArtifact(demo_generator).step);
    const scroll_demo = b.addRunArtifact(demo_generator);
    scroll_demo.addArg("--scroll");
    const scroll_demo_step = b.step("demo-scroll", "Create a local Git repository with a tall and wide diff");
    scroll_demo_step.dependOn(b.getInstallStep());
    scroll_demo_step.dependOn(&scroll_demo.step);

    const package_tool = b.addExecutable(.{
        .name = "lantana-package-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/package.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const archive_step = b.step("archive", "Build one release archive for the selected target");
    if (release_targets.forTarget(target.result)) |archive_target| {
        const archive_command = b.addSystemCommand(&.{ "zip", "-q", "-j" });
        const archive_path = archive_command.addOutputFileArg(b.fmt("lantana-{s}.zip", .{archive_target.asset}));
        archive_command.addArtifactArg(cli);
        const archive_install = b.addInstallFile(archive_path, b.fmt("release/lantana-{s}.zip", .{archive_target.asset}));
        archive_step.dependOn(&archive_install.step);
    } else {
        const triple = target.result.zigTriple(b.allocator) catch "unknown-target";
        archive_step.dependOn(&b.addFail(b.fmt("archive supports the six release targets only; got {s}", .{triple})).step);
    }

    const packages_step = b.step("packages", "Validate release archives and render package metadata");
    const package_run = b.addRunArtifact(package_tool);
    package_run.addArg("render");
    package_run.addArg(zon.version);
    const package_dist = if (b.args) |args| blk: {
        if (args.len != 1) std.process.fatal("zig build packages expects exactly one archive directory after --\n", .{});
        break :blk args[0];
    } else "dist";
    package_run.addArg(b.pathFromRoot(package_dist));
    package_run.addArg(b.getInstallPath(.{ .custom = "packages" }, ""));
    package_run.addArg(b.pathFromRoot("pkg/lantana.rb"));
    package_run.addArg(b.pathFromRoot("pkg/lantana.json"));
    package_run.addFileInput(b.path("pkg/lantana.rb"));
    package_run.addFileInput(b.path("pkg/lantana.json"));
    package_run.stdio = .inherit;
    packages_step.dependOn(&package_run.step);

    const release_step = b.step("release", "Build all release archives and render package metadata");
    const release_dist = b.getInstallPath(.{ .custom = "release" }, "");
    const release_packages = b.getInstallPath(.{ .custom = "packages" }, "");
    const release_package_run = b.addRunArtifact(package_tool);
    for (release_targets.targets) |release_target| {
        const target_query = std.Build.parseTargetQuery(.{ .arch_os_abi = release_target.query }) catch unreachable;
        const release_target_resolved = b.resolveTargetQuery(target_query);
        const release_vaxis = b.dependency("vaxis", .{ .target = release_target_resolved, .optimize = .ReleaseSafe });
        const release_lantana = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = release_target_resolved,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "vaxis", .module = release_vaxis.module("vaxis") }},
        });
        const release_cli_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = release_target_resolved,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "lantana", .module = release_lantana },
                .{ .name = "build_options", .module = options.createModule() },
            },
        });
        const release_cli = b.addExecutable(.{
            .name = "lantana",
            .root_module = release_cli_module,
        });
        const archive = b.addSystemCommand(&.{ "zip", "-q", "-j" });
        const release_archive_path = archive.addOutputFileArg(b.fmt("lantana-{s}.zip", .{release_target.asset}));
        archive.addArtifactArg(release_cli);
        const release_install_archive = b.addInstallFile(release_archive_path, b.fmt("release/lantana-{s}.zip", .{release_target.asset}));
        release_step.dependOn(&release_install_archive.step);
        release_package_run.step.dependOn(&release_install_archive.step);
    }

    release_package_run.addArg("render");
    release_package_run.addArg(zon.version);
    release_package_run.addArg(release_dist);
    release_package_run.addArg(release_packages);
    release_package_run.addArg(b.pathFromRoot("pkg/lantana.rb"));
    release_package_run.addArg(b.pathFromRoot("pkg/lantana.json"));
    release_package_run.addArg(release_dist);
    release_package_run.addFileInput(b.path("pkg/lantana.rb"));
    release_package_run.addFileInput(b.path("pkg/lantana.json"));
    release_package_run.stdio = .inherit;
    release_step.dependOn(&release_package_run.step);
}
