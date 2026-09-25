# Contributing to Lantana

Lantana is pre-1.0 software. Its API and command behavior may change between releases.

1. Open an issue to describe the problem or proposed change. Discuss the approach before starting a pull request.
2. Fork the repository and make the change. Keep application-specific behavior out of the Zig library.
3. Open a pull request that links the issue with `Closes #NNN`. Complete the pull request template and include the commands you ran.

## Language

Use English for issues, pull requests, documentation, comments, and commit messages. This keeps the project history readable for contributors.

## Development checks

Install the tools with `mise install`. Run `mise exec -- zig fmt --check build.zig build.zig.zon src e2e tools`, `mise exec -- zig build test`, and `mise exec -- zig build check` before opening a pull request. Git pager behavior is covered by terminal tests that use real Git and a PTY or ConPTY.

## Releases

GitHub Releases contain the native `lantana` executables and generated release notes. Maintainers publish releases through the Release workflow.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
