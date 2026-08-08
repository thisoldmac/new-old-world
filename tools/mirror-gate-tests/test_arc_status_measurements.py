#!/usr/bin/env python3
"""`tools/arc-status` reports arc state, and it was wrong about arc state.

On 2026-08-07 it printed *"nothing graduated to the corpus in 21h —
durable lessons are evaporating"* while 26 findings sat on
`claude/018-findings` across 7 commits. The findings were written. The
tool read the parent's WORKING DIRECTORY, which sits on `main`, so it
measured a checkout rather than the work — a real worry with a wrong
shape, and the same class of defect as an instrument that cannot see the
thing it exists to photograph.

Its own header says its output is evidence and your recollection is not.
That only holds if the evidence is sound, which is why this exists: the
tool that measures everything else had nothing measuring it.

Every case below drives the REAL script against a synthetic repository
built here, rather than reading its source. A source check would have
passed on the day the bug shipped.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARC_STATUS = ROOT / "tools" / "arc-status"


def git(repo, *args, when=None):
    env = dict(os.environ)
    env.update({
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
    })
    if when:
        env["GIT_AUTHOR_DATE"] = when
        env["GIT_COMMITTER_DATE"] = when
    return subprocess.run(["git", "-C", str(repo), *args], env=env,
                          check=True, capture_output=True, text=True).stdout


def commit(repo, path, text, message, when=None):
    p = Path(repo) / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)
    git(repo, "add", "--", str(path))
    git(repo, "commit", "-q", "-m", message, when=when)


class ArcStatusMeasurementTests(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.repo = base / "arc"
        self.corpus_repo = base / "corpus"
        self._build_arc()
        self._build_corpus()
        self.addCleanup(self._tmp.cleanup)

    # ---- fixtures ---------------------------------------------------

    def _build_arc(self):
        r = self.repo
        r.mkdir()
        git(r, "init", "-q", "-b", "main")
        commit(r, "docs/seed.md", "seed\n", "seed")

        git(r, "checkout", "-q", "-b", "claude/019-integration-1")
        commit(r, "docs/int.md", "int\n", "integration base")

        # A lane cut from the integration branch: two commits of its own.
        git(r, "checkout", "-q", "-b", "claude/019-alpha")
        commit(r, "docs/a1.md", "a1\n", "alpha one")
        commit(r, "docs/a2.md", "a2\n", "alpha two")

        # A lane cut from ANOTHER LANE. One commit of its own, and three
        # since it forked from the integration branch.
        git(r, "checkout", "-q", "-b", "claude/019-beta")
        commit(r, "docs/b1.md", "b1\n", "beta one")

        # Work in a namespace the lane glob does not match.
        git(r, "checkout", "-q", "-b", "codex/somewhere-else",
            "claude/019-integration-1")
        commit(r, "docs/c1.md", "c1\n", "codex one")

        git(r, "checkout", "-q", "claude/019-integration-1")

    def _build_corpus(self):
        c = self.corpus_repo
        c.mkdir()
        git(c, "init", "-q", "-b", "main")
        # OLD on the trunk. Old enough that a tool measuring the checkout
        # would report the corpus as abandoned.
        commit(c, "data/findings/one.md", "1\n", "findings: one",
               when="2026-01-01T00:00:00Z")
        commit(c, "data/findings/two.md", "2\n", "findings: two",
               when="2026-01-01T00:00:00Z")

        git(c, "checkout", "-q", "-b", "claude/018-findings")
        for i, name in enumerate(["three", "four", "five"]):
            commit(c, f"data/findings/{name}.md", f"{i}\n",
                   f"findings: {name}")
        git(c, "checkout", "-q", "main")

        # The working tree is now main's — two old files. This is exactly
        # the state the old implementation measured, and the state in
        # which it was wrong.
        old = (Path(c) / "data" / "findings")
        for f in old.glob("*.md"):
            os.utime(f, (0, 0))

    def run_arc_status(self):
        env = dict(os.environ)
        env["TBT_CORPUS"] = str(self.corpus_repo / "data" / "findings")
        r = subprocess.run(["bash", str(ARC_STATUS)], cwd=str(self.repo),
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0,
                         f"arc-status exited {r.returncode}\n{r.stderr}")
        return r.stdout

    # ---- the corpus, measured across refs ---------------------------

    def test_findings_on_a_branch_are_not_reported_as_never_written(self):
        """THE BUG. Three findings are committed on a branch and the
        checkout shows two ancient files. The old implementation read the
        checkout and announced that nothing had graduated in months."""
        out = self.run_arc_status()
        self.assertNotIn("evaporating", out,
                         "findings were written hours ago, on a branch")
        self.assertIn("findings: five", out,
                      "the newest corpus commit is the branch's, and "
                      "naming it is how a reader checks")

    def test_written_and_landed_are_reported_as_different_states(self):
        """They want different repairs. A tool that collapses them keeps
        telling somebody to write what they have already written."""
        out = self.run_arc_status()
        self.assertIn("2 finding(s) on main", out)
        self.assertIn("3 finding(s) written and NOT on main, "
                      "across 1 branch(es)", out)
        self.assertIn("3 unique to claude/018-findings, 3 not on main "
                      "(3 commit(s))", out)

    # ---- the unlanded total is a SET, not a sum -----------------------
    #
    # Round 8 recorded that the commits half of this script had learned
    # not to double-count across branches sharing history and the
    # findings half had not. On 2026-08-07 that cost a landing: 57
    # findings went onto `main`, `main` moved 216 -> 273, and this line
    # went on reporting "87 across 35" — unchanged, still naming the
    # branch whose 26 had just landed. The true remainder was 15.

    def _fork(self, parent, name, files):
        """A corpus branch cut from `parent`, adding one commit per file."""
        git(self.corpus_repo, "checkout", "-q", "-b", name, parent)
        for f in files:
            commit(self.corpus_repo, f"data/findings/{f}.md", f"{f}\n",
                   f"findings: {f}")
        git(self.corpus_repo, "checkout", "-q", "main")

    def test_a_finding_on_two_branches_is_counted_once(self):
        """A child lane carries its parent's findings. Summing
        `--diff-filter=A` per branch counted them once per branch, so the
        arc's backlog grew every time somebody cut a worktree."""
        self._fork("main", "claude/x", ["shared"])
        self._fork("claude/x", "claude/y", ["why"])
        out = self.run_arc_status()
        # three/four/five on 018, plus shared and why. Five files, not
        # the six a per-branch sum produces by counting `shared` twice.
        self.assertIn("5 finding(s) written and NOT on main, "
                      "across 3 branch(es)", out)

    def test_a_finding_that_has_landed_stops_being_counted(self):
        """The expensive half. `--diff-filter=A $trunk...$cb` measures
        against the branch's own merge base, so a finding copied onto the
        trunk — which is exactly how the landing lane lands them — still
        reads as an addition on every branch that ever held it. The
        number then cannot move no matter how much work lands, and it is
        wrong in the direction that makes a reader redo the landing."""
        commit(self.corpus_repo, "data/findings/three.md", "0\n",
               "corpus: land three")
        out = self.run_arc_status()
        self.assertIn("3 finding(s) on main", out)
        self.assertIn("2 finding(s) written and NOT on main, "
                      "across 1 branch(es)", out)

    def test_the_directory_readme_is_not_a_finding(self):
        """`tools/data check` reports 273 where the `.md` count is 274.
        A tool whose number cannot be reconciled with the corpus's own
        gate is a second number for a reader to distrust."""
        commit(self.corpus_repo, "data/findings/README.md", "how to\n",
               "findings: readme")
        self._fork("main", "claude/x", ["shared"])
        out = self.run_arc_status()
        self.assertIn("2 finding(s) on main", out)
        self.assertIn("4 finding(s) written and NOT on main", out)

    def test_the_branch_column_is_what_deleting_it_would_lose(self):
        """The only question a per-branch breakdown answers. `claude/x`
        holds one unlanded finding and `claude/y` also holds it, so
        deleting `claude/x` loses nothing and it must not be listed;
        `claude/y` alone holds `why`."""
        self._fork("main", "claude/x", ["shared"])
        self._fork("claude/x", "claude/y", ["why"])
        out = self.run_arc_status()
        knowledge = out.split("=== KNOWLEDGE")[1]
        self.assertIn("1 unique to claude/y, 2 not on main", knowledge)
        self.assertNotIn("claude/x", knowledge,
                         "nothing is lost by deleting it; listing it "
                         "sends somebody to rescue a duplicate")

    def test_a_stale_corpus_still_earns_the_warning(self):
        """The warning is kept, not softened: the worry is legitimate and
        this arc has genuinely let findings sit. With nothing recent on
        ANY ref it must still fire."""
        git(self.corpus_repo, "branch", "-q", "-D", "claude/018-findings")
        out = self.run_arc_status()
        self.assertIn("evaporating", out)
        self.assertIn("nothing WRITTEN to the corpus in", out)

    def test_a_corpus_outside_a_repository_says_so(self):
        """Silence would read as "nothing unlanded", which is the same
        false comfort in a different costume."""
        with tempfile.TemporaryDirectory() as loose:
            findings = Path(loose) / "findings"
            findings.mkdir()
            (findings / "x.md").write_text("x\n")
            env = dict(os.environ)
            env["TBT_CORPUS"] = str(findings)
            out = subprocess.run(["bash", str(ARC_STATUS)],
                                 cwd=str(self.repo), env=env,
                                 capture_output=True, text=True).stdout
        self.assertIn("not in a git repository", out)

    # ---- the lane table ---------------------------------------------

    def test_a_lane_says_how_much_of_its_count_is_another_lanes_work(self):
        """`merge-base $b $INT` is the fork point from the INTEGRATION
        branch, so a lane cut from another lane inherits its count. On
        2026-08-07 a branch with one commit on it read as seventeen, and
        the arc's unlanded total counted those seventeen twice.

        Symmetric on purpose — see `shared_with`. Deriving a DIRECTION
        was tried twice and answers backwards whenever the parent lane's
        tip has moved past the fork point, which is the normal state of
        a lane somebody is still working in."""
        out = self.run_arc_status()
        self.assertIn("3 commits (2 shared with 019-alpha)", out)
        self.assertIn("2 commits (2 shared with 019-beta)", out)

    def test_shared_commits_are_counted_once_in_the_arc_total(self):
        """Alpha's two and beta's one are three distinct commits, not
        five. The summed version fired the merge trigger early on work
        that did not exist."""
        out = self.run_arc_status()
        total = subprocess.run(
            ["git", "-C", str(self.repo), "rev-list", "--count",
             "claude/019-alpha", "claude/019-beta", "--not",
             "claude/019-integration-1"],
            capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(total, "3", "the fixture itself")

    def test_branches_outside_the_lane_glob_are_counted_rather_than_hidden(self):
        """The heading says "work that exists". It enumerates one naming
        convention, and a true sentence about a smaller set than the
        reader thinks is the same defect as measuring the wrong tree."""
        out = self.run_arc_status()
        self.assertIn("1 unlanded branch(es) outside that glob", out)
        self.assertNotIn("codex/somewhere-else", out.split("=== CONFLICTS")[0]
                         .split("outside that glob")[0],
                         "it is counted, not listed as a lane")

    # ---- the state it was once killed by ----------------------------

    def test_it_survives_an_idle_machine_and_an_empty_arc(self):
        """It died once under `set -e` when `pgrep` matched nothing —
        the state you are in when you run it to find out what to do
        next. Every section must print on the quietest possible repo."""
        out = self.run_arc_status()
        for section in ["=== LANDED", "=== NOT LANDED", "=== CONFLICTS",
                        "=== MAIN", "=== MACHINE", "=== KNOWLEDGE",
                        "=== GATE FRESHNESS"]:
            self.assertIn(section, out, f"{section} never printed")


if __name__ == "__main__":
    unittest.main()
