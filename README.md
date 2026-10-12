# Lantana

[![License](https://img.shields.io/github/license/hashiiiii/Lantana)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/Lantana)](https://github.com/hashiiiii/Lantana/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/Lantana/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/Lantana/actions/workflows/ci.yml)

Lantana displays Git patches in a terminal, with a file tree and side-by-side diffs.
Run `lantana` or embed its Zig module.

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

Download the ZIP archive for your platform from [GitHub Releases](https://github.com/hashiiiii/Lantana/releases).
Extract `lantana` (`lantana.exe` on Windows), then add its directory to your `PATH`.

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

To use Lantana for `git diff`, configure Git's diff pager:

```sh
lantana set
git diff
lantana unset
```

Choose a scope:

| Command | Git configuration |
| --- | --- |
| `lantana set --project` | Current clone; creates `.lantana.gitconfig` |
| `lantana set --local` | Current clone |
| `lantana set --user` | Global |

The default scope is `--local`. Use the same flag with `unset`.

With `--project`, commit `.lantana.gitconfig`. Run `lantana set --project` once in each clone to activate it.

Use Up/Down to select files and Enter to focus the diff. Scroll with Up/Down or `j`/`k`. Press Esc to return to the tree or `q` to quit.

### Keymap

Without a configuration file, Lantana uses the [built-in keymap](src/keymap.json).
To customize bindings, copy it to your configuration directory as `keymap.json` and edit the keys:

| Environment | Path |
| --- | --- |
| `XDG_CONFIG_HOME` is nonempty | `$XDG_CONFIG_HOME/lantana/keymap.json` |
| Windows | `%APPDATA%/lantana/keymap.json` |
| macOS / Linux | `$HOME/.config/lantana/keymap.json` |

The file defines all bindings. Omitted actions and empty arrays have no keys assigned.
Global bindings take priority over bindings for the focused pane.
Only dialog bindings are active while the quit dialog is open.
Dialog actions are ignored outside the dialog; other actions are ignored inside it.

The built-in keymap groups actions as follows:

| Context | Actions |
| --- | --- |
| `global` | `quit`, `back`, `focus_next`, `toggle_render_mode` |
| `tree` | `move_up`, `move_down`, `collapse_or_focus_parent`, `expand_folder`, `activate`, `toggle_folder` |
| `content` | `scroll_up`, `scroll_down`, `page_up`, `page_down`, `pan_left`, `pan_right` |
| `dialog` | `cancel`, `confirm`, `choose_cancel`, `choose_quit`, `activate_choice` |

Any listed action can be assigned to any listed context.

Use one character or a named key with modifiers, such as `Down`, `Enter`, `Escape`, `Ctrl+q`, or `Shift+Enter`.
Separate successive presses with spaces, such as `x x`. Sequences have no timeout.
See [zig-keymap](https://github.com/hashiiiii/zig-keymap#keys) for supported keys.

If the CLI cannot load key bindings, it prints an error and returns status `2`.
Diagnostics include the file path and, for JSON syntax errors, the line and column.
It writes the captured patch to standard output.

Embedded viewers use built-in bindings unless `Options.bindings` supplies a caller-owned `lantana.Bindings` instance.
`lantana.Bindings.load(allocator, json)` returns `.bindings` or an owned `.invalid` diagnostic.
Call `deinit()` on the returned bindings or diagnostic.
Each terminal session clears pending input when it starts and ends.

## Development

Install [mise](https://mise.jdx.dev/) and [activate it in your shell](https://mise.jdx.dev/cli/activate.html). Run these commands from the repository root:

```sh
mise install
zig build
zig build test
zig build check
```

`zig build` installs `lantana` to `zig-out/bin/`.

Build the release archives and package files:

```sh
zig build release
```

Archives are in `zig-out/release/`. The Homebrew formula, Scoop manifest, and checksums are in `zig-out/packages/`.

Create and open the demo:

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

Open an issue before starting a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and required checks.

## License

Lantana is licensed under the [Apache License 2.0](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
