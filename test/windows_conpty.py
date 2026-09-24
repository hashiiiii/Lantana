#!/usr/bin/env python3
"""Prove Git's pager pipe and console input work through native ConPTY."""

import os
import re
import select
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from winpty import Backend, PtyProcess


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
QUERIES = {
    "\x1b[6n": "\x1b[1;1R",
    "\x1b[5n": "\x1b[0n",
    "\x1b[?u": "\x1b[?0u\x1b[?1;2c",
}


def git(repo, *args):
    return subprocess.check_output(["git", *args], cwd=repo)


def run_pager(repo):
    environment = os.environ.copy()
    environment.pop("GIT_PAGER", None)
    environment.pop("PAGER", None)
    environment["TERM"] = "xterm-256color"

    # pywinpty treats integer zero as an absent backend, so the string forces ConPTY.
    process = PtyProcess.spawn(
        ["git", "--paginate", "diff"],
        cwd=str(repo),
        env=environment,
        dimensions=(24, 80),
        backend=str(Backend.ConPTY),
    )
    transcript = ""
    responses = {query: 0 for query in QUERIES}
    sent_quit = False
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([process.fileobj], [], [], 0.1)
            if readable:
                try:
                    transcript += process.read(65536)
                except EOFError:
                    break
                for query, reply in QUERIES.items():
                    count = transcript.count(query)
                    while responses[query] < count:
                        process.write(reply)
                        responses[query] += 1
                visible = ANSI.sub("", transcript)
                # The screen header proves Git has fed the patch before the key is sent.
                if "Before (-)" in visible and "Example.cs" in visible and not sent_quit:
                    process.write("q")
                    sent_quit = True
            if not process.isalive() and "\x1b[?1049l" in transcript:
                break
        else:
            raise AssertionError(f"ConPTY pager timed out: {transcript[-1200:]!r}")
        assert sent_quit, transcript[-1200:]
        assert process.wait() == 0, transcript[-1200:]
        assert "before" in transcript and "after" in transcript
        assert "\x1b[?1049h" in transcript, "viewer did not enter alternate screen"
        assert "\x1b[?1049l" in transcript, "viewer did not leave alternate screen"
    finally:
        process.close(force=True)


def main():
    executable = Path(sys.argv[1]).resolve()
    assert executable.is_file(), executable
    assert Backend.ConPTY == 0
    with tempfile.TemporaryDirectory(prefix="lantana-conpty-") as directory:
        repo = Path(directory)
        git(repo, "init", "-q")
        git(repo, "config", "user.name", "Lantana Test")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "commit.gpgsign", "false")
        (repo / "Example.cs").write_text("before\n", encoding="utf-8")
        git(repo, "add", "Example.cs")
        git(repo, "commit", "-qm", "initial")
        (repo / "Example.cs").write_text("after\n", encoding="utf-8")
        git(repo, "config", "core.pager", shlex.quote(executable.as_posix()))
        git(repo, "config", "pager.diff", "true")
        git(repo, "config", "color.ui", "false")
        patch = git(repo, "--no-pager", "diff")
        assert patch
        status_before = git(repo, "status", "--porcelain=v1")
        config_before = (repo / ".git" / "config").read_bytes()
        run_pager(repo)
        assert git(repo, "status", "--porcelain=v1") == status_before
        assert (repo / ".git" / "config").read_bytes() == config_before
        assert (repo / "Example.cs").read_text(encoding="utf-8") == "after\n"
        empty = subprocess.run([str(executable)], input=b"", capture_output=True, timeout=5)
        assert empty.returncode == 0 and empty.stdout == b""


if __name__ == "__main__":
    main()
