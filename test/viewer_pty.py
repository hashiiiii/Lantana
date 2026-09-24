#!/usr/bin/env python3
"""Inspect live terminal frames while driving a real Git diff pager."""

import fcntl
import os
import pty
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata
from pathlib import Path


def git(repo, *args):
    return subprocess.check_output(["git", *args], cwd=repo)


class Screen:
    # A transcript can contain stale file names after navigation; assertions use live cells.
    def __init__(self, width=80, height=24):
        self.resize(width, height)
        self.pending = bytearray()
        self.frame = 0
        self.alt = False

    def resize(self, width, height):
        self.width, self.height = width, height
        self.cells = [[" "] * width for _ in range(height)]
        self.row = self.col = 0

    def text(self):
        return "\n".join("".join(row) for row in self.cells)

    def feed(self, data):
        self.pending.extend(data)
        index = 0
        while index < len(self.pending):
            byte = self.pending[index]
            if byte == 27:
                if index + 1 >= len(self.pending):
                    break
                next_byte = self.pending[index + 1]
                if next_byte == ord("["):
                    end = index + 2
                    while end < len(self.pending) and not 0x40 <= self.pending[end] <= 0x7E:
                        end += 1
                    if end >= len(self.pending):
                        break
                    self.csi(bytes(self.pending[index + 2 : end]), chr(self.pending[end]))
                    index = end + 1
                    continue
                if next_byte in (ord("]"), ord("P"), ord("_"), ord("^"), ord("G")):
                    end = index + 2
                    while end < len(self.pending):
                        if self.pending[end] == 7:
                            end += 1
                            break
                        if self.pending[end : end + 2] == b"\x1b\\":
                            end += 2
                            break
                        end += 1
                    if end >= len(self.pending):
                        break
                    index = end
                    continue
                index += 2
                continue
            if byte == 13:
                self.col = 0
                index += 1
                continue
            if byte == 10:
                self.row = min(self.height - 1, self.row + 1)
                index += 1
                continue
            if byte < 32 or byte == 127:
                index += 1
                continue
            size = 1
            if byte >= 0xF0:
                size = 4
            elif byte >= 0xE0:
                size = 3
            elif byte >= 0xC0:
                size = 2
            if index + size > len(self.pending):
                break
            try:
                character = bytes(self.pending[index : index + size]).decode("utf-8")
            except UnicodeDecodeError:
                character = "?"
                size = 1
            if self.row < self.height and self.col < self.width:
                self.cells[self.row][self.col] = character
            self.col += 2 if unicodedata.east_asian_width(character) in "WF" else 1
            index += size
        del self.pending[:index]

    def csi(self, raw, final):
        parameter = raw.decode("ascii", "ignore")
        if parameter == "?1049" and final == "h":
            self.alt = True
            self.resize(self.width, self.height)
            return
        if parameter == "?1049" and final == "l":
            self.alt = False
            return
        if parameter == "?2026" and final == "l":
            self.frame += 1
            return
        if parameter.startswith("?") or parameter.startswith(">"):
            return
        values = [int(part) if part.isdigit() else 0 for part in parameter.split(";")]
        first = values[0] if values else 0
        if final in "Hf":
            self.row = max(0, min(self.height - 1, (first or 1) - 1))
            self.col = max(0, min(self.width - 1, ((values[1] if len(values) > 1 else 1) or 1) - 1))
        elif final == "J":
            if first == 2:
                self.resize(self.width, self.height)
            elif first == 0:
                for row in range(self.row, self.height):
                    start = self.col if row == self.row else 0
                    self.cells[row][start:] = [" "] * (self.width - start)
        elif final == "K":
            self.cells[self.row][self.col :] = [" "] * (self.width - self.col)


