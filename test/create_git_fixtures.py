#!/usr/bin/env python3
"""Regenerate parser fixtures with real Git patches."""

import subprocess
import tempfile
from pathlib import Path


FIXTURES = Path(__file__).parent / "fixtures"


def git(repo, *args):
    return subprocess.check_output(["git", *args], cwd=repo)


def write(repo, name, contents):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents)


def repository(root, name):
    repo = root / name
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.name", "Lantana Test")
    git(repo, "config", "user.email", "test@example.invalid")
    git(repo, "config", "core.quotePath", "true")
    git(repo, "config", "color.ui", "false")
    return repo


def commit_initial(repo):
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "initial")


def save(repo, name, *options):
    git(repo, "add", "-A")
    (FIXTURES / name).write_bytes(git(repo, "diff", "--cached", *options))


def main():
    FIXTURES.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lantana-fixtures-") as directory:
        root = Path(directory)

        ordinary = repository(root, "ordinary")
        write(ordinary, "Assets/A.prefab", b"name: Before\ncount: 1\n")
        write(ordinary, "Scripts/A.cs", b"class A {}\n")
        commit_initial(ordinary)
        write(ordinary, "Assets/A.prefab", b"name: After\ncount: 1\n")
        write(ordinary, "Scripts/A.cs", b"class A {\n  // diff --git a/fake b/fake\n}\n")
        save(ordinary, "ordinary.patch")

        kinds = repository(root, "kinds")
        write(kinds, "Assets/Delete.prefab", b"deleted\n")
        write(kinds, "Assets/Rename.prefab", b"same content\n")
        write(kinds, "Assets/Mode.cs", b"mode only\n")
        write(kinds, "Image.png", b"\x89PNG\x00before")
        commit_initial(kinds)
        (kinds / "Assets/Delete.prefab").unlink()
        (kinds / "Assets/Rename.prefab").rename(kinds / "Assets/Renamed.prefab")
        (kinds / "Assets/Mode.cs").chmod(0o755)
        write(kinds, "Assets/New.meta", b"guid: abc\n")
        write(kinds, "Image.png", b"\x89PNG\x00after")
        save(kinds, "kinds.patch", "--find-renames")

        paths = repository(root, "paths")
        for name in ("space name.cs", 'quote"tab\t.cs', "日本語.prefab"):
            write(paths, name, b"before\n")
        write(paths, "dir b/Mode.cs", b"mode only\n")
        commit_initial(paths)
        for name in ("space name.cs", 'quote"tab\t.cs', "日本語.prefab"):
            write(paths, name, b"after\n")
        (paths / "dir b/Mode.cs").chmod(0o755)
        save(paths, "paths.patch")

        rename = repository(root, "mixed-rename")
        write(rename, "日本語.cs", b"same content\n")
        commit_initial(rename)
        (rename / "日本語.cs").rename(rename / "Plain.cs")
        save(rename, "mixed_rename.patch", "--find-renames")

        reverse = repository(root, "mixed-rename-reverse")
        write(reverse, "Plain.cs", b"same content\n")
        commit_initial(reverse)
        (reverse / "Plain.cs").rename(reverse / "日本語.cs")
        save(reverse, "mixed_rename_reverse.patch", "--find-renames")

        ambiguous = repository(root, "ambiguous-rename")
        write(ambiguous, "dir b/Old.cs", b"same content\n")
        commit_initial(ambiguous)
        (ambiguous / "dir b/Old.cs").rename(ambiguous / "New.cs")
        save(ambiguous, "ambiguous_rename.patch", "--find-renames")

        metadata = repository(root, "metadata-hunk")
        write(metadata, "Actual.cs", b"-- a/wrong-old.cs\n")
        commit_initial(metadata)
        write(metadata, "Actual.cs", b"++ b/wrong-new.cs\n")
        save(metadata, "metadata_hunk.patch")

        hunks = repository(root, "hunks")
        write(hunks, "Script.cs", b"zero\none\ntwo\n\nfour\nfive\nsix\nseven\neight\nnine")
        commit_initial(hunks)
        write(hunks, "Script.cs", b"zero\nONE\nextra\ntwo\n\nfour\nfive\nsix\nseven\neight\nNINE")
        save(hunks, "hunks.patch", "--unified=2")

        (FIXTURES / "colored.patch").write_bytes(
            git(ordinary, "-c", "color.ui=always", "diff", "--cached", "--color=always")
        )


if __name__ == "__main__":
    main()
