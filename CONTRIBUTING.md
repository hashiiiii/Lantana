# Contributing to Lantana

Lantana is pre-1.0 software. Its API and command behavior may change between releases.

1. Open an issue to describe the problem or proposed change. Discuss the approach before starting a pull request.
2. Fork the repository and make the change. Keep application-specific behavior out of the Zig library.
3. Open a pull request that links the issue with `Closes #NNN`. Complete the pull request template and include the commands you ran.

## Language

Use English for issues, pull requests, documentation, comments, and commit messages. This keeps the project history readable for contributors.

## Development checks

Follow the [development setup](README.md#development). Run these commands before opening a pull request:

```sh
zig fmt --check build.zig build.zig.zon src e2e tools
zig build test
zig build check
```

Git pager behavior is covered by terminal tests that use real Git and a PTY or ConPTY.

## Releases

GitHub Releases contain the native `lantana` executables and generated release notes. Maintainers run the Release workflow from `main` with an `X.Y.Z` version. Configure `APP_CLIENT_ID` and `APP_PRIVATE_KEY` as repository secrets. The GitHub App needs Contents write access to Lantana, homebrew-tap, and scoop-bucket.

The package tool generates the Homebrew formula from the release version, supported targets, and ZIP checksums. Lantana does not store a Ruby template.
The Release workflow publishes the generated formula to `hashiiiii/homebrew-tap` and the Scoop manifest to `hashiiiii/scoop-bucket`.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
