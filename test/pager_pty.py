#!/usr/bin/env python3
"""Exercise Git's pager pipe and the controlling terminal together."""

import fcntl
import os
import pty
import re
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


def git(repo, *args):
    return subprocess.check_output(["git", *args], cwd=repo)


def run_pager(repo, expected):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    child = os.fork()
    if child == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave, fd)
        if slave > 2:
            os.close(slave)
        os.chdir(repo)
        env = os.environ.copy()
        env.pop("GIT_PAGER", None)
        env.pop("PAGER", None)
        env["TERM"] = "xterm-256color"
        command = (
            'before=$(stty -g); git --paginate diff; code=$?; '
            'after=$(stty -g); [ "$before" = "$after" ] || exit 94; exit "$code"'
        )
        os.execvpe("sh", ["sh", "-c", command], env)

    transcript = bytearray()
    sent_quit = False
    status = None
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    transcript.extend(chunk)
                    # The terminal query is part of libvaxis initialization.
                    if b"\x1b[6n" in chunk:
                        os.write(master, b"\x1b[1;1R")
                    if b"\x1b[?u" in chunk:
                        os.write(master, b"\x1b[?0u\x1b[?1;2c")
                    if b"\x1b[5n" in chunk:
                        os.write(master, b"\x1b[0n")
                    visible = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", transcript)
                    if expected.replace(b" ", b"") in visible and not sent_quit:
                        os.write(master, b"q")
                        sent_quit = True
            done, result = os.waitpid(child, os.WNOHANG)
            if done:
                status = result
                break
        if status is None:
            os.kill(child, 9)
            _, status = os.waitpid(child, 0)
            raise AssertionError(f"pager timed out; output={transcript[-1000:]!r}")
        assert os.waitstatus_to_exitcode(status) == 0, transcript[-1000:]
        assert sent_quit, transcript[-1000:]
        assert b"\x1b[?1049h" in transcript, "viewer did not enter alternate screen"
        assert b"\x1b[?1049l" in transcript, "viewer did not leave alternate screen"
    finally:
        os.close(master)
        os.close(slave)


def main():
    executable = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="lantana-pty-") as directory:
        repo = Path(directory)
        git(repo, "init", "-q")
        git(repo, "config", "user.name", "Lantana Test")
        git(repo, "config", "user.email", "test@example.invalid")
        (repo / "Example.cs").write_text("before\n")
        git(repo, "add", "Example.cs")
        git(repo, "commit", "-qm", "initial")
        (repo / "Example.cs").write_text("after\n")
        git(repo, "config", "core.pager", shlex.quote(str(executable)))
        git(repo, "config", "pager.diff", "true")
        git(repo, "config", "color.ui", "false")
        patch = git(repo, "--no-pager", "diff")
        status_before = git(repo, "status", "--porcelain=v1")
        config_before = (repo / ".git" / "config").read_bytes()
        run_pager(repo, f"PATCH BYTES: {len(patch)}".encode())
        assert git(repo, "status", "--porcelain=v1") == status_before
        assert (repo / ".git" / "config").read_bytes() == config_before
        assert (repo / "Example.cs").read_text() == "after\n"


if __name__ == "__main__":
    main()
