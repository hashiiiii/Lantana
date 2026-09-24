# Lantana

Lantana is a Zig library for reviewing a captured Git patch in a terminal. It shows changed files in a collapsible tree and aligns ordinary text hunks in Before and After columns. A caller may supply a full-width document for a selected file. Lantana does not run Git or change the repository.

The package targets Zig 0.16.0. Release support is pending terminal checks on all target platforms and integration with its first consumer.

## Add the package

Pin a commit when adding the archive to a consumer's `build.zig.zon`. Replace `<commit>` with a Lantana commit and `<hash>` with the result of `zig fetch` for that URL:

```sh
zig fetch https://github.com/hashiiiii/Lantana/archive/<commit>.tar.gz
```

```zig
.dependencies = .{
    .lantana = .{
        .url = "https://github.com/hashiiiii/Lantana/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Import its module in the consumer's `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("lantana", .{ .target = target, .optimize = optimize });
    const application = b.addExecutable(.{
        .name = "my-pager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lantana", .module = dependency.module("lantana") }},
        }),
    });
    b.installArtifact(application);
}
```

Lantana exports a module. It installs no executable as a runtime dependency. The `git-pager` executable in this repository is an optional integration example.

## Call the viewer

Read the complete patch from standard input before calling `lantana.run`. Keep those bytes alive until the call returns. Pass the process I/O and environment from `std.process.Init`:

```zig
const std = @import("std");
const lantana = @import("lantana");

fn showPatch(init: std.process.Init, patch: []const u8) !void {
    try lantana.run(std.heap.page_allocator, patch, .{
        .io = init.io,
        .environ = init.environ_map,
        .theme = .{},
    });
}
```

An empty patch returns without entering the alternate screen. The caller handles errors from `run`. In particular, if terminal initialization fails, the caller can write its retained patch to standard output. The example does this for a detached pager. The example caps input at 32 MiB; the library does not set that limit.

The Git pager receives the patch through standard input. Lantana opens terminal input separately, using `/dev/tty` on POSIX and console handles on Windows. The caller owns Git configuration, patch capture, and any source recovery.

## Render a document

Set `Options.renderer` to a `DocumentRenderer`. Lantana calls it when a file is selected. `FileMetadata` contains the exact patch section, old and new paths, and available blob IDs. The callback may return `.text` with ANSI SGR styles or `.unavailable` with a reason:

```zig
fn renderDocument(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    file: lantana.FileMetadata,
) anyerror!lantana.Document {
    _ = context;
    const path = file.new_path orelse file.old_path orelse return .{ .unavailable = "No path" };
    return .{ .text = try std.fmt.allocPrint(allocator, "Document: {s}\n", .{path}) };
}

const renderer: lantana.DocumentRenderer = .{ .render = renderDocument };
```

Allocate returned text for the supplied allocator, or return text that stays valid until `run` returns. Lantana strips unsupported control sequences before drawing. A renderer error, unavailable result, or invalid document opens the raw patch with a visible reason. It retains unsupported Git sections as captured text.

`Theme` accepts plain RGB `Color` values for foreground, background, accent, removed lines, and added lines. Its defaults work without configuration. The public renderer and theme interface contains no `libvaxis` types.

## Try the example

```sh
mise exec -- zig build example
git -c "core.pager='$(pwd)/zig-out/bin/git-pager'" -c pager.diff=true --paginate diff
```

The example's `--demo-document` option displays a sample document for `.prefab` files. It does not interpret their contents. In the viewer, use Up and Down to select files, `c` to collapse or reopen a folder, `m` to switch modes, `j` and `k` to scroll, `h` and `l` to pan, and `q` to quit. Raw tabs appear as arrows. Mouse selection and resize are supported.

Run `mise exec -- zig build test` for unit tests and real Git terminal tests. The terminal tests use a PTY on macOS and Linux and ConPTY on Windows. Run `mise exec -- zig build fixtures` on macOS or Linux to regenerate the committed patches with Git. `mise exec -- zig build check -Dtarget=x86_64-windows-gnu` checks Windows compilation from another host.

Lantana uses the Apache License 2.0. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
