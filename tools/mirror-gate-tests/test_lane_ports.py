#!/usr/bin/env python3
"""The lane port scheme: deterministic, collision-free, and additive.

Every case here is one of the three failures of 2026-08-06, or one of the
constraints that let the scheme land while a dozen lanes were mid-flight
on hand-assigned ports.

The registry is redirected to a temporary directory for every test
(`NOW_LANE_REGISTRY`), because a gate that writes into the real one would
claim blocks for lanes that do not exist and then be the staleness it is
supposed to prevent.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "lane-ports"
SPIN = ROOT / "scripts" / "spin-up-ppc"


def code_of(function: str) -> str:
    """One function's CODE, with its prose removed.

    Read through `ast` rather than by slicing the text, because the first
    version of the guard below matched the word `kill` in the very
    docstring explaining that reclaim never kills anything — a guard
    failing on its own explanation. Comments do not survive the parse and
    the docstring is dropped explicitly; string literals stay, since a
    forbidden call spelled inside one would still run.
    """
    import ast
    tree = ast.parse(TOOL.read_text())
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == function:
            body = node.body
            if (body and isinstance(body[0], ast.Expr)
                    and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)):
                body = body[1:]
            return "\n".join(ast.unparse(stmt) for stmt in body)
    raise AssertionError(f"tools/lane-ports has no {function}()")


def load_module():
    """Import `tools/lane-ports` despite its having no .py suffix."""
    spec = importlib.util.spec_from_loader(
        "lane_ports",
        importlib.machinery.SourceFileLoader("lane_ports", str(TOOL)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.registry = tempfile.mkdtemp(prefix="lane-ports-test-")
        self.addCleanup(shutil.rmtree, self.registry, ignore_errors=True)
        self.env = dict(os.environ, NOW_LANE_REGISTRY=self.registry)

    def run_tool(self, *args, cwd=None, check=True):
        out = subprocess.run([sys.executable, str(TOOL), *args],
                             capture_output=True, text=True,
                             env=self.env, cwd=cwd or str(ROOT), timeout=90)
        if check:
            self.assertEqual(out.returncode, 0,
                             f"{args}\n{out.stdout}\n{out.stderr}")
        return out

    def show(self, cwd=None):
        return json.loads(self.run_tool("show", "--json", cwd=cwd).stdout)


class DerivationTests(Sandbox):
    """No coordinator: the same lane gets the same answer, always."""

    def test_the_same_lane_gets_the_same_block_every_time(self):
        first, second = self.show(), self.show()
        self.assertEqual(first["block"], second["block"])
        self.assertEqual(first["ports"], second["ports"])

    def test_a_wiped_registry_does_not_move_a_lane(self):
        """The property a pure registry does not have, and the reason the
        scheme is a hash FIRST and a claim file second. /private/tmp is
        swept by macOS; a lane that moved when that happened would be a
        lane whose in-flight VM it could no longer find."""
        before = self.show()
        for entry in os.listdir(self.registry):
            os.unlink(os.path.join(self.registry, entry))
        self.assertEqual(self.show()["block"], before["block"])

    def test_two_different_lanes_get_different_blocks(self):
        module = load_module()
        a = module.preferred_block("/w/lane-a")
        b = module.preferred_block("/w/lane-b")
        self.assertNotEqual(a, b)

    def test_the_derivation_is_a_pinned_function_of_the_path_alone(self):
        """Golden vectors, and they are the guard that has teeth.

        `test_a_wiped_registry_does_not_move_a_lane` was watched PASSING
        against a `preferred_block` mutated to fold in `int(time.time())`
        — because it asks the same question twice inside one second. A
        derivation that drifts with anything but the path loses a lane
        its running VM, so it is pinned to constants computed once,
        here, rather than to agreement between two adjacent calls.
        """
        module = load_module()
        for root, block in (("/w/lane-a", 370),
                            ("/w/lane-b", 266),
                            ("/Users/michelle/Lab/Code/timbottu/now", 37)):
            self.assertEqual(module.preferred_block(root), block,
                             f"the derivation for {root} moved; every lane "
                             "with a VM up has just lost track of it")

    def test_a_collision_is_stepped_past_rather_than_shared(self):
        """A hash alone collides — 1000 blocks and fifteen lanes is a
        ~10% chance of a pair landing together, and 'usually collision
        free' is what the hand-assigned scheme already was. So a taken
        block is probed past, deterministically.

        The collision is FORCED, not hoped for. A first version of this
        claimed two roots and checked they differed, which they did for
        the ordinary reason — it passed against an `allocate` mutated to
        hand out a claimed block, because the two roots never landed on
        the same one to begin with.

        The lane roots have to EXIST, too, and the strengthened version
        found that out the hard way: a claim naming a directory that is
        not there is an orphan by definition, and `allocate` correctly
        took it over. Two made-up paths test the orphan path, not the
        collision path.
        """
        module = load_module()
        module.REGISTRY = self.registry
        module.preferred_block = lambda root: 5     # everybody wants block 5
        one = os.path.realpath(tempfile.mkdtemp(prefix="lane-one-"))
        two = os.path.realpath(tempfile.mkdtemp(prefix="lane-two-"))
        self.addCleanup(shutil.rmtree, one, ignore_errors=True)
        self.addCleanup(shutil.rmtree, two, ignore_errors=True)
        first = module.allocate(one)
        second = module.allocate(two)
        self.assertEqual(first["block"], 5)
        self.assertNotEqual(second["block"], 5,
                            "two lanes were handed the same block")
        self.assertEqual(module.read_claim(5)["laneRoot"], one)
        self.assertEqual(module.read_claim(second["block"])["laneRoot"], two)
        # And the displaced lane is stable too: it keeps where it landed.
        self.assertEqual(module.allocate(two)["block"], second["block"])

    def test_a_lane_gets_eight_ports_and_they_are_contiguous(self):
        lane = self.show()
        ports = sorted(lane["ports"].values())
        self.assertEqual(len(ports), 8)
        self.assertEqual(ports, list(range(ports[0], ports[0] + 8)))
        self.assertEqual(lane["ports"]["wire"], lane["ports"]["anchor"] + 1)


class RegionTests(Sandbox):
    """Where the region sits is the constraint that let this land while a
    dozen lanes were already running."""

    def test_the_region_avoids_every_port_this_project_spells_by_hand(self):
        module = load_module()
        by_hand = ({1400}                      # the guest anchor worker
                   | set(range(1700, 1900))    # the hand-assigned hostfwds
                   | set(range(5250, 5254)))   # product wire + metal harnesses
        low, high = module.BASE, module.BASE + module.BLOCKS * module.STRIDE
        self.assertTrue(all(port < low or port >= high for port in by_hand),
                        "the derived region overlaps a hand-assigned port, so "
                        "adopting it could walk into a lane already in flight")

    def test_the_region_avoids_the_ports_this_suite_draws_from_itself(self):
        """`HostAppStateTestSupport.testListenPort` draws 20000-40000
        keyed on the pid, and macOS draws ephemeral ports from
        49152-65535. A lane range inside either would be taken from the
        lane by its own test process."""
        module = load_module()
        high = module.BASE + module.BLOCKS * module.STRIDE
        self.assertLessEqual(high, 20000)
        self.assertGreaterEqual(module.BASE, 1024)


class AttributionTests(Sandbox):
    """The fact that was missing: whose port is this?"""

    def test_whose_names_the_owning_lane_for_a_port_in_the_region(self):
        mine = self.show()
        answer = json.loads(
            self.run_tool("whose", "--port", str(mine["ports"]["wire"]),
                          "--json").stdout)
        self.assertTrue(answer["isMine"])
        self.assertEqual(answer["owner"]["laneRoot"], mine["laneRoot"])

    def test_whose_says_plainly_that_a_hand_assigned_port_has_no_owner(self):
        """1840 is the exact port that held up a lane on 2026-08-06. The
        honest answer for it is still 'nobody can tell you' — the value
        of the scheme is that ports allocated THROUGH it never have that
        answer, not that it can retrofit one."""
        answer = json.loads(
            self.run_tool("whose", "--port", "1840", "--json").stdout)
        self.assertFalse(answer["inRegion"])
        self.assertIsNone(answer["owner"])

    def test_a_neighbouring_lanes_port_is_reported_as_not_mine(self):
        module = load_module()
        module.REGISTRY = self.registry
        mine = self.show()
        neighbour = (mine["block"] + 1) % module.BLOCKS
        module.write_claim(neighbour, {
            "laneRoot": "/w/somebody-else", "branch": "claude/other",
            "qmpSockets": [], "runDirs": []})
        port = module.ports_of(neighbour)["wire"]
        answer = json.loads(
            self.run_tool("whose", "--port", str(port), "--json").stdout)
        self.assertFalse(answer["isMine"])
        self.assertEqual(answer["owner"]["laneRoot"], "/w/somebody-else")


class OrphanTests(Sandbox):
    """A range whose owner died must come back without a human deciding."""

    def test_a_claim_whose_worktree_is_gone_and_is_idle_is_an_orphan(self):
        module = load_module()
        module.REGISTRY = self.registry
        module.write_claim(11, {"laneRoot": "/w/deleted-worktree",
                                "branch": "gone", "qmpSockets": [],
                                "runDirs": []})
        self.assertEqual(module.liveness(11, module.read_claim(11))["state"],
                         "orphan")

    def test_gc_reaps_orphans_and_their_run_directories(self):
        module = load_module()
        module.REGISTRY = self.registry
        run_dir = tempfile.mkdtemp(prefix="lane-ports-run-")
        with open(os.path.join(run_dir, "session.qcow2"), "wb") as handle:
            handle.write(b"\0" * 4096)
        module.write_claim(12, {"laneRoot": "/w/deleted-worktree",
                                "branch": "gone", "qmpSockets": [],
                                "runDirs": [run_dir]})
        self.run_tool("gc")
        self.assertIsNone(module.read_claim(12))
        self.assertFalse(os.path.isdir(run_dir),
                         "an orphan's run directory is the 11 GB that "
                         "outlived its VMs on 2026-08-06")

    def test_gc_leaves_an_idle_lane_alone(self):
        """An idle block is not an orphan. Its worktree is still there, so
        that lane will ask for it again and must get the same one."""
        module = load_module()
        module.REGISTRY = self.registry
        mine = self.show()
        self.run_tool("gc")
        self.assertIsNotNone(module.read_claim(mine["block"]))

    def test_reclaiming_someone_elses_block_is_refused(self):
        module = load_module()
        module.REGISTRY = self.registry
        mine = self.show()
        neighbour = (mine["block"] + 1) % module.BLOCKS
        module.write_claim(neighbour, {"laneRoot": "/w/somebody-else",
                                       "branch": "claude/other",
                                       "qmpSockets": [], "runDirs": []})
        out = self.run_tool("reclaim", "--block", str(neighbour), check=False)
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("belongs to", out.stdout)


class SafetyTests(unittest.TestCase):
    """Two rules the rest of this repository already pays for."""

    def test_reclamation_goes_through_qmp_by_socket_path_never_by_port(self):
        """`lsof -ti tcp:<wire>` matches QEMU itself under user-mode
        networking, so killing what holds a port kills the machine — done
        by accident 2026-08-03. The reclaim path must therefore address a
        VM by its QMP socket and nothing else."""
        body = code_of("reclaim") + code_of("qmp_quit")
        for forbidden in ("kill", "pkill", "lsof", "SIGKILL", "SIGTERM",
                          "terminate()"):
            self.assertNotIn(forbidden, body,
                             f"reclaim reaches for {forbidden!r}; the only "
                             "safe handle on a VM is its QMP socket path")
        self.assertIn("shutdown-guest.py", body)
        self.assertIn("qmp_quit(sock)", body)
        self.assertIn("AF_UNIX", body,
                      "the QMP channel must be the socket path, not a TCP port")

    def test_a_power_cut_is_opt_in_and_says_what_it_costs(self):
        text = TOOL.read_text()
        self.assertIn("--power-cut", text)
        self.assertIn("Disk First Aid", text)


class AdditiveTests(unittest.TestCase):
    """Lanes already in flight on hand-assigned ports must not move."""

    def test_spin_up_reads_the_callers_ports_before_deriving_anything(self):
        """`--env` sets NOW_ANCHOR_PORT and NOW_WIRE_PORT itself, so the
        caller's own values have to be captured first or the derivation
        silently overwrites them — moving a lane that asked for a pair,
        which is the one thing this change must not do."""
        text = SPIN.read_text()
        asked = text.index('ASKED_ANCHOR="${NOW_ANCHOR_PORT:-}"')
        derive = text.index('"$NOW/tools/lane-ports" --lane "$NOW" --env')
        self.assertLess(asked, derive)
        self.assertIn('ANCHOR="${ASKED_ANCHOR:-$LANE_ANCHOR}"', text)
        self.assertIn('WIRE="${ASKED_WIRE:-$LANE_WIRE}"', text)

    def test_spin_up_still_works_with_no_lane_tool_at_all(self):
        """The derivation is guarded by `-x`, and the old defaults remain
        the fallback. A checkout without the tool boots exactly as before."""
        text = SPIN.read_text()
        self.assertIn('LANE_ANCHOR=1700; LANE_WIRE=5250', text)
        self.assertIn('[ -x "$NOW/tools/lane-ports" ]', text)

    def test_spin_up_tells_the_guest_which_port_to_dial(self):
        """The one path that does not go over a port we chose: the guest's
        dialling book is written at stage time from NOW_WIRE_PORT, and
        without it the clone keeps the image's saved 5250 and dials
        whatever host session holds that."""
        text = SPIN.read_text()
        stage = text[text.index("== stage the extension"):
                     text.index('python3 "$NOW/tools/stage-ext.py"')]
        self.assertIn('NOW_WIRE_PORT="$WIRE"', stage)

    def test_spin_up_actually_honours_the_ports_it_is_given(self):
        """The behavioural half, because the three above read text.

        `scripts/spin-up-ppc` is RUN, with a `/bin/echo` standing in for
        QEMU and empty files for the images, until it writes `$RUN/ports`
        — which is the decision under test and happens before anything
        boots. A text assertion about variable order would survive a
        later edit that reintroduced the overwrite somewhere else; this
        does not.

        Skipped by name, not silently, where the lab checkout providing
        `tools/lib.sh` is absent: spin-up-ppc cannot start at all there.
        """
        lab = ROOT
        while lab != lab.parent and not (lab / "tools" / "lib.sh").is_file():
            lab = lab.parent
        if not (lab / "tools" / "lib.sh").is_file():
            raise unittest.SkipTest(
                "no lab checkout above the repo (tools/lib.sh), so "
                "spin-up-ppc cannot run here")

        # /private/tmp, not $TMPDIR: a UNIX socket path is capped at 104
        # bytes and spin-up-ppc refuses (exit 78) a run directory over 80,
        # which /var/folders/... already is before anything is appended.
        work = tempfile.mkdtemp(prefix="lnpt-", dir="/private/tmp")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        for name in ("base.qcow2", "ext.bin", "app.bin", "shut.bin"):
            open(os.path.join(work, name), "wb").close()
        registry = os.path.join(work, "registry")

        def spin(label, **extra):
            run_dir = os.path.join(work, label)
            env = dict(os.environ,
                       NOW_LANE_REGISTRY=registry,
                       NOW_SPIN_RUN=run_dir,
                       TIMBOTTU_QEMU="/bin/echo",
                       NOW_SPIN_BASE=os.path.join(work, "base.qcow2"),
                       NOW_EXT_BIN=os.path.join(work, "ext.bin"),
                       NOW_APP_BIN=os.path.join(work, "app.bin"),
                       NOW_SHUTDOWN_BIN=os.path.join(work, "shut.bin"),
                       **extra)
            child = subprocess.Popen([str(SPIN)], env=env, cwd=str(ROOT),
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
            ports_file = os.path.join(run_dir, "ports")
            try:
                for _ in range(240):
                    if os.path.exists(ports_file):
                        break
                    if child.poll() is not None:
                        break
                    time.sleep(0.25)
            finally:
                child.terminate()
                try:
                    child.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    child.kill()
            self.assertTrue(os.path.exists(ports_file),
                            f"{label}: spin-up-ppc never chose ports")
            with open(ports_file, encoding="utf-8") as handle:
                return [int(field) for field in handle.read().split()]

        derived = spin("derived")
        self.assertTrue(all(12000 <= port < 20000 for port in derived),
                        f"the default is not the derived block: {derived}")

        # A lane mid-flight on the hand-assigned pair that lost a run on
        # 2026-08-06. It must land on exactly those, unmoved.
        self.assertEqual(spin("explicit", NOW_ANCHOR_PORT="1840",
                              NOW_WIRE_PORT="5440"), [1840, 5440])

        # And one half at a time: the other half still derives.
        anchor_only = spin("half", NOW_ANCHOR_PORT="1700")
        self.assertEqual(anchor_only[0], 1700)
        self.assertEqual(anchor_only[1], derived[1])

    def test_the_vm_is_recorded_before_it_boots(self):
        """An orphan nobody recorded cannot be reclaimed. The attach has
        to precede the boot, or a run that dies halfway leaves a machine
        with no handle on it — which is what cost a lane its run."""
        text = SPIN.read_text()
        self.assertLess(text.index('"$NOW/tools/lane-ports" attach'),
                        text.index("boot fresh; wait_anchor"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
