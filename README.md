# Lantana

[![License](https://img.shields.io/github/license/hashiiiii/Lantana)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hashiiiii/Lantana)](https://github.com/hashiiiii/Lantana/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/hashiiiii/Lantana/ci.yml?branch=main&label=CI)](https://github.com/hashiiiii/Lantana/actions/workflows/ci.yml)

Lantana shows Git patches in a terminal. It groups changed files in a tree and shows text changes side by side. Use the `lantana` command as a Git diff pager, or embed the Zig module in another program.

## Installation

### Homebrew (macOS / Linux)

```sh
brew install hashiiiii/tap/lantana
```

### Scoop (Windows)

```powershell
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

Pipe a Git patch into Lantana:

```sh
git diff | lantana
git diff --cached | lantana
```

To open Lantana with a regular `git diff`, set up the diff pager:

```sh
lantana setup
git diff
lantana unset
```

Choose the same scope for `setup` and `unset`:

| Scope | Shared file | Git configuration |
| --- | --- | --- |
| `--project` | `.lantana.gitconfig` | Current clone |
| `--local` | None | Current clone |
| `--user` | None | Global |

Without a flag, both commands use `--local`. With `--project`, commit `.lantana.gitconfig` to share the choice; each clone runs `lantana setup --project` once to activate it. Lantana writes the fixed `pager.diff=lantana` value to that clone's Git configuration. The shared file is not loaded as Git configuration. `setup` leaves another configured diff pager untouched, and `unset` removes only Lantana's setting in the selected scope. `GIT_PAGER` and `git --paginate` can override `pager.diff`.

In the file tree, use Up and Down to select a file, and Enter to focus its diff. Use Up, Down, `j`, and `k` to scroll. Press Esc to return to the tree, or `q` to quit. Lantana reads the patch and leaves the repository unchanged.

## Development

Install [mise](https://mise.jdx.dev/) and run these commands from the repository root:

```sh
mise install
mise exec -- zig build
mise exec -- zig build test
mise exec -- zig build check
```

`mise exec -- zig build` installs `lantana` to `zig-out/bin/`. `mise exec -- zig build test` runs unit tests and terminal tests with real Git. The terminal tests use a PTY on macOS and Linux and ConPTY on Windows. Run `bash e2e/cli.sh` after building to check the Git setup commands. VS Code resolves Zig and ZLS from `PATH`; expose the mise tools to VS Code before opening the workspace.

To try a repository with varied changes:

```sh
mise exec -- zig build demo
cd .zig-cache/lantana-demo
git diff --cached | ../../zig-out/bin/lantana
```

The Zig module is in `src/`, terminal tests are in `e2e/`, Git fixtures and demo tools are in `tools/`, and release package templates are in `pkg/`.

## Contributing

Open an issue before starting a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and required checks.

## License

Lantana is licensed under the [Apache License 2.0](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