class Session:
    def __init__(self, repo):
        self.master, self.slave = pty.openpty()
        self.screen = Screen()
        self.transcript = bytearray()
        self.replies = {b"\x1b[6n": 0, b"\x1b[?u": 0, b"\x1b[5n": 0}
        self.resize(80, 24)
        self.child = os.fork()
        if self.child == 0:
            os.close(self.master)
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
            for fd in (0, 1, 2):
                os.dup2(self.slave, fd)
            if self.slave > 2:
                os.close(self.slave)
            os.chdir(repo)
            env = os.environ.copy()
            env.pop("GIT_PAGER", None)
            env.pop("PAGER", None)
            env["TERM"] = "xterm-256color"
            command = (
                # Git must restore the terminal mode before the shell exits.
                'before=$(stty -g); git --paginate diff --unified=100; code=$?; '
                'after=$(stty -g); [ "$before" = "$after" ] || exit 94; exit "$code"'
            )
            os.execvpe("sh", ["sh", "-c", command], env)

    def resize(self, width, height):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        self.screen.resize(width, height)

    def pump(self):
        readable, _, _ = select.select([self.master], [], [], 0.1)
        if not readable:
            return
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return
        self.transcript.extend(chunk)
        self.screen.feed(chunk)
        responses = {
            b"\x1b[6n": b"\x1b[1;1R",
            b"\x1b[?u": b"\x1b[?0u\x1b[?1;2c",
            b"\x1b[5n": b"\x1b[0n",
        }
        for query, answer in responses.items():
            count = self.transcript.count(query)
            while self.replies[query] < count:
                os.write(self.master, answer)
                self.replies[query] += 1

    def wait_frame(self, expected, after=-1):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            self.pump()
            if self.screen.frame > after and expected in self.screen.text():
                return self.screen.text()
        raise AssertionError(f"missing {expected!r}; frame={self.screen.frame}; screen=\n{self.screen.text()}\noutput={self.transcript[-500:]!r}")

    def send(self, keys):
        frame = self.screen.frame
        os.write(self.master, keys)
        return frame

    def finish(self):
        os.write(self.master, b"q")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            self.pump()
            done, status = os.waitpid(self.child, os.WNOHANG)
            if done:
                assert os.waitstatus_to_exitcode(status) == 0, self.transcript[-500:]
                assert b"\x1b[?1049l" in self.transcript
                os.close(self.master)
                os.close(self.slave)
                return
        os.kill(self.child, 9)
        os.waitpid(self.child, 0)
        raise AssertionError("viewer did not quit")


def main():
    executable = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="lantana-viewer-") as directory:
        repo = Path(directory)
        git(repo, "init", "-q")
        git(repo, "config", "user.name", "Lantana Test")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "color.ui", "false")
        git(repo, "config", "core.pager", shlex.quote(str(executable)) + " --demo-document")
        git(repo, "config", "pager.diff", "true")
        (repo / "Assets").mkdir()
        (repo / "Scripts").mkdir()
        (repo / "Assets/A.prefab").write_text("\n".join(f"value {n}" for n in range(30)) + "\n")
        (repo / "Assets/B.meta").write_text("guid: before\n")
        (repo / "Scripts/C.cs").write_text("class C { int value = 1; }\n")
        (repo / "Image.png").write_bytes(b"\x89PNG\x00before")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "initial")
        (repo / "Assets/A.prefab").write_text("\n".join(f"value {n} after" for n in range(30)) + "\n")
        (repo / "Assets/B.meta").write_text("guid: after\n")
        (repo / "Scripts/C.cs").write_text("class C { int value = 2; }\n")
        (repo / "Image.png").write_bytes(b"\x89PNG\x00after")
        status_before = git(repo, "status", "--porcelain=v1")
        config_before = (repo / ".git/config").read_bytes()
        session = Session(repo)
        frame = session.wait_frame("Document for Assets/A.prefab")
        assert "Before (-)" not in frame
        assert "Assets" in frame and "Scripts" in frame
        session.wait_frame("Before (-)", session.send(b"m"))
        before_pan = session.wait_frame("y:2", session.send(b"jj"))
        after_pan = session.wait_frame("x:2", session.send(b"ll"))
        # The body must change too; an offset label alone does not prove horizontal panning.
        assert before_pan.splitlines()[3:] != after_pan.splitlines()[3:]
        session.wait_frame("Assets/B.meta", session.send(b"\x1b[B"))
        assert "No document for this file" in session.screen.text()
        session.wait_frame("Image.png", session.send(b"c"))
        assert "Binary files" in session.screen.text()
        session.wait_frame("Scripts/C.cs", session.send(b"\x1b[B"))
        session.wait_frame("A.prefab", session.send(b"\x1b[<0;8;3M\x1b[<0;8;3m"))
        session.wait_frame("Assets/B.meta", session.send(b"\x1b[<0;8;5M\x1b[<0;8;5m"))
        session.resize(48, 16)
        session.wait_frame("Assets/B.meta", session.screen.frame)
        session.resize(20, 6)
        session.wait_frame("Terminal too small", session.screen.frame)
        session.resize(80, 24)
        session.wait_frame("Assets/B.meta", session.screen.frame)
        session.finish()
        assert git(repo, "status", "--porcelain=v1") == status_before
        assert (repo / ".git/config").read_bytes() == config_before


if __name__ == "__main__":
    main()
