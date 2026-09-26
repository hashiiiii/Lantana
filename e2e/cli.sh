#!/usr/bin/env bash
# Real Git repositories catch scope mistakes that a parser-only test cannot.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
binary="$repo_root/zig-out/bin/lantana"
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) binary="$binary.exe" ;; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL="$scratch/global" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$scratch/xdg"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$binary" ] || fail "missing lantana executable"
version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$repo_root/build.zig.zon")
[ "$("$binary" --version)" = "lantana $version" ] || fail "binary version"
[ -z "$(printf '' | "$binary")" ] || fail "empty patch output"

git init -q "$scratch/local"
cd "$scratch/local"
"$binary" setup
[ "$(git config --local --get pager.diff)" = lantana ] || fail "default local setup"
"$binary" setup --local
[ "$(git config --local --get-all pager.diff)" = lantana ] || fail "repeated setup"
"$binary" unset
if git config --local --get pager.diff >/dev/null; then fail "local unset"; fi
git config --local pager.diff less
if "$binary" setup --local >/dev/null 2>&1; then fail "replaced another pager"; fi
if "$binary" unset --local >/dev/null 2>&1; then fail "removed another pager"; fi
[ "$(git config --local --get pager.diff)" = less ] || fail "changed another pager"

cd "$scratch"
"$binary" setup --user
[ "$(git config --global --get pager.diff)" = lantana ] || fail "user setup"
"$binary" unset --user
if git config --global --get pager.diff >/dev/null; then fail "user unset"; fi

git init -q "$scratch/project"
mkdir "$scratch/project/nested"
cd "$scratch/project/nested"
# The shareable preference belongs at the repository root even from a subdirectory.
"$binary" setup --project
cd ..
[ "$(git config --local --get pager.diff)" = lantana ] || fail "project clone config"
[ "$(git config --file .lantana.gitconfig --get pager.diff)" = lantana ] || fail "project preference"
git add .lantana.gitconfig
git -c user.name=Lantana -c user.email=lantana@example.com commit -qm "Record project pager"
git clone -q "$scratch/project" "$scratch/clone"
cd "$scratch/clone"
if git config --local --get pager.diff >/dev/null; then fail "clone inherited local config"; fi
"$binary" setup --project
[ "$(git config --local --get pager.diff)" = lantana ] || fail "clone setup"
"$binary" unset --project
if git config --local --get pager.diff >/dev/null; then fail "clone unset"; fi
[ ! -e .lantana.gitconfig ] || fail "clone project file remains"

cd "$scratch/project"
git config --file .lantana.gitconfig core.abbrev 12
"$binary" unset --project
if git config --local --get pager.diff >/dev/null; then fail "project unset"; fi
if git config --file .lantana.gitconfig --get pager.diff >/dev/null; then fail "project preference remains"; fi
[ "$(git config --file .lantana.gitconfig --get core.abbrev)" = 12 ] || fail "removed another project setting"

echo PASS
