#!/usr/bin/env bash
# Exercise the installed command against real Git configuration files so a
# broken setup command cannot silently replace another pager.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
binary="$repo_root/zig-out/bin/lantana"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) binary="$binary.exe" ;;
esac

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[ -x "$binary" ] || fail "missing lantana executable: $binary"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL="$scratch/global"
export GIT_CONFIG_NOSYSTEM=1
export XDG_CONFIG_HOME="$scratch/xdg"

git init -q "$scratch/repo"
cd "$scratch/repo"

version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$repo_root/build.zig.zon")
[ "$("$binary" --version)" = "lantana $version" ] || fail "version differs from build.zig.zon"
[ -z "$(printf '' | "$binary")" ] || fail "empty input produced output"

"$binary" setup --local
[ "$(git config --local --get pager.diff)" = lantana ] || fail "local setup did not select lantana"
"$binary" setup --local
[ "$(git config --local --get-all pager.diff)" = lantana ] || fail "repeated setup changed local config"
"$binary" unset --local
if git config --local --get pager.diff >/dev/null; then fail "local unset left pager.diff"; fi
"$binary" unset --local

git config --local pager.diff less
if "$binary" setup --local >/dev/null 2>&1; then fail "setup replaced an existing pager"; fi
[ "$(git config --local --get pager.diff)" = less ] || fail "setup changed an existing pager"
if "$binary" unset --local >/dev/null 2>&1; then fail "unset removed another pager"; fi
[ "$(git config --local --get pager.diff)" = less ] || fail "unset changed another pager"

git config --local --unset pager.diff
git config --local --add pager.diff lantana
git config --local --add pager.diff ''
if "$binary" setup --local >/dev/null 2>&1; then fail "setup accepted multiple pager values"; fi
if "$binary" unset --local >/dev/null 2>&1; then fail "unset accepted multiple pager values"; fi
[ "$(git config --local --get-all pager.diff | wc -l | tr -d ' ')" = 2 ] || fail "commands changed multiple pager values"

cd "$scratch"
"$binary" setup --user
[ "$(git config --global --get pager.diff)" = lantana ] || fail "user setup did not select lantana"
"$binary" unset --user
if git config --global --get pager.diff >/dev/null; then fail "global unset left pager.diff"; fi

if "$binary" setup --global >/dev/null 2>&1; then fail "unknown scope was accepted"; fi

git init -q "$scratch/project"
mkdir "$scratch/project/nested"
cd "$scratch/project/nested"
# A command run below the repository root must still create one shareable file at the root.
"$binary" setup --project
cd ..
[ "$(git config --get pager.diff)" = lantana ] || fail "project setup did not select lantana"
[ "$(git config --file .lantana.gitconfig --get pager.diff)" = lantana ] || fail "project config is not shareable"
if git config --local --no-includes --get include.path >/dev/null; then fail "project setup included a tracked config"; fi
"$binary" setup --project
[ "$(git config --local --no-includes --get-all pager.diff | wc -l | tr -d ' ')" = 1 ] || fail "repeated project setup added another pager"
# A clone receives the preference file, then activates the fixed command in its own config.
git add .lantana.gitconfig
git -c user.name=Lantana -c user.email=lantana@example.com commit -qm "Record project pager"
git clone -q "$scratch/project" "$scratch/project-clone"
cd "$scratch/project-clone"
if git config --local --get pager.diff >/dev/null; then fail "clone unexpectedly inherited the pager"; fi
[ "$(git config --file .lantana.gitconfig --get pager.diff)" = lantana ] || fail "clone is missing the project preference"
"$binary" setup --project
[ "$(git config --local --get pager.diff)" = lantana ] || fail "clone did not activate the project preference"
"$binary" unset --project
if git config --local --get pager.diff >/dev/null; then fail "clone project unset left pager.diff"; fi
cd "$scratch/project"
"$binary" unset --project
if git config --get pager.diff >/dev/null; then fail "project unset left pager.diff"; fi
[ ! -e .lantana.gitconfig ] || fail "project unset left the generated config"

git config --local pager.diff less
if "$binary" setup --project >/dev/null 2>&1; then fail "project setup replaced a local pager"; fi
[ ! -e .lantana.gitconfig ] || fail "failed project setup wrote a config"
git config --local --unset pager.diff
git config --file .lantana.gitconfig pager.diff less
if "$binary" setup --project >/dev/null 2>&1; then fail "project setup replaced a shared pager"; fi
[ "$(git config --file .lantana.gitconfig --get pager.diff)" = less ] || fail "project setup changed a shared pager"
git config --file .lantana.gitconfig pager.diff lantana
"$binary" setup --project
git config --file .lantana.gitconfig core.abbrev 12
"$binary" unset --project
if git config --file .lantana.gitconfig --get pager.diff >/dev/null; then fail "project unset left pager.diff"; fi
[ "$(git config --file .lantana.gitconfig --get core.abbrev)" = 12 ] || fail "project unset removed another shared setting"
if git config --get core.abbrev >/dev/null; then fail "project setup applied unrelated tracked config"; fi

echo PASS
