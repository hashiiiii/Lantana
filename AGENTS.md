# AGENTS

- Read `docs/superpowers/specs/2026-09-25-lantana-design.md` and `docs/superpowers/plans/2026-09-25-lantana.md` before implementing the viewer.
- Keep Lantana generic. Do not import PrefabLens code or add UnityYAML-specific behavior.
- Accept captured Git patches. Do not rerun `git diff` to reconstruct the caller's input.
- Preserve raw bytes and keep unsupported content visible.
- Do not add file or content search in the first release.
- Use real Git and terminal sessions for integration checks. Do not use mocks or stubs.
- Do not claim Windows terminal support without a real ConPTY check.
