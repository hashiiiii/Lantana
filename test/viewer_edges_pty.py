#!/usr/bin/env python3
"""Exercise display and navigation edge cases with Git and a real PTY."""

import shlex
import sys
import tempfile
import unittest
from pathlib import Path

from viewer_pty import Session, git


EXECUTABLE = Path(sys.argv.pop(1)).resolve()


class EdgeCases(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="lantana-edge-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Lantana Test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        git(self.repo, "config", "color.ui", "false")
        git(self.repo, "config", "core.pager", shlex.quote(str(EXECUTABLE)))
        git(self.repo, "config", "pager.diff", "true")

    def changed(self, name, before, after):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(before)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "initial")
        path.write_bytes(after)

    def start(self):
        self.status_before = git(self.repo, "status", "--porcelain=v1")
        self.config_before = (self.repo / ".git/config").read_bytes()
        session = Session(self.repo)
        self.addCleanup(session.abort)
        return session

    def finish(self, session):
        session.finish()
        self.assertEqual(self.status_before, git(self.repo, "status", "--porcelain=v1"))
        self.assertEqual(self.config_before, (self.repo / ".git/config").read_bytes())

    def test_invalid_utf8_keeps_terminal_restorable(self):
        self.changed("A.cs", b"before\n", b"\xff\xcc\x81\n")
        session = self.start()
        frame = session.wait_frame("Before (-)")
        # The replacement character must reach the screen without crashing grapheme layout.
        self.assertIn("�", frame)
        self.finish(session)

    def test_nonempty_line_without_final_newline_is_marked(self):
        self.changed("A.cs", b"end", b"end\n")
        session = self.start()
        frame = session.wait_frame("Before (-)")
        self.assertIn("end [no newline]", frame)
        self.finish(session)

    def test_tab_indentation_survives_horizontal_panning(self):
        self.changed("A.cs", b"\tbefore()\n", b"\tafter()\n")
        session = self.start()
        frame = session.wait_frame("Before (-)")
        # An explicit tab marker distinguishes a tab from source spaces.
        self.assertIn("→   after()", frame)
        panned = session.wait_frame("x:1", session.send(b"l"))
        self.assertIn("   after()", panned)
        self.finish(session)

    def test_collapsed_only_folder_reopens_with_keyboard(self):
        self.changed("Assets/A.cs", b"before\n", b"after\n")
        session = self.start()
        session.wait_frame("Before (-)")
        session.wait_frame("No changed files", session.send(b"c"))
        frame = session.wait_frame("Before (-)", session.send(b"c"))
        self.assertIn("A.cs", frame)
        self.finish(session)

    def test_mouse_wheel_can_hide_the_selected_tree_file(self):
        for number in range(30):
            (self.repo / f"{number:02}.cs").write_text("before\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "initial")
        for number in range(30):
            (self.repo / f"{number:02}.cs").write_text("after\n")
        session = self.start()
        session.wait_frame("Before (-)")
        frame = session.screen.frame
        for _ in range(15):
            session.send(b"\x1b[<65;8;5M")
        visible = session.wait_frame("29.cs", frame)
        tree = "\n".join(line[:28] for line in visible.splitlines())
        self.assertNotIn("00.cs", tree)
        self.finish(session)


if __name__ == "__main__":
    unittest.main()
