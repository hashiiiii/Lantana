#!/usr/bin/env bash
# Render package metadata only after every platform archive has the expected
# root entry, so package managers cannot publish a broken or partial release.
set -euo pipefail

if [ "$#" -ne 3 ] || [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: render.sh <X.Y.Z> <dist-dir> <out-dir>" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
version=$1
dist=$2
out=$3

targets=(macos-arm64 macos-x64 linux-x64 linux-arm64 windows-x64 windows-arm64)
for target in "${targets[@]}"; do
  archive="$dist/lantana-$target.zip"
  expected=lantana
  if [[ "$target" == windows-* ]]; then expected=lantana.exe; fi
  if ! actual=$(unzip -Z1 "$archive" 2>/dev/null); then
    echo "error: cannot read release archive: $archive" >&2
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "error: $archive must contain only $expected at the ZIP root" >&2
    exit 1
  fi
done

sha() { shasum -a 256 "$dist/lantana-$1.zip" | cut -d' ' -f1; }

mkdir -p "$out"
sed -e "s/{{VERSION}}/$version/g" \
    -e "s/{{SHA256_MACOS_ARM64}}/$(sha macos-arm64)/g" \
    -e "s/{{SHA256_MACOS_X64}}/$(sha macos-x64)/g" \
    -e "s/{{SHA256_LINUX_ARM64}}/$(sha linux-arm64)/g" \
    -e "s/{{SHA256_LINUX_X64}}/$(sha linux-x64)/g" \
    "$script_dir/lantana.rb" > "$out/lantana.rb"

sed -e "s/{{VERSION}}/$version/g" \
    -e "s/{{SHA256_WINDOWS_X64}}/$(sha windows-x64)/g" \
    -e "s/{{SHA256_WINDOWS_ARM64}}/$(sha windows-arm64)/g" \
    "$script_dir/lantana.json" > "$out/lantana.json"

if grep -q '{{' "$out/lantana.rb" "$out/lantana.json"; then
  echo "error: unrendered package placeholder" >&2
  exit 1
fi
