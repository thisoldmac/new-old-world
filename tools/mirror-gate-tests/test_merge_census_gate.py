#!/usr/bin/env python3
"""`tools/merge-census-gate`, watched failing against the losses it claims.

The gate's whole subject is a merge that reports NOTHING, so every case
here is built by making a merge lose something and requiring the verdict
to change. A merge commit's tree is amended after the merge rather than
mocked, because the gate reads real trees and real parents and a fake of
that would be the gate written twice.

Three verdicts, and each has both a case that trips it and a neighbouring
case that must not:

  DROPPED       a definition neither side removed and the merge lacks --
                the keep-both truncation shape. Refuses.
  IMPORTED
  SELF-REVERT   a commit the merge brings in that undoes its own
                predecessor silently. Refuses. This is the half that
                catches `fe4d8179`, and the replay at the foot of this
                file runs the real one.
  REMOVED BY
  A SIDE        a deletion one parent actually made. Reported, never
                refused -- and the case for it asserts the exit code is
                ZERO, because a gate that refuses honest deletions is a
                gate somebody turns off within the day.
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
TOOL = ROOT / "tools" / "merge-census-gate"

INT_SIDE = "b64a15049502c61e336a5481f1b050d0fe59b149"
LANE_SIDE = "0bbf6f7db41fbb8a82f5a0e750c1b9e53d18e66f"
INCIDENT = "fe4d8179567d1ef35b6f89dfe3fa2a8e81bf7a5a"
SCENE = "mirror/host/MirrorKit/Sources/MirrorKit/Scene.swift"


def load():
    spec = importlib.util.spec_from_loader(
        "merge_census_gate",
        importlib.machinery.SourceFileLoader("merge_census_gate", str(TOOL)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def have(rev):
    return subprocess.run(["git", "cat-file", "-e", rev + "^{commit}"],
                          cwd=ROOT, capture_output=True).returncode == 0


def fn(name):
    return "void %s(void)\n{\n    do_the_thing();\n}\n\n" % name


class Repo:
    def __init__(self, tmp):
        self.dir = tmp
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "gate@test")
        self.git("config", "user.name", "gate")

    def git(self, *args):
        return subprocess.run(["git"] + list(args), cwd=self.dir, check=True,
                              capture_output=True, text=True).stdout

    def write(self, name, text):
        (Path(self.dir) / name).write_text(text)
        self.git("add", name)

    def commit(self, message):
        subprocess.run(["git", "commit", "-q", "-m", message], cwd=self.dir,
                       check=True, capture_output=True)
        return self.git("rev-parse", "HEAD").strip()


def three_way(tmp, x_funcs, y_funcs, base_funcs=("alpha", "beta", "omega")):
    """base -> X and base -> Y, merged. Returns (repo, merge sha).

    X and Y each write their own file so the merge itself never conflicts:
    the hazard under test is a CLEAN merge that loses code, and a fixture
    that conflicted would be testing the other thing.
    """
    r = Repo(tmp)
    r.write("shared.c", "".join(fn(f) for f in base_funcs))
    r.commit("chore: the base")
    r.git("checkout", "-q", "-b", "x")
    r.write("x.c", "".join(fn(f) for f in x_funcs))
    r.write("shared.c", "".join(fn(f) for f in base_funcs))
    r.commit("feat(x): the x side")
    r.git("checkout", "-q", "main")
    r.git("checkout", "-q", "-b", "y")
    r.write("y.c", "".join(fn(f) for f in y_funcs))
    r.commit("feat(y): the y side")
    r.git("checkout", "-q", "x")
    r.git("merge", "-q", "--no-ff", "-m", "Merge branch 'y' into x", "y")
    return r, r.git("rev-parse", "HEAD").strip()


def amend_tree(r, edits):
    """Rewrite files in the merge's tree, keeping both parents.

    `git commit --amend` preserves parentage, which is the only property
    that matters: the fixture has to be a real merge commit or the gate
    will decline to look at it.
    """
    for name, text in edits.items():
        r.write(name, text)
    subprocess.run(["git", "commit", "-q", "--amend", "--no-edit"],
                   cwd=r.dir, check=True, capture_output=True)
    return r.git("rev-parse", "HEAD").strip()


def check(mod, root, commit):
    """The gate's own verdict, with its output captured."""
    import io
    import contextlib
    buf = io.StringIO()
    cwd = os.getcwd()
    os.chdir(root)
    try:
        with contextlib.redirect_stdout(buf):
            rc = mod.cmd_check([commit])
    finally:
        os.chdir(cwd)
    return rc, buf.getvalue()


