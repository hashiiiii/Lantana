#!/usr/bin/env bash
# Validate package files against release archives, including a runnable host binary.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dist=${1:?pass the directory containing the release ZIP archives}
version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$repo_root/build.zig.zon")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
sha() { shasum -a 256 "$dist/lantana-$1.zip" | cut -d' ' -f1; }

"$repo_root/pkg/render.sh" "$version" "$dist" "$scratch/out"
ruby -c "$scratch/out/lantana.rb" >/dev/null || fail "Homebrew formula syntax"
grep -Fq "version \"$version\"" "$scratch/out/lantana.rb" || fail "Homebrew formula version"
for target in macos-arm64 macos-x64 linux-arm64 linux-x64; do
  grep -Fq "$(sha "$target")" "$scratch/out/lantana.rb" || fail "Homebrew $target hash"
done
jq -e --arg version "$version" --arg x64 "$(sha windows-x64)" --arg arm64 "$(sha windows-arm64)" \
  '.version == $version and
   .architecture["64bit"].url == ("https://github.com/hashiiiii/Lantana/releases/download/v" + $version + "/lantana-windows-x64.zip") and
   .architecture["64bit"].hash == $x64 and
   .architecture.arm64.url == ("https://github.com/hashiiiii/Lantana/releases/download/v" + $version + "/lantana-windows-arm64.zip") and
   .architecture.arm64.hash == $arm64 and
   .bin == "lantana.exe"' "$scratch/out/lantana.json" >/dev/null || fail "Scoop manifest"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host=macos-arm64 ;;
  Darwin-x86_64) host=macos-x64 ;;
  Linux-aarch64 | Linux-arm64) host=linux-arm64 ;;
  Linux-x86_64) host=linux-x64 ;;
  *) fail "unsupported test host" ;;
esac
mkdir "$scratch/installed"
unzip -q "$dist/lantana-$host.zip" -d "$scratch/installed"
[ "$("$scratch/installed/lantana" --version)" = "lantana $version" ] || fail "released binary version"

echo PASS
