# Lantana

Lantana is a planned Zig library for reviewing Git patches in a terminal. It is designed to be embedded in another program. PrefabLens is its first intended consumer.

The first release will show a changed-file tree and a two-column raw diff. A caller may supply a rendered document for a selected file. Lantana will show that document in the right pane and allow a switch back to the raw diff. The first release will not include search.

Lantana will accept the patch that Git already produced. It will not run another `git diff` to reconstruct the caller's arguments. Unsupported patch shapes must remain visible as original text.

The project is at the design stage. It has no buildable library or installed executable yet. See the [design](docs/superpowers/specs/2026-09-25-lantana-design.md) and [implementation plan](docs/superpowers/plans/2026-09-25-lantana.md).

## Intended use from PrefabLens

Git can start `prefablens diff-pager` through `pager.diff`. PrefabLens will read Git's patch from standard input and pass it to Lantana. For UnityYAML files, PrefabLens will recover the exact compared versions and supply its existing semantic tree as a document. Lantana will own the file tree, raw comparison, and terminal interaction.

Lantana is intended to be a source dependency linked into one `prefablens` executable. It will not require users to install another program.

The license will be selected before public publication.
