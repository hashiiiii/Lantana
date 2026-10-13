# Lantana

[![License](https://img.shields.io/github/license/hashiiiii/Lantana)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/Lantana)](https://github.com/hashiiiii/Lantana/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/Lantana/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/Lantana/actions/workflows/ci.yml)

Lantana is a terminal viewer for Git patches, with a file tree and side-by-side diffs.  
Use `lantana` or embed its Zig module.

<p align="center">
  <img width="924" src="docs/images/top.png" alt="Lantana showing a file tree and side-by-side Git diffs" />
</p>

## Installation

### Homebrew (macOS / Linux)

```sh
brew install hashiiiii/tap/lantana
```

### Scoop (Windows)

```sh
scoop bucket add hashiiiii https://github.com/hashiiiii/scoop-bucket
scoop install lantana
```

### mise

```sh
mise use -g github:hashiiiii/Lantana
```

### Manual

Download your platform's ZIP from [GitHub Releases](https://github.com/hashiiiii/Lantana/releases).  
Extract `lantana` (`lantana.exe` on Windows) and add its directory to `PATH`.

## Usage

View staged and unstaged changes:

```sh
git diff HEAD | lantana
```

| Changes | Command |
| --- | --- |
| Unstaged | `git diff \| lantana` |
| Staged | `git diff --cached \| lantana` |

### Git integration

Set Lantana as Git's diff pager, then remove the setting with `unset`:

```sh
lantana set
git diff
lantana unset
```

| Command | Git configuration |
| --- | --- |
| `lantana set --project` | Current clone; creates `.lantana.gitconfig` |
| `lantana set --local` | Current clone |
| `lantana set --user` | Global |

`--local` is the default. Pass the same scope to `unset`.

For `--project`, commit `.lantana.gitconfig` and run `lantana set --project` once in each clone.

Select files with Up/Down, press Enter to focus the diff, and Esc to return to the tree.  
Scroll with Up/Down or `j`/`k`; press `q` to quit.

### External renderers

Lantana runs user-configured commands to render file-specific views.
Successful output opens in the content pane; press `m` to switch to the raw diff.

The first diff session creates `renderers.json` containing `[]` beside `keymap.json`, preserving existing files.
Edit it and restart Lantana:

| Environment | Path |
| --- | --- |
| `XDG_CONFIG_HOME` is nonempty | `$XDG_CONFIG_HOME/lantana/renderers.json` |
| Windows | `%APPDATA%/lantana/renderers.json` |
| macOS / Linux | `$HOME/.config/lantana/renderers.json` |

Only user configuration registers commands.

#### Command contract

Each rule requires `patterns` and `command`. Optional `timeout_ms` defaults to `10000` and accepts values from `1` through `60000`.

Patterns match repository-relative paths, including folders. Matching is case-sensitive; `*` matches any substring, including `/`.
Other characters are literal. The first matching rule wins.

`command` is an argv array, invoked directly without a shell. Each placeholder must occupy one complete argument:

| Argument | Value |
| --- | --- |
| `{before}` | Absolute path of the temporary before snapshot |
| `{after}` | Absolute path of the temporary after snapshot |
| `{path}` | Repository-relative changed path; new path for a rename |
| `{repo}` | Absolute repository root |

Commands run from `{repo}`, inherit the environment, and receive an empty stdin.
Supply the executable through `PATH` or an absolute path. Additional arguments are passed literally.
If supported, place `--` before path arguments so filenames remain operands.

Viewers can use any language. Read the snapshots and print the view to stdout.
Use `{path}` when file identity or extension matters.
Return exit status `0` and nonempty UTF-8 text on stdout.
ANSI SGR colors, bold, dim, and underline are supported; other terminal controls are removed before display.
Each selected file is rendered once per session.

Snapshots contain the captured comparison's full contents and retain the selected path's extension.
Added files have an empty before snapshot; deleted files have an empty after snapshot.
Snapshot files are deleted after the command finishes.

Worktree contents are verified against the patch's blob ID. CRLF is normalized only when the resulting blob matches.
Unverified clean-filter transformations fall back to raw.

Lantana keeps the raw diff if sources cannot be verified.
Failed commands, empty or invalid output, and timeouts also fall back to raw.
Stdout is limited to 4 MiB; stderr is limited to 16 KiB. Every changed file remains available.

Malformed configuration prints its path, preserves the original patch on stdout, and exits with status `2`.

#### Example: PrefabLens

Install [PrefabLens](https://github.com/hashiiiii/PrefabLens#installation), then register it like any other external command:

```json
[
  {
    "patterns": ["*.prefab", "*.unity", "*.asset", "*.mat", "*.controller", "*.anim"],
    "command": ["prefablens", "--color", "--project", "{repo}", "{before}", "{after}"]
  }
]
```

Run `lantana set` in the repository, then `git diff`.
Matching UnityYAML files show their semantic diff; other files keep the raw diff.
For a Unity project nested inside a repository, replace `{repo}` after `--project` with its absolute directory.

### Keymap

The first time you view a diff, Lantana creates `keymap.json` with the [default bindings](src/keymap.json).  
This works with Homebrew, Scoop, mise, and manual installations. Existing files are never overwritten.

Edit the file at the path below, then restart Lantana to apply changes:

| Environment | Path |
| --- | --- |
| `XDG_CONFIG_HOME` is nonempty | `$XDG_CONFIG_HOME/lantana/keymap.json` |
| Windows | `%APPDATA%/lantana/keymap.json` |
| macOS / Linux | `$HOME/.config/lantana/keymap.json` |

#### Contexts

Place bindings in the context for their UI:

| Context | Active UI |
| --- | --- |
| `global` | Either pane, except while the dialog is open |
| `tree` | Left file tree, when focused |
| `content` | Right diff pane, when focused |
| `dialog` | Quit confirmation dialog; all other contexts are inactive |

<p align="center">
  <img width="924" src="docs/images/tree-content.png" alt="Left tree and right content contexts" />
</p>

<p align="center">
  <img width="924" src="docs/images/dialog.png" alt="Quit confirmation dialog context" />
</p>

See [zig-keymap](https://github.com/hashiiiii/zig-keymap#keys) for key syntax.

## Development

Install [mise](https://mise.jdx.dev/) and [activate it](https://mise.jdx.dev/cli/activate.html). Then, from the repository root:

```sh
mise install
zig build
zig build test
zig build check
```

`zig build` installs `lantana` to `zig-out/bin/`.

Applications embedding the Zig module can supply a [`DocumentRenderer`](src/root.zig).
Successful documents open by default and remain switchable to raw.

The optional PrefabLens compatibility test launches plain `git diff` with mixed UnityYAML and C# changes.
It requires an installed executable and a POSIX terminal:

```sh
zig build test-prefablens -Dprefablens=/absolute/path/to/prefablens
```

Build release archives and package files:

```sh
zig build release
```

`zig-out/release/` contains the archives; `zig-out/packages/` contains the Homebrew formula, Scoop manifest, and checksums.

Run the demo:

```sh
zig build demo
cd .zig-cache/lantana-demo
git diff HEAD | ../../zig-out/bin/lantana
```

| Directory | Contents |
| --- | --- |
| `src/` | Zig library and CLI |
| `e2e/` | Terminal and CLI tests |
| `tools/` | Git fixture, demo, and release package generators |

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md)

## License

[Apache License 2.0](LICENSE)
