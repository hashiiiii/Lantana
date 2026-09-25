# Lantana

Lantana is a Zig library for reviewing a captured Git patch in a terminal. It shows changed files in a collapsible tree and aligns text lines in two columns. Changed lines have tinted backgrounds. A caller may supply a document or complete file text for a selected file. Lantana does not run Git or change the repository.

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

Set `Options.file_text` to a `FileTextProvider` when the viewer should reveal lines omitted from the patch. The callback receives `FileMetadata` and returns the full before and after text. Lantana checks that the supplied text matches every captured hunk before it folds unchanged ranges. If the text is missing or stale, the captured patch remains visible. The example pager reads Git blobs and checks a working tree file's object ID before using it.

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

Allocate returned text for the supplied allocator, or return text that stays valid until `run` returns. Lantana strips unsupported control sequences before drawing. Raw diff is the initial view; press `m` to show a supplied document. A renderer error, unavailable result, or invalid document keeps the raw patch visible. Unsupported Git sections remain available as captured text.

`Theme` accepts plain RGB `Color` values for foreground, background, accent, removed lines, and added lines. Its defaults work without configuration. The public renderer and theme interface contains no `libvaxis` types.

## Try the example

```sh
mise exec -- zig build example
git -c "core.pager='$(pwd)/zig-out/bin/git-pager'" -c pager.diff=true --paginate diff
```

The example's `--demo-document` option makes a sample document available for `.prefab` files. Press `m` to view it. It does not interpret their contents. Choose a Nerd Font in your terminal to display the folder and extension icons. Icon selection uses a small built-in table and adds no dependency.

In the left pane, Up and Down visit folders and files. Left closes a folder or selects its parent; Right opens a folder. Enter toggles a folder or focuses the right pane for a file.

In the right pane, Up, Down, `j`, `k`, Page Up, and Page Down scroll vertically. Left, Right, `h`, and `l` pan across long lines. Trackpad gestures also pan when the terminal reports horizontal mouse events. Vertical scrolling reveals a bar at the right edge. Horizontal panning reveals a bar along the bottom when lines extend past the pane. Both bars support clicks and dragging. Click a folded range to toggle it. Drag across source text and release to copy it through OSC 52, if your terminal permits clipboard access. Raw tabs appear as arrows.

Esc in the right pane returns to the left pane. Esc in the left pane opens a quit dialog with Cancel selected. `q` quits directly. Resize is supported.

To try more changes in one review, create a separate local Git repository:

```sh
mise exec -- zig build demo
pager="$(pwd)/zig-out/bin/git-pager"
cd .zig-cache/lantana-demo
GIT_PAGER="'$pager' --demo-document" git --paginate diff --cached
```

The demo has 33 changed files. They cover additions, deletions, a rename, a binary file, a mode change, and quoted paths. One file has two distant hunks. Another ends without a final newline. The file list is long enough to scroll. The changes are staged, so one Git command shows all of them. `zig build demo` leaves an existing `.zig-cache/lantana-demo` untouched.

To try vertical and horizontal scrolling on one file, create a separate demo:

```sh
mise exec -- zig build demo-scroll
pager="$(pwd)/zig-out/bin/git-pager"
cd .zig-cache/lantana-scroll-demo
GIT_PAGER="'$pager'" git --paginate diff --cached
```

`Long/WideAndTall.cs` has 180 changed lines, each 200 characters wide. `zig build demo-scroll` leaves an existing `.zig-cache/lantana-scroll-demo` untouched.

Run `mise exec -- zig build test` for unit tests and real Git terminal tests. Product unit tests live beside their code in `src/`. The screen helper keeps its unit test in `tools/terminal_screen.zig`. Terminal E2E tests and platform support live in `e2e/`. The Git helper and both generators live in `tools/`.

The terminal tests use a PTY on macOS and Linux and ConPTY on Windows. Run `mise exec -- zig build fixtures` on macOS or Linux to regenerate the committed patches with Git. `mise exec -- zig build check -Dtarget=x86_64-windows-gnu` checks Windows compilation from another host.

Lantana uses the Apache License 2.0. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
