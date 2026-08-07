#!/usr/bin/env python3
"""A worktree must not read "SKIPPED (no toolchain)" on a machine that has one.

`.env.lab` describes one desk and is gitignored, so a fresh worktree
starts without it and `scripts/build-guests` skipped — exit 0, six
SKIPPED lines, and `scripts/test-all` green having invoked no
cross-compiler at all. That is a gate declining to run, which AGENTS.md
treats as a first-class defect, and it bit a lane on 2026-08-06: told to
copy the file, it copied it into its own worktree, where it dies with the
worktree, and only after the gate had already read ok once.

A worktree is not a fresh clone. It is the same desk and the same Retro68
install, so the MAIN WORKTREE's `.env.lab` is used rather than pointed at.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build-guests"


class BuildGuestsEnvTests(unittest.TestCase):

    def setUp(self):
        # /private/tmp rather than $TMPDIR: nothing here needs a short
        # path, but a git worktree under /var/folders confuses nothing
        # and this keeps the failure output readable.
        self.work = tempfile.mkdtemp(prefix="bgenv-", dir="/private/tmp")
        self.addCleanup(shutil.rmtree, self.work, ignore_errors=True)
        self.main = os.path.join(self.work, "main")
        os.makedirs(os.path.join(self.main, "scripts"))
        shutil.copy(SCRIPT, os.path.join(self.main, "scripts", "build-guests"))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        self.git("add", "-A")
        self.git("commit", "-qm", "scaffold")
        self.tree = os.path.join(self.work, "wt")
        self.git("worktree", "add", "-q", "--detach", self.tree, "HEAD")

    def git(self, *args):
        subprocess.run(["git", "-C", self.main, *args], check=True,
                       capture_output=True)

    def write_env(self, where, marker):
        # Toolchain paths that do not exist, so every guest SKIPs and no
        # cross-compiler is invoked. What is under test is which file was
        # SOURCED, and the marker is how the run says so.
        with open(os.path.join(where, ".env.lab"), "w", encoding="utf-8") as f:
            f.write(f"RETRO68_TOOLCHAIN_MARKER={marker}\n"
                    "RETRO68_PPC_TOOLCHAIN=/nonexistent/ppc.cmake\n")

    def run_in(self, tree):
        out = subprocess.run([os.path.join(tree, "scripts", "build-guests")],
                             capture_output=True, text=True, cwd=tree,
                             timeout=120)
        return out.stdout + out.stderr

    def test_a_worktree_uses_the_main_worktrees_env_lab(self):
        self.write_env(self.main, "from-main")
        text = self.run_in(self.tree)
        self.assertIn(".env.lab from the main worktree", text)
        self.assertIn(os.path.join(self.main, ".env.lab"), text)
        self.assertNotIn("no .env.lab", text)

    def test_a_worktrees_own_env_lab_still_wins(self):
        """A lane deliberately pointing at a different toolchain must not
        be quietly overridden by the desk's default."""
        self.write_env(self.main, "from-main")
        self.write_env(self.tree, "from-worktree")
        text = self.run_in(self.tree)
        self.assertNotIn("from the main worktree", text)

    def test_with_no_env_lab_anywhere_the_skip_says_so_plainly(self):
        text = self.run_in(self.tree)
        self.assertIn("no .env.lab", text)
        self.assertIn("main worktree", text,
                      "the message must name where to put it, or the next "
                      "lane copies it into its own worktree again")


if __name__ == "__main__":
    unittest.main(verbosity=2)
