#!/usr/bin/env python3
"""`tools/self-revert-gate`, watched failing against the thing it claims.

Two halves, and both are required by AGENTS.md for different reasons.

THE REPLAY. `fe4d8179` is the commit this gate exists for -- it reverted
its own predecessor's CDEF-attribution work in a message about
`hello.machine` -- and the last case here puts that exact commit through
the gate and requires it to be named, along with the predecessor. A gate
argued from a synthetic fixture has never met the defect it was built for.

THE MUTATIONS. Every threshold in the gate gets a case that moves ONLY
that threshold and requires the verdict to flip. This arc has already
been bitten by the alternative: two render guards passed the exact
mutation they were written for, having been verified against a different
one. So "a smaller revert is under the floor" and "saying so silences it"
are not comments here, they are cases, and each one is built by editing
one number in an otherwise-identical fixture.
"""

import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "self-revert-gate"

# The commit that cost this arc a merge, and its immediate predecessor.
INCIDENT = "fe4d8179567d1ef35b6f89dfe3fa2a8e81bf7a5a"
PREDECESSOR = "9c219366a09971137f6e87878491b4c0b71a2921"


def load():
    spec = importlib.util.spec_from_loader(
        "self_revert_gate",
        importlib.machinery.SourceFileLoader("self_revert_gate", str(TOOL)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def have(rev):
    """Is this object in THIS clone? The replay needs the real history.

    A contributor whose clone does not carry the arc's lane branches is
    not failing this gate, so the replay reports SKIP loudly rather than
    failing -- and loudly is the point: a gate that quietly declines to
    run is how `scripts/test-mirrorkit` came to be missing from
    `test-all` for three days.
    """
    return subprocess.run(["git", "cat-file", "-e", rev + "^{commit}"],
                          cwd=ROOT, capture_output=True).returncode == 0


LINE = "    the %s line of the measurement, which is long enough to count"


class Fixture:
    """A throwaway repository with one lane's history in it.

    Built rather than mocked, because every threshold in the gate is
    derived from git itself -- commit times, first-parent ancestry, the
    exact bytes of a diff -- and a fake that reproduced all of that would
    be the gate written twice.
    """

    def __init__(self, tmp):
        self.dir = tmp
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "gate@test")
        self.git("config", "user.name", "gate")
        self.clock = 1754500000

    def git(self, *args):
        return subprocess.run(["git"] + list(args), cwd=self.dir,
                              check=True, capture_output=True,
                              text=True).stdout

    def commit(self, message, files, minutes=1):
        self.clock += minutes * 60
        for name, body in files.items():
            (Path(self.dir) / name).write_text(body)
            self.git("add", name)
        when = "%d +0000" % self.clock
        env = dict(os.environ, GIT_AUTHOR_DATE=when, GIT_COMMITTER_DATE=when)
        subprocess.run(["git", "commit", "-q", "-m", message],
                       cwd=self.dir, check=True, capture_output=True,
                       env=env)
        return self.git("rev-parse", "HEAD").strip()


def lane(tmp, added=20, removed=18, gap_minutes=7,
         message="feat(other): something else entirely"):
    """A -> B on one branch: A adds `added` lines, B removes `removed`.

    Every case below is this function with one argument changed, which is
    what makes them mutations of each other rather than six unrelated
    fixtures.
    """
    f = Fixture(tmp)
    f.commit("chore: the file before anything", {"table.c": "int base;\n"})
    body = "int base;\n" + "".join((LINE % i) + "\n" for i in range(added))
    a = f.commit("feat: the measurement, pinned", {"table.c": body}, 1)
    kept = "int base;\n" + "".join(
        (LINE % i) + "\n" for i in range(removed, added))
    b = f.commit(message, {"table.c": kept}, gap_minutes)
    return f, a, b


class SelfRevertGate(unittest.TestCase):

    def setUp(self):
        self.mod = load()

    def flagged(self, root, commit):
        self.mod._CHANGED.clear()
        self.mod._EPOCH.clear()
        return self.mod.findings(commit, root)

    # ------------------------------------------------------------------
    # The shape that shipped.

    def test_a_commit_that_undoes_its_predecessor_is_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            f, a, b = lane(tmp)
            found = self.flagged(f.dir, b)
            self.assertEqual(len(found), 1,
                             "the revert of the predecessor was not flagged")
            self.assertEqual(found[0]["ancestor"], a)
            self.assertEqual(found[0]["lines"], 18)
            self.assertEqual(found[0]["of"], 20)
            self.assertAlmostEqual(found[0]["gap_minutes"], 7, places=3)
            self.assertIn("table.c", found[0]["files"])

    # ------------------------------------------------------------------
    # One mutation per threshold. Each moves ONE number.

    def test_saying_so_silences_it(self):
        """The condition that makes refusal fair. It has to be live, or the
        gate is asking for work rather than for a truthful message."""
        with tempfile.TemporaryDirectory() as tmp:
            f, a, b = lane(tmp, message="feat(other): reverts the measurement")
            self.assertEqual(self.flagged(f.dir, b), [])

    def test_naming_the_hash_silences_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            f, a, _ = lane(tmp)
            # Rebuild B with A's short hash in the body, nothing else moved.
            f.git("reset", "-q", "--hard", "HEAD~1")
            kept = "int base;\n" + "".join(
                (LINE % i) + "\n" for i in range(18, 20))
            b = f.commit("feat(other): something else entirely\n\n"
                         "This drops what %s pinned.\n" % a[:8],
                         {"table.c": kept}, 7)
            self.assertEqual(self.flagged(f.dir, b), [])

    def test_a_small_removal_is_under_the_floor(self):
        """12 lines is the floor and this is 8. Stated as a case because it
        is the gate's largest blind spot: a real but small revert."""
        with tempfile.TemporaryDirectory() as tmp:
            f, _, b = lane(tmp, added=20, removed=8)
            self.assertEqual(self.flagged(f.dir, b), [])
        with tempfile.TemporaryDirectory() as tmp:
            f, _, b = lane(tmp, added=20, removed=12)
            self.assertEqual(len(self.flagged(f.dir, b)), 1,
                             "exactly at the floor must still flag")

    def test_touching_part_of_a_predecessor_is_not_undoing_it(self):
        """18 of 100 is an edit. 18 of 20 is a revert. The fraction is what
        separates a lane reworking its own approach from one erasing it."""
        with tempfile.TemporaryDirectory() as tmp:
            f, _, b = lane(tmp, added=100, removed=18)
            self.assertEqual(self.flagged(f.dir, b), [])

    def test_a_predecessor_from_last_week_is_not_adjacent(self):
        with tempfile.TemporaryDirectory() as tmp:
            f, _, b = lane(tmp, gap_minutes=60 * 48)
            self.assertEqual(self.flagged(f.dir, b), [])

    def test_boilerplate_lines_do_not_count_as_a_revert(self):
        """A closing brace appears in every diff in the repository. If those
        counted, any two commits touching one file would look like a revert
        of each other, and this gate would be a coin toss."""
        with tempfile.TemporaryDirectory() as tmp:
            f = Fixture(tmp)
            f.commit("chore: base", {"t.c": "int x;\n"})
            # Forty DISTINCT lines, none of them substantial -- well past
            # both thresholds, so nothing but `substantial()` can be what
            # keeps this quiet. (An earlier version of this case used the
            # same four braces repeated, which deduplicates to four lines
            # and was caught by the FLOOR instead: it passed with
            # `substantial` mutated to accept everything, which is the
            # exact failure mode this arc keeps paying for -- a case
            # verified against a different mutation than the one it names.)
            noise = "int x;\n" + "".join("  %d,\n" % i for i in range(40))
            f.commit("feat: a table of bare numbers", {"t.c": noise})
            b = f.commit("feat: unrelated", {"t.c": "int x;\n"})
            self.assertEqual(self.flagged(f.dir, b), [])

    def test_a_merge_is_not_this_gate_s_business(self):
        """Cross-branch loss at a merge is merge-census-gate's half. This
        one must stay silent on a merge commit, or every integration in the
        fleet goes red for work it did not do."""
        with tempfile.TemporaryDirectory() as tmp:
            f, a, b = lane(tmp)
            f.git("checkout", "-q", "-b", "side", a)
            f.commit("feat(side): elsewhere", {"other.c": "int y;\n"})
            f.git("checkout", "-q", "main" if f.git(
                "branch", "--list", "main").strip() else "master")
            f.git("merge", "-q", "--no-ff", "-m", "Merge side", "side")
            merge = f.git("rev-parse", "HEAD").strip()
            self.assertEqual(self.flagged(f.dir, merge), [])

    # ------------------------------------------------------------------
    # The replay: the real commit, out of this repository's own history.

    def test_the_incident_is_named(self):
        if not (have(INCIDENT) and have(PREDECESSOR)):
            print("\nSKIP: %s is not in this clone, so the REPLAY did not "
                  "run.\n      Only the synthetic mutations above covered "
                  "this gate." % INCIDENT[:8])
            return
        found = self.flagged(str(ROOT), INCIDENT)
        ancestors = {f["ancestor"] for f in found}
        self.assertIn(PREDECESSOR, ancestors,
                      "the gate did not name the commit fe4d8179 reverted")
        hit = [f for f in found if f["ancestor"] == PREDECESSOR][0]
        self.assertEqual(hit["lines"], hit["of"],
                         "fe4d8179 removed every line 9c219366 added")
        self.assertIn("docs/open-issues.md", hit["files"])
        self.assertIn("now-guest-ppc/tests/scene_json_test.c", hit["files"])

    def test_the_incident_would_go_quiet_if_it_had_said_so(self):
        """The other half of the replay, and the one that proves the gate is
        not simply flagging every large diff: the SAME commit, with one
        sentence added to its message, passes."""
        if not have(INCIDENT):
            print("\nSKIP: the incident is not in this clone.")
            return
        message = subprocess.run(
            ["git", "log", "-1", "--format=%B", INCIDENT],
            cwd=ROOT, check=True, capture_output=True, text=True).stdout
        self.assertFalse(self.mod.mentions(message, PREDECESSOR),
                         "fe4d8179's real message must NOT mention it")
        self.assertTrue(
            self.mod.mentions(message + "\nThis reverts 9c219366.\n",
                              PREDECESSOR),
            "one honest sentence has to be enough to satisfy this gate")


if __name__ == "__main__":
    unittest.main(verbosity=2)
