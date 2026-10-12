# Lantana

[![License](https://img.shields.io/github/license/hashiiiii/Lantana)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/Lantana)](https://github.com/hashiiiii/Lantana/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/Lantana/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/Lantana/actions/workflows/ci.yml)

Lantana is a terminal viewer for Git patches, with a file tree and side-by-side diffs.
Use `lantana` or embed its Zig module.

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

### Keymap

The first time you view a diff, Lantana creates `keymap.json` with the [default bindings](src/keymap.json).
This works with Homebrew, Scoop, mise, and manual installations. Existing files are never overwritten.

Edit the file at the path below, then restart Lantana to apply changes:

| Environment | Path |
| --- | --- |
| `XDG_CONFIG_HOME` is nonempty | `$XDG_CONFIG_HOME/lantana/keymap.json` |
| Windows | `%APPDATA%/lantana/keymap.json` |
| macOS / Linux | `$HOME/.config/lantana/keymap.json` |

For example, set `global.quit` to `["Ctrl+q"]` to quit with Ctrl+q.

Omitted actions and `[]` are unbound.
Global bindings take priority over bindings for the focused pane.
The quit dialog uses only `dialog` bindings.
Dialog actions work only there; other actions work outside it.

Default contexts and actions:

| Context | Actions |
| --- | --- |
| `global` | `quit`, `back`, `focus_next`, `toggle_render_mode` |
| `tree` | `move_up`, `move_down`, `collapse_or_focus_parent`, `expand_folder`, `activate`, `toggle_folder` |
| `content` | `scroll_up`, `scroll_down`, `page_up`, `page_down`, `pan_left`, `pan_right` |
| `dialog` | `cancel`, `confirm`, `choose_cancel`, `choose_quit`, `activate_choice` |

Any action can be assigned to any context.

Keys use one character or a name, with optional modifiers: `Down`, `Enter`, `Escape`, `Ctrl+q`, `Shift+Enter`.
Separate sequence keys with spaces, such as `x x`; sequences have no timeout.
See [zig-keymap](https://github.com/hashiiiii/zig-keymap#keys) for supported keys.

If key bindings cannot be loaded, the CLI prints an error with the path and exits with status `2`.
It writes the captured patch to stdout. JSON syntax errors also include the line and column.

Embedded viewers use the defaults or a caller-owned `lantana.Bindings` instance supplied through `Options.bindings`.
`lantana.Bindings.load(allocator, json)` returns `.bindings` or an owned `.invalid` diagnostic; call `deinit()` on either.
Terminal sessions clear pending input on entry and exit.

## Development

Install [mise](https://mise.jdx.dev/) and [activate it](https://mise.jdx.dev/cli/activate.html). Then, from the repository root:

```sh
mise install
zig build
zig build test
zig build check
```

`zig build` installs `lantana` to `zig-out/bin/`.

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

Open an issue before a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and required checks.

## License

Lantana is licensed under the [Apache License 2.0](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