class Census(unittest.TestCase):
    """The unit the whole gate is built on. If this reads a name wrong,
    every verdict above it is wrong in the same direction and silently."""

    def setUp(self):
        self.mod = load()

    def names(self, path, text):
        return {n for _, n in self.mod.symbols_in(path, text)}

    def test_c(self):
        text = ("#define WIDE 4\n"
                "typedef struct NowThing NowThing;\n"
                "static const char *now_cdef_role(short id)\n{\n"
                "    if (id == 0) return helper(id);\n"
                "    while (more(id)) { }\n"
                "}\n")
        self.assertEqual(
            self.names("a.c", text),
            {"WIDE", "NowThing", "now_cdef_role"},
            "an indented call or a `while` must not read as a definition")

    def test_swift(self):
        text = ("// a func namedInComment must not count\n"
                "struct Scene {\n"
                "    public let cdef: Int?\n"
                "    func decode() {\n"
                "        if let x = maybe { }\n"
                "    }\n"
                "}\n")
        self.assertEqual(self.names("a.swift", text),
                         {"Scene", "cdef", "decode"})

    def test_python_and_markdown(self):
        self.assertEqual(self.names("a.py", "class K:\n    def go(self):\n"),
                         {"K", "go"})
        self.assertEqual(
            self.names("a.md", "# Title\n```\n## not a heading\n```\n## Real\n"),
            {"Title", "Real"},
            "a heading inside a fence is code, not structure")


