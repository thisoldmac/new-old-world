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
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

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


def find_lab():
    """The lab checkout, by spin-up-ppc's own two routes, or None.

    A worktree under /private/tmp shares no ancestor with the lab, so the
    walk alone answers None there — and that is the lane configuration,
    not an edge case. Ask git for the MAIN clone's .git and walk up from
    that, exactly as the script does.
    """
    def walk_up(start):
        d = Path(start).resolve()
        while True:
            if (d / "tools" / "lib.sh").is_file():
                return d
            if d == d.parent:
                return None
            d = d.parent

    if os.environ.get("NOW_LAB_ROOT"):
        return walk_up(os.environ["NOW_LAB_ROOT"])
    found = walk_up(ROOT)
    if found:
        return found
    try:
        common = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute",
             "--git-common-dir"], capture_output=True, text=True,
            timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return walk_up(Path(common).parent) if common else None


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
                            ("/opt/example/Projects/now", 523)):
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


class HumanRangeTests(Sandbox):
    """The block a lane may never be given.

    On 2026-08-07 Michelle's VM was running on 16728/16729 and the hash
    handed block 591 — exactly those ports — to a lane. Nothing was
    misconfigured: allocation reserved a NAME and the collision happened
    on a SOCKET, and a comment saying "leave 591 alone" is read by every
    agent and enforced by none. So the range is skipped in code, and
    these are the cases that say it still is.
    """

    def roots_hashing_into_the_range(self, module, count=3):
        """Paths whose PREFERRED block is inside the reserved range.

        Searched rather than hardcoded, so the cases keep testing the
        skip if the range constants ever move — a hardcoded path would
        quietly stop landing in the range and the test would pass by
        aiming at nothing.
        """
        found = []
        for i in range(2_000_000):
            root = f"/w/human-probe-{i}"
            if module.is_human_block(module.preferred_block(root)):
                found.append(root)
                if len(found) == count:
                    return found
        raise AssertionError("no path hashes into the reserved range")

    def test_a_lane_whose_hash_lands_in_the_human_range_steps_past_it(self):
        module = load_module()
        for root in self.roots_hashing_into_the_range(module):
            self.assertTrue(module.is_human_block(module.preferred_block(root)))
            block = module.allocate(root)["block"]
            self.assertFalse(
                module.is_human_block(block),
                f"{root} hashes into the reserved range and allocation gave "
                f"it block {block} — a lane has just been handed a person's "
                "ports, which is the 2026-08-07 collision exactly")

    def test_the_skip_is_what_moves_them_and_not_luck(self):
        """The mutation, run as a test rather than watched once.

        With the range made empty the SAME roots land inside 590-599. A
        guard whose removal changes nothing is not a guard, and this is
        the case that would have gone quiet if the skip were deleted.
        """
        module = load_module()
        roots = self.roots_hashing_into_the_range(module)
        first, last = module.HUMAN_BLOCK_FIRST, module.HUMAN_BLOCK_LAST
        try:
            module.HUMAN_BLOCK_FIRST, module.HUMAN_BLOCK_LAST = 99998, 99999
            landed = [module.allocate(r, create=False)["block"] for r in roots]
        finally:
            module.HUMAN_BLOCK_FIRST, module.HUMAN_BLOCK_LAST = first, last
        self.assertTrue(
            all(first <= b <= last for b in landed),
            f"with the reservation inert these roots landed at {landed}, "
            "which is outside the range they hash into — so the passing "
            "case above is not evidence the skip did anything")

    def test_no_lane_can_be_allocated_the_range_however_many_claim(self):
        """Not "usually skipped": the range is absent from the outcome
        space. Every block is claimed by somebody and the reserved ones
        are still nobody's."""
        module = load_module()
        # This is an allocation-space proof, not a live-socket test. Without
        # the stub it launches up to 3,200 `lsof` processes while walking
        # synthetic, deliberately nonexistent lane roots.
        with mock.patch.object(module, "port_holders", return_value=[]):
            blocks = {
                module.allocate(f"/w/crowd-{i}")["block"]
                for i in range(400)
            }
        intruders = sorted(b for b in blocks if module.is_human_block(b))
        self.assertEqual(intruders, [], f"lanes were given {intruders}")

    def test_asking_for_the_human_block_by_number_is_refused_and_says_why(self):
        """`--force` does not open it either. Reclaim stops a machine,
        and the one machine no lane may stop is the person's."""
        module = load_module()
        out = self.run_tool("reclaim", "--block", str(module.HUMAN_BLOCK),
                            "--force", check=False)
        self.assertNotEqual(out.returncode, 0,
                            "reclaim took the human block with --force")
        for phrase in ("RESERVED HUMAN RANGE", "NOW_PREFS_SUFFIX"):
            self.assertIn(phrase, out.stdout,
                          "the refusal must name the range AND say that a "
                          "port block is not isolation; a bare denial "
                          "teaches nothing and invites a workaround")

    def test_whose_names_the_range_rather_than_calling_it_unclaimed(self):
        """The registry cannot answer this one. A person's stack files no
        claim, so "unclaimed" is the literal truth and the wrong answer —
        it reads as an invitation."""
        module = load_module()
        port = module.ports_of(module.HUMAN_BLOCK)["wire"]
        out = self.run_tool("whose", "--port", str(port))
        self.assertIn("RESERVED HUMAN RANGE", out.stdout)
        self.assertNotIn("unclaimed", out.stdout)

    def test_is_human_answers_by_exit_code_at_both_edges(self):
        """The predicate scripts/spin-up-ppc branches on. It exists so the
        range is stated in ONE place: a shell script that restated
        590-599 would be a second copy to drift."""
        module = load_module()
        first = module.BASE + module.HUMAN_BLOCK_FIRST * module.STRIDE
        last = module.BASE + (module.HUMAN_BLOCK_LAST + 1) * module.STRIDE - 1
        for port, human in ((first, True), (last, True),
                            (first - 1, False), (last + 1, False),
                            (module.BASE, False), (22, False)):
            out = self.run_tool("human", "--is-human", str(port), check=False)
            self.assertEqual(out.returncode, 0 if human else 1,
                             f"port {port}: expected human={human}")
            self.assertEqual(out.stdout, "",
                             "the predicate must be silent — shell branches "
                             "on the exit code, not on output")

    def test_the_reserved_range_is_inside_the_region_it_carves_from(self):
        """A range outside the region would protect nothing: allocation
        only ever hands out blocks 0..BLOCKS-1."""
        module = load_module()
        self.assertGreaterEqual(module.HUMAN_BLOCK_FIRST, 0)
        self.assertLess(module.HUMAN_BLOCK_LAST, module.BLOCKS)
        self.assertTrue(module.is_human_block(module.HUMAN_BLOCK),
                        "the default human block is outside its own range")


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

    def test_spin_up_forwards_tcp_and_udp_on_the_same_wire_number(self):
        """The reliable stream and replaceable pointer lane share N, not a
        socket. Both forwards must reach QEMU's `-netdev` argument; exporting
        a spare environment variable looked right in the script while booting
        a VM with TCP only, and the guest could arm but never receive a point.
        """
        text = SPIN.read_text()
        udp = ('HOSTFWD="${HOSTFWD},hostfwd=udp:127.0.0.1:'
               '${WIRE}-:${WIRE}"')
        self.assertIn(udp, text)
        self.assertIn('"$HOSTFWD" "" "$QMP"', text,
                      "the combined forward string never reaches the QEMU helper")
        self.assertLess(text.index(udp),
                        text.index('boot fresh; wait_anchor'))

    def test_spin_up_selects_only_the_three_mac99_input_profiles(self):
        """PMU/ADB and CUDA comparisons change one machine property only.

        The later `-machine via=...` reaches the shared launcher through its
        existing extra-argument seam; a second hand-written QEMU boot line
        would let the supposedly identical rigs drift in every other respect.
        """
        text = SPIN.read_text()
        self.assertIn('VIA="${NOW_SPIN_VIA:-pmu}"', text)
        self.assertIn('pmu|pmu-adb|cuda)', text)
        self.assertIn('TBT_QEMU_EXTRA_ARGS=(-machine "via=$VIA")', text)
        self.assertIn('"mac99Via": via', text)
        self.assertIn('"artifactOverride": artifact_override', text)
        self.assertIn('if not artifact_override:', text)
        self.assertLess(text.index('TBT_QEMU_EXTRA_ARGS=(-machine "via=$VIA")'),
                        text.index('boot fresh; wait_anchor'))

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

    def test_a_human_stack_cannot_be_handed_over_headless(self):
        """On 2026-08-07 a lane handed Michelle a VM booted `-display
        none`. A modal alert came up in Mail, she had no window to dismiss
        it in, and the stack was unusable. The brief was followed exactly;
        the brief did not say "and give her a screen".

        So the machine decides, from the ports, which already know whose
        it is. RUN, not read: a text assertion would survive an edit that
        moved the check after the boot, which is where it would stop
        mattering.
        """
        # The same two routes spin-up-ppc itself uses, in the same order.
        # Walking up from ROOT alone is not enough: an agent lane's
        # worktree lives under /private/tmp with no shared ancestor at
        # all, so that walk reaches / — and this guard would then SKIP in
        # exactly the configuration the defect happened in.
        if not find_lab():
            raise unittest.SkipTest(
                "no lab checkout (tools/lib.sh) above the repo or its main "
                "worktree, so spin-up-ppc cannot run here")

        module = load_module()
        # A SPARE block in the reserved range, never HUMAN_BLOCK itself.
        # spin-up-ppc refuses an explicitly-requested anchor that is
        # already listening, so aiming at 591 would make this test skip
        # exactly while her stack is up — which is most of the time, and
        # is a gate declining to run in the one condition it is about.
        # Any block in the range proves the same thing: the refusal keys
        # on the RANGE, not on which block inside it.
        spare = next(b for b in range(module.HUMAN_BLOCK_FIRST,
                                      module.HUMAN_BLOCK_LAST + 1)
                     if b != module.HUMAN_BLOCK)
        human_anchor = module.ports_of(spare)["anchor"]

        work = tempfile.mkdtemp(prefix="lnpt-h-", dir="/private/tmp")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        for name in ("base.qcow2", "ext.bin", "app.bin", "shut.bin"):
            open(os.path.join(work, name), "wb").close()

        env = dict(os.environ,
                   NOW_LANE_REGISTRY=os.path.join(work, "registry"),
                   NOW_SPIN_RUN=os.path.join(work, "headless"),
                   TIMBOTTU_QEMU="/bin/echo",
                   NOW_SPIN_BASE=os.path.join(work, "base.qcow2"),
                   NOW_EXT_BIN=os.path.join(work, "ext.bin"),
                   NOW_APP_BIN=os.path.join(work, "app.bin"),
                   NOW_SHUTDOWN_BIN=os.path.join(work, "shut.bin"),
                   NOW_ANCHOR_PORT=str(human_anchor),
                   NOW_WIRE_PORT=str(human_anchor + 1),
                   NOW_SPIN_DISPLAY="0")
        # Popen and a SHORT bounded wait, not subprocess.run(timeout=...).
        # The refusal happens in under a second; anything slower means it
        # did not refuse and has gone on to boot, and this must then say
        # so in one line rather than raise TimeoutExpired out of the
        # plumbing 180 seconds later. Watched, by mutating the guard to
        # `if false`: that is exactly what it did.
        child = subprocess.Popen([str(SPIN)], env=env, cwd=str(ROOT),
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            # Kill the GROUP, and do not wait on the pipes afterwards.
            # spin-up-ppc's readiness poll is a python3 grandchild that
            # inherits stderr and sits there for 300s, so a plain
            # communicate() after kill() blocks on IT — the mutation run
            # took 309 seconds to report a failure it had already
            # decided at 60.
            try:
                os.killpg(os.getpgid(child.pid), signal.SIGKILL)
            except (OSError, ProcessLookupError):
                child.kill()
            self.fail("spin-up-ppc did not refuse a headless human stack — "
                      "it went on to boot one. That is the 2026-08-07 "
                      "defect exactly.")
        out = subprocess.CompletedProcess(
            child.args, child.returncode, stdout, stderr)
        if "is in use" in out.stdout + out.stderr:
            raise unittest.SkipTest(
                "the human stack is running on these ports right now, "
                "which is the whole point of reserving them")
        self.assertEqual(out.returncode, 64,
                         "a human stack was allowed to boot headless:\n"
                         f"{out.stdout}\n{out.stderr}")
        self.assertIn("REFUSING", out.stderr)
        self.assertIn("HUMAN port range", out.stderr)
        # And it refused BEFORE spending a clone on it.
        self.assertFalse(
            os.path.exists(os.path.join(work, "headless", "session.qcow2")),
            "it cloned the image before deciding it would not hand it over")

    def test_the_vm_is_recorded_before_it_boots(self):
        """An orphan nobody recorded cannot be reclaimed. The attach has
        to precede the boot, or a run that dies halfway leaves a machine
        with no handle on it — which is what cost a lane its run."""
        text = SPIN.read_text()
        self.assertLess(text.index('"$NOW/tools/lane-ports" attach'),
                        text.index("boot fresh; wait_anchor"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
