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

View changes that have not been staged with `git add`:

```sh
git diff | lantana
```

View staged changes that will go into the next commit:

```sh
git diff --cached | lantana
```

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
| `lantana set --project` | Current clone, with the choice recorded in `.lantana.gitconfig` |
| `lantana set --local` | Current clone |
| `lantana set --user` | Global |

Without a flag, `set` and `unset` use `--local`. Use the same scope when removing the integration, for example `lantana unset --user`.

With `--project`, commit `.lantana.gitconfig` to share the pager choice. Run `lantana set --project` once in each clone to activate it.

Git selects pagers through [`pager.diff`](https://git-scm.com/docs/git-config). [`.gitattributes`](https://git-scm.com/docs/gitattributes) selects diff and merge drivers for individual files. Using a pager lets Lantana show all changed files together.

`set` leaves another configured diff pager untouched. `unset` removes only Lantana's setting in the selected scope. `GIT_PAGER` and `git --paginate` can override `pager.diff`.

In the file tree, use Up and Down to select a file, and Enter to focus its diff. Use Up, Down, `j`, and `k` to scroll. Press Esc to return to the tree, or `q` to quit. Lantana reads the patch and leaves the repository unchanged.

## Development

Install [mise](https://mise.jdx.dev/) and [activate it in your shell](https://mise.jdx.dev/cli/activate.html). Run these commands from the repository root:

```sh
mise install
zig build
zig build test
zig build check
```

`zig build` installs `lantana` to `zig-out/bin/`. `zig build test` runs unit tests and terminal tests with real Git. The terminal tests use a PTY on macOS and Linux and ConPTY on Windows. Run `bash e2e/cli.sh` after building to check `set` and `unset`. VS Code resolves Zig and ZLS from `PATH`; expose the mise tools to VS Code before opening the workspace.

To try a repository with varied changes:

```sh
zig build demo
cd .zig-cache/lantana-demo
git diff --cached | ../../zig-out/bin/lantana
```

The demo stages its changes with `git add`, so `--cached` shows those changes against its last commit. A plain `git diff` is empty immediately after generation.

The Zig module is in `src/`, terminal tests are in `e2e/`, Git fixtures and demo tools are in `tools/`, and release package templates are in `pkg/`.

## Contributing

Open an issue before starting a pull request. See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and required checks.

## License

Lantana is licensed under the [Apache License 2.0](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.
