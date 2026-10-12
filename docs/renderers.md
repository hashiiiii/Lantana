# External renderers

Lantana can run an external command to render a file-specific view. A successful view opens in the content pane; press `m` to switch to the raw diff.

## Configure a renderer

The first diff session creates `renderers.json` beside `keymap.json`, without overwriting existing configuration:

| Environment | Path |
| --- | --- |
| Nonempty `XDG_CONFIG_HOME` | `$XDG_CONFIG_HOME/lantana/renderers.json` |
| Windows | `%APPDATA%/lantana/renderers.json` |
| macOS / Linux | `$HOME/.config/lantana/renderers.json` |

The default file contains `[]`. Edit it and restart Lantana.

## Command contract

Each rule requires `patterns` and `command`. Optional `timeout_ms` defaults to `10000`, and accepts values from `1` through `60000`.

Patterns match repository-relative paths, including folders. Matching is case-sensitive; `*` matches any substring, including `/`. Other characters are literal. The first matching rule wins.

`command` is an argv array. Lantana invokes it directly, without a shell. Each placeholder must occupy one complete argument:

| Argument | Value |
| --- | --- |
| `{before}` | Absolute path of the temporary before snapshot |
| `{after}` | Absolute path of the temporary after snapshot |
| `{path}` | Repository-relative changed path; new path for a rename |
| `{repo}` | Absolute repository root |

Commands run from `{repo}`, inherit the environment, and receive an empty stdin. The executable is resolved through `PATH`, or supplied as an absolute path.

Return exit status `0` and UTF-8 text on stdout. ANSI SGR colors, bold, dim, and underline are supported. Other terminal controls are removed before display. Each selected file is rendered once per session. Press Esc to return to the tree after switching views.

The snapshots contain the captured comparison's full contents. Added files have an empty before snapshot; deleted files have an empty after snapshot. Snapshot files are deleted after the command finishes.

Lantana retains raw output when sources cannot be verified, the command fails, output is empty or invalid, or the deadline expires. Stdout is limited to 4 MiB; stderr is limited to 16 KiB. No changed file is omitted.

Worktree snapshots are checked against the patch's blob ID. CRLF is normalized only when the resulting blob matches. Other unverified clean-filter transformations fall back to raw.

Malformed configuration prints its path, preserves the original patch on stdout, and exits with status `2`.

Only user configuration registers commands. A repository cannot install an executable renderer through a checked-in configuration file.

## For viewer authors

Your viewer can use any language. Accept two snapshot paths, read their contents, and print the view to stdout. Use `{path}` when file identity or extension matters; temporary filenames retain the selected path's extension.

A viewer can use additional literal arguments. Place `--` before path arguments if your command supports it, so filenames remain operands.

The existing Zig `DocumentRenderer` API also supports applications that embed Lantana. Successful documents open by default and remain switchable to raw.

## Example: PrefabLens

Install [PrefabLens](https://github.com/hashiiiii/PrefabLens#installation), then register it like any other external command:

```json
[
  {
    "patterns": ["*.prefab", "*.unity", "*.asset", "*.mat", "*.controller", "*.anim"],
    "command": ["prefablens", "--color", "--project", "{repo}", "{before}", "{after}"]
  }
]
```

Run `lantana set` in the repository, then `git diff`. Matching UnityYAML files show their semantic diff; other files keep the raw diff.

For a Unity project nested inside a repository, replace `{repo}` after `--project` with its absolute directory.

Verify an installed executable with this optional POSIX terminal test:

```sh
zig build test-prefablens -Dprefablens=/absolute/path/to/prefablens
```

The test launches plain `git diff` with mixed UnityYAML and C# changes, including a staged comparison with later worktree edits.