class MergeCensusGate(unittest.TestCase):

    def setUp(self):
        self.mod = load()

    # ------------------------------------------------------------------

    def test_a_clean_merge_that_keeps_everything_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            r, m = three_way(tmp, ["gamma"], ["delta"])
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 0, out)
            self.assertIn("0 dropped", out)

    def test_a_definition_nobody_removed_and_the_merge_lacks_refuses(self):
        """The keep-both truncation: `omega` is in the base and in BOTH
        parents, and the resolution loses it anyway because the shared
        trailing context sits outside the hunk. Six duplicate Python defs
        and a gutted docs entry are the two this repository has paid for."""
        with tempfile.TemporaryDirectory() as tmp:
            r, _ = three_way(tmp, ["gamma"], ["delta"])
            m = amend_tree(r, {"shared.c": fn("alpha") + fn("beta")})
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 1, out)
            self.assertIn("omega", out)
            self.assertIn("DROPPED", out)

    def test_an_addition_the_merge_swallowed_refuses(self):
        """`gamma` exists only on X and only after the base, so nobody
        removed it. A merge that arrives without it dropped it."""
        with tempfile.TemporaryDirectory() as tmp:
            r, _ = three_way(tmp, ["gamma"], ["delta"])
            m = amend_tree(r, {"x.c": fn("something_else")})
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 1, out)
            self.assertIn("gamma", out)

    def test_a_deletion_a_side_actually_made_is_reported_not_refused(self):
        """The case that decides whether anyone leaves this gate on. Y
        removes `beta`; the merge honouring that is correct, and a gate
        that refused it would be refusing every honest deletion in the
        fleet. It must be LISTED and must exit 0."""
        with tempfile.TemporaryDirectory() as tmp:
            r = Repo(tmp)
            r.write("shared.c", fn("alpha") + fn("beta"))
            r.commit("chore: the base")
            r.git("checkout", "-q", "-b", "x")
            r.write("x.c", fn("gamma"))
            r.commit("feat(x): the x side")
            r.git("checkout", "-q", "main")
            r.git("checkout", "-q", "-b", "y")
            r.write("shared.c", fn("alpha"))
            r.commit("cleanup(y): beta had no callers left")
            r.git("checkout", "-q", "x")
            r.git("merge", "-q", "--no-ff", "-m", "Merge branch 'y'", "y")
            m = r.git("rev-parse", "HEAD").strip()
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 0, out)
            self.assertIn("beta", out)
            self.assertIn("removed by a side", out)
            self.assertIn("cleanup(y)", out,
                          "a bare list of names is not usable; the removal "
                          "has to be attributed to the commit that made it")

    def test_a_merge_that_imports_a_silent_self_revert_refuses(self):
        """The `fe4d8179` shape, synthesised: the lane's second commit
        undoes its first in a message about something else, and the merge
        is clean. Nothing in the census sees it -- the name never moves --
        so this half is the sibling gate asked directly about every commit
        the merge brings in."""
        with tempfile.TemporaryDirectory() as tmp:
            r = Repo(tmp)
            r.write("shared.c", fn("alpha"))
            r.commit("chore: the base")
            r.git("checkout", "-q", "-b", "y")
            body = fn("alpha") + "".join(
                "/* the %d th line of a real measurement, long enough */\n" % i
                for i in range(30))
            r.write("shared.c", body)
            r.commit("fix(y): the measurement, recorded")
            r.write("shared.c", fn("alpha"))
            r.commit("feat(y): an unrelated field on the hello frame")
            r.git("checkout", "-q", "main")
            r.write("x.c", fn("gamma"))
            r.commit("feat(x): the x side")
            r.git("merge", "-q", "--no-ff", "-m", "Merge branch 'y'", "y")
            m = r.git("rev-parse", "HEAD").strip()
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 1, out)
            self.assertIn("IMPORTED SELF-REVERT", out)
            self.assertIn("an unrelated field on the hello frame", out)

    def test_history_already_on_the_first_parent_is_not_re_refused(self):
        """Same fixture, merged the other way round: the self-revert is on
        the line being merged INTO, so it is not something this merge
        imports. Refusing it here would make every later merge in an arc
        red for a commit nobody on this merge can change, which is how a
        gate gets switched off rather than obeyed."""
        with tempfile.TemporaryDirectory() as tmp:
            r = Repo(tmp)
            r.write("shared.c", fn("alpha"))
            r.commit("chore: the base")
            r.git("checkout", "-q", "-b", "y")
            body = fn("alpha") + "".join(
                "/* the %d th line of a real measurement, long enough */\n" % i
                for i in range(30))
            r.write("shared.c", body)
            r.commit("fix(y): the measurement, recorded")
            r.write("shared.c", fn("alpha"))
            r.commit("feat(y): an unrelated field on the hello frame")
            r.git("checkout", "-q", "main")
            r.write("x.c", fn("gamma"))
            r.commit("feat(x): the x side")
            r.git("checkout", "-q", "y")
            r.git("merge", "-q", "--no-ff", "-m", "Merge branch 'main'",
                  "main")
            m = r.git("rev-parse", "HEAD").strip()
            rc, out = check(self.mod, r.dir, m)
            self.assertEqual(rc, 0, out)

    # ------------------------------------------------------------------
    # The replay, against the merge that actually happened.

    def test_the_real_auto_merge_of_the_incident(self):
        """Reconstruct what git would have produced for round 7's merge of
        `claude/019-asset-packs` and require the gate to name the loss.

        `git merge-tree --write-tree` is exactly the resolution git would
        have committed, so this is not a model of the incident, it is the
        incident. Two things are asserted, because they are the two halves
        of the gate: the census loses `Scene.swift`'s `cdef`, and the
        imported-commit scan names `fe4d8179`.
        """
        if not (have(INT_SIDE) and have(LANE_SIDE) and have(INCIDENT)):
            print("\nSKIP: round 7's branches are not in this clone, so the "
                  "REPLAY did not run.\n      Only the synthetic cases above "
                  "covered this gate.")
            return

        merged = subprocess.run(
            ["git", "merge-tree", "--write-tree", INT_SIDE, LANE_SIDE],
            cwd=ROOT, capture_output=True, text=True)
        tree = merged.stdout.split("\n")[0].strip()
        self.assertTrue(tree, "merge-tree produced no tree")

        _, _, lost, _ = self.mod.compare(INT_SIDE, tree, str(ROOT))
        self.assertIn((SCENE, "prop", "cdef"), lost,
                      "the auto-merge dropped Scene.swift's `cdef` and the "
                      "census did not see it")

        base = subprocess.run(["git", "merge-base", INT_SIDE, LANE_SIDE],
                              cwd=ROOT, check=True, capture_output=True,
                              text=True).stdout.strip()
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            suspects = self.mod.self_revert_suspects(
                [INT_SIDE, LANE_SIDE], base, str(ROOT))
        self.assertIn(INCIDENT, suspects,
                      "the imported-commit scan did not name fe4d8179")
        self.assertIn("hello says which Macintosh", buf.getvalue())

    def test_the_merge_that_actually_landed_passes(self):
        """The other end of the replay, and the case that decides whether
        this gate is usable at all.

        Round 7 read `fe4d8179`, resolved all seven files by hand, and NAMED
        the commit in the merge body. `fe4d8179` is still in that merge's
        history -- content resolved away is not history removed -- so a gate
        that keyed only on ancestry would refuse the correct merge, and go
        on refusing every later merge of that lane forever. It passes
        because the merge said what it was carrying, which is the same
        escape the sibling gate offers a commit.
        """
        if not have("4b3ece40"):
            print("\nSKIP: the landed merge is not in this clone.")
            return
        parents = subprocess.run(
            ["git", "rev-list", "-1", "--parents", "4b3ece40"], cwd=ROOT,
            check=True, capture_output=True, text=True).stdout.split()[1:]
        base = subprocess.run(["git", "merge-base"] + parents, cwd=ROOT,
                              check=True, capture_output=True,
                              text=True).stdout.strip()
        message = subprocess.run(
            ["git", "log", "-1", "--format=%B", "4b3ece40"], cwd=ROOT,
            check=True, capture_output=True, text=True).stdout
        import io
        import contextlib
        with contextlib.redirect_stdout(io.StringIO()):
            with_message = self.mod.self_revert_suspects(
                parents, base, str(ROOT), message)
            without = self.mod.self_revert_suspects(parents, base, str(ROOT))
        self.assertNotIn(INCIDENT, with_message,
                         "the landed merge names fe4d8179 and must pass")
        self.assertIn(INCIDENT, without,
                      "and it is the MESSAGE doing that, not ancestry -- "
                      "the same merge with a bare subject is refused")


if __name__ == "__main__":
    unittest.main(verbosity=2)
