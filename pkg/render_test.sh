#!/usr/bin/env bash
# Use real cross-compiled archives: package metadata must describe assets
# users can actually download, and a missing asset must block publication.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dist=${1:?pass the directory containing all release ZIP archives}
version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$repo_root/build.zig.zon")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

"$repo_root/pkg/render.sh" "$version" "$dist" "$scratch/out"
ruby -c "$scratch/out/lantana.rb" >/dev/null || fail "Homebrew formula syntax"
jq -e --arg version "$version" \
  --arg x64 "$(shasum -a 256 "$dist/lantana-windows-x64.zip" | cut -d' ' -f1)" \
  --arg arm64 "$(shasum -a 256 "$dist/lantana-windows-arm64.zip" | cut -d' ' -f1)" \
  '.version == $version and
   .architecture["64bit"].url == ("https://github.com/hashiiiii/Lantana/releases/download/v" + $version + "/lantana-windows-x64.zip") and
   .architecture["64bit"].hash == $x64 and
   .architecture.arm64.url == ("https://github.com/hashiiiii/Lantana/releases/download/v" + $version + "/lantana-windows-arm64.zip") and
   .architecture.arm64.hash == $arm64 and
   .bin == "lantana.exe"' "$scratch/out/lantana.json" >/dev/null || fail "Scoop manifest"
grep -Fq "version \"$version\"" "$scratch/out/lantana.rb" || fail "Homebrew formula version"
grep -Fq "$(shasum -a 256 "$dist/lantana-macos-arm64.zip" | cut -d' ' -f1)" "$scratch/out/lantana.rb" || fail "macOS ARM hash"
grep -Fq "$(shasum -a 256 "$dist/lantana-macos-x64.zip" | cut -d' ' -f1)" "$scratch/out/lantana.rb" || fail "macOS Intel hash"
grep -Fq "$(shasum -a 256 "$dist/lantana-linux-x64.zip" | cut -d' ' -f1)" "$scratch/out/lantana.rb" || fail "Linux hash"
grep -Fq "$(shasum -a 256 "$dist/lantana-linux-arm64.zip" | cut -d' ' -f1)" "$scratch/out/lantana.rb" || fail "Linux ARM hash"

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

mkdir "$scratch/incomplete"
cp "$dist"/lantana-*.zip "$scratch/incomplete/"
rm "$scratch/incomplete/lantana-$host.zip"
if "$repo_root/pkg/render.sh" "$version" "$scratch/incomplete" "$scratch/invalid" >/dev/null 2>&1; then
  fail "renderer accepted an incomplete release"
fi
[ ! -e "$scratch/invalid/lantana.rb" ] || fail "renderer wrote a formula for an incomplete release"
[ ! -e "$scratch/invalid/lantana.json" ] || fail "renderer wrote a manifest for an incomplete release"

echo PASS
