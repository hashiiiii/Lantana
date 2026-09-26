# Lantana

[![License](https://img.shields.io/github/license/hashiiiii/Lantana)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/Lantana)](https://github.com/hashiiiii/Lantana/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/Lantana/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/Lantana/actions/workflows/ci.yml)

Lantana is a terminal viewer for Git patches, with a file tree and side-by-side diffs. Use the `lantana` command or embed the Zig module.

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

Download the ZIP archive for your platform from [GitHub Releases](https://github.com/hashiiiii/Lantana/releases). Extract the `lantana` executable (`lantana.exe` on Windows) and add its directory to your `PATH`.

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

To open Lantana with a regular `git diff`, set the diff pager:

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

Create `keymap.toml` in your configuration directory:

| Environment | Path |
| --- | --- |
| `XDG_CONFIG_HOME` is set | `$XDG_CONFIG_HOME/lantana/keymap.toml` |
| Windows | `%APPDATA%/lantana/keymap.toml` |
| macOS / Linux | `$HOME/.config/lantana/keymap.toml` |

```toml
[global]
quit = ["Ctrl+q"]

[content]
page_down = ["Ctrl+d"]
page_up = ["Ctrl+u"]
```

Arrays replace an action's keys. Unspecified actions retain their defaults. `[]` disables an action.

| Context | Actions |
| --- | --- |
| `global` | `quit`, `back`, `focus_next`, `toggle_render_mode` |
| `tree` | `move_up`, `move_down`, `collapse_or_focus_parent`, `expand_folder`, `activate`, `toggle_folder` |
| `content` | `scroll_up`, `scroll_down`, `page_up`, `page_down`, `pan_left`, `pan_right` |
| `dialog` | `cancel`, `confirm`, `choose_cancel`, `choose_quit`, `activate_choice` |

Use one character or a named key with modifiers, such as `Down`, `Enter`, `Escape`, `Ctrl+q`, or `Shift+Enter`.
See [zig-keymap](https://github.com/hashiiiii/zig-keymap#keys) for supported keys.

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

Archives are written to `zig-out/release/`. Homebrew and Scoop files are written to `zig-out/packages/`.

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
| `tools/` | Git fixture and demo generators |
| `pkg/` | Release package templates |

## Contributing

Open an issue before starting a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and required checks.

## License

Lantana is licensed under the [Apache License 2.0](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
