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

Configure an external viewer in `renderers.json` to show file-specific views in the content pane.
Press `m` to switch between a rendered view and the raw diff.

See [External renderers](docs/renderers.md) for configuration and the command contract.

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
