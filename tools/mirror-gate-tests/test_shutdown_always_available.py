#!/usr/bin/env python3
"""A guest must always be stoppable cleanly, and the shared image must not
be power-cuttable.

WHAT THIS GATE IS FOR. On 2026-08-07 a lane reported, honestly, that it
had broken the "never QMP `quit`" rule because the graceful route
refused: the anchor's session scope excludes the `script` verb the lab's
`tools/shutdown-guest` asks through, and that tool ends by saying nothing
can then shut the guest down gracefully. Its two remaining options were a
power cut or leaving a VM running for the next lane to trip over.

That is the most plausible mechanism anybody has found for the dirty
images this project is carrying: five of the seven preserved qcow2 files
on this Mac have the HFS volume still marked mounted, so every clone of
them opens in Disk First Aid. `tools/volclean.py` and the bake gate
DETECT that. Nothing prevented it, and nobody had established why it kept
happening. The agents were not careless; they were cornered.

So these tests pin the three things that uncorner them, and each one is
watchable-fail (see the mutation notes on each):

  1. Every caller that CAN pass --wire does. Without it shutdown-guest.py
     skips the Finder route - the only one measured to leave a clean
     volume - for the applet, which starts a shutdown without reliably
     finishing one.
  2. The refusal names a third option and its cost. A message that leaves
     the reader with two bad choices gets read, believed, and correctly
     acted on by nobody - the same lesson as the dead-hooks warning four
     lanes read and did nothing about.
  3. The shared-image guard refuses, and it FAILS CLOSED. A guard that
     answers "allow" when it cannot tell is a guard that stops guarding on
     the one day something is unusual.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"
GUARD_PATH = TOOLS / "shared-image-guard.py"


def _load_guard():
    import importlib.util
    spec = importlib.util.spec_from_file_location("shared_image_guard",
                                                  GUARD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeQMP:
    """A unix socket that speaks just enough QMP to answer query-block.

    The guard's decision turns on a reply from a real socket, so the test
    gives it one. A test that monkey-patched `writable_disks` would prove
    the classifier and nothing about the tool."""

    def __init__(self, disks):
        self.dir = tempfile.mkdtemp(dir="/private/tmp")
        self.path = os.path.join(self.dir, "qmp.sock")
        self.disks = disks
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(self.path)
        self.srv.listen(4)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._session, args=(c,),
                             daemon=True).start()

    def _session(self, c):
        f = c.makefile("rwb")
        try:
            f.write(b'{"QMP":{"version":{},"capabilities":[]}}\n')
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    return
                cmd = json.loads(line).get("execute")
                if cmd == "query-block":
                    blocks = [{"device": f"d{i}",
                               "inserted": {"file": d, "ro": ro}}
                              for i, (d, ro) in enumerate(self.disks)]
                    f.write(json.dumps({"return": blocks}).encode() + b"\n")
                else:
                    f.write(b'{"return":{}}\n')
                f.flush()
        except (OSError, ValueError):
            return
        finally:
            c.close()

    def close(self):
        try:
            self.srv.close()
        except OSError:
            pass


class SharedImageGuardTests(unittest.TestCase):
    """The guard itself, driven over a socket."""

    def setUp(self):
        self.guard = _load_guard()
        self.assets = tempfile.mkdtemp(dir="/private/tmp")
        self.guard.ASSETS = self.assets
        self.session = tempfile.mkdtemp(dir="/private/tmp")
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.close()

    def _sock(self, disks):
        s = FakeQMP(disks)
        self.servers.append(s)
        return s.path

    def _touch(self, path):
        Path(path).write_bytes(b"")
        return path

    def test_a_shared_image_is_refused_by_name(self):
        """MUTATION: make classify() return 'session' unconditionally and
        this fails - the verdict flips to allowed and the shared file's
        name vanishes from the reason."""
        shared = self._touch(os.path.join(self.assets, "now-mirror-stage.qcow2"))
        v = self.guard.verdict(sock_path=self._sock([(shared, False)]))
        self.assertFalse(v["allowed"])
        self.assertIn("now-mirror-stage.qcow2", v["reason"])
        # Naming the cure, not only the crime.
        self.assertIn("shutdown-guest.py", v["reason"])

    def test_a_session_clone_is_allowed_but_still_called_dirty(self):
        """A throwaway clone may be power-cut. It must NOT be described as
        harmless: the reader's next instinct is to keep the image.

        MUTATION: drop the 'do NOT preserve' sentence and this fails."""
        clone = self._touch(os.path.join(self.session, "session.qcow2"))
        v = self.guard.verdict(sock_path=self._sock([(clone, False)]))
        self.assertTrue(v["allowed"])
        self.assertIn("do NOT preserve", v["reason"])

    def test_one_shared_disk_among_several_still_refuses(self):
        """MUTATION: change the loop to decide on the FIRST disk only and
        this fails, because the shared one is second."""
        clone = self._touch(os.path.join(self.session, "session.qcow2"))
        shared = self._touch(os.path.join(self.assets, "os91-runner.qcow2"))
        v = self.guard.verdict(sock_path=self._sock([(clone, False),
                                                     (shared, False)]))
        self.assertFalse(v["allowed"])
        self.assertIn("os91-runner.qcow2", v["reason"])

    def test_a_read_only_shared_disk_does_not_refuse(self):
        """QEMU cannot dirty a volume it has open read-only, and a guard
        that refuses the safe case teaches people to reach for --force.

        MUTATION: drop the `inserted.get("ro")` skip and this fails."""
        clone = self._touch(os.path.join(self.session, "session.qcow2"))
        shared = self._touch(os.path.join(self.assets, "os91-hd.qcow2"))
        v = self.guard.verdict(sock_path=self._sock([(clone, False),
                                                     (shared, True)]))
        self.assertTrue(v["allowed"])

    def test_it_fails_CLOSED_when_qmp_cannot_be_reached(self):
        """The whole point. "I could not tell" must not read as "safe".

        MUTATION: return {"allowed": True} from the except branch and this
        fails - which is the bug this test exists to make unshippable."""
        v = self.guard.verdict(sock_path=os.path.join(self.session, "nope.sock"))
        self.assertFalse(v["allowed"])
        self.assertIn("Refusing rather than guessing", v["reason"])

    def test_it_fails_closed_when_the_machine_reports_no_writable_disk(self):
        v = self.guard.verdict(sock_path=self._sock([]))
        self.assertFalse(v["allowed"])

    def test_a_symlinked_run_directory_cannot_smuggle_a_shared_image(self):
        """MUTATION: use os.path.abspath instead of realpath in _under and
        this fails - the link resolves nowhere near the asset store by
        string, and the shared file is allowed."""
        shared = self._touch(os.path.join(self.assets, "now-mirror-stage.qcow2"))
        link = os.path.join(self.session, "looks-private.qcow2")
        os.symlink(shared, link)
        v = self.guard.verdict(sock_path=self._sock([(link, False)]))
        self.assertFalse(v["allowed"])

    def test_the_cli_exit_code_is_the_verdict(self):
        """A caller shells out to this; the exit status has to carry it."""
        shared = self._touch(os.path.join(self.assets, "now-mirror-stage.qcow2"))
        env = dict(os.environ, NOW_STAGE_ASSETS=self.assets)
        refused = subprocess.run([sys.executable, str(GUARD_PATH),
                                  "--disk", shared], env=env,
                                 capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        clone = self._touch(os.path.join(self.session, "session.qcow2"))
        allowed = subprocess.run([sys.executable, str(GUARD_PATH),
                                  "--disk", clone], env=env,
                                 capture_output=True, text=True)
        self.assertEqual(allowed.returncode, 0)


class EveryCallerPassesTheCleanRoute(unittest.TestCase):
    """--wire is what selects the route measured to leave a clean volume.

    Both of these omitted it until 2026-08-07 while printing the words
    "guest-clean", which is how a rule everybody believed they were
    following was broken by the tooling itself."""

    def test_the_printed_stop_recipe_passes_wire(self):
        """MUTATION: delete `--wire $WIRE` from the recipe and this fails."""
        text = (ROOT / "scripts" / "spin-up-ppc").read_text()
        stop = text[text.index('echo "stop:  $NOW/tools/shutdown-guest.py'):]
        self.assertIn("--wire $WIRE", stop)

    def test_lane_ports_reclaim_passes_wire(self):
        """MUTATION: remove "--wire", wire from the argv and this fails.

        Anchored on the argv LITERAL rather than on the first mention of
        the filename. It used to slice from `text.index("shutdown-guest.py")`
        and that broke at the round 7 merge without either lane being
        wrong: a sibling lane added a `SHUTDOWN_RIG_MISSING` constant whose
        comment names the same tool eighty lines above the call, so the
        slice began in a comment and the assertion read a region with no
        argv in it. A locator that any new PROSE can move is not a locator.
        """
        text = (TOOLS / "lane-ports").read_text()
        marker = '"shutdown-guest.py")'      # the argv element, not a mention
        self.assertIn(marker, text,
                      "reclaim must invoke tools/shutdown-guest.py by name")
        call = text[text.index(marker):]
        call = call[:call.index("returncode")]
        self.assertIn('"--wire"', call)

    def test_lane_ports_power_cut_goes_through_the_guard(self):
        """A lane owns its block; it does not own the shared asset store,
        and `launch --base` writes straight into it.

        MUTATION: delete the guard subprocess call and this fails."""
        text = (TOOLS / "lane-ports").read_text()
        self.assertIn("shared-image-guard.py", text)
        cut = text[text.index("power_cut:"):]
        cut = cut[:cut.index("elif rc != 0")]
        self.assertIn("shared-image-guard.py", cut)
        self.assertLess(cut.index("shared-image-guard.py"),
                        cut.index("qmp_quit(sock)"),
                        "the guard must run BEFORE the quit, not beside it")

    def test_the_in_run_shutdown_explains_why_it_has_no_wire(self):
        """The one caller that legitimately cannot pass --wire says so, so
        that a reader closing the gap above does not 'fix' it."""
        text = (ROOT / "scripts" / "spin-up-ppc").read_text()
        pre = text[:text.index("boot cold; wait_anchor")]
        self.assertIn("NO --wire HERE, AND THAT IS DELIBERATE", pre)


class TheRefusalIsActionable(unittest.TestCase):
    """A failure that names no action is the shape of warning this project
    has already paid for once - four lanes read the dead-hooks warning,
    believed it, and correctly did nothing about it."""

    def setUp(self):
        self.text = (TOOLS / "shutdown-guest.py").read_text()

    def test_it_offers_a_third_option_that_is_not_a_power_cut(self):
        """MUTATION: delete print_the_third_option's CALL SITE and this
        fails.

        It did not, at first. The test asserted the name appeared in the
        file, which the definition satisfies on its own - so a version
        that carried the whole message and never printed it read green.
        That is the defect this gate is about, in miniature: the text
        existing is not the text reaching anybody. Assert the call, in
        main, where it has to run."""
        main = self.text[self.text.index("def main():"):]
        main = main[:main.index("def _graceful")]
        self.assertIn("print_the_third_option(a.sock", main)
        body = self.text[self.text.index("def print_the_third_option"):]
        body = body[:body.index("def force_power_cut")]
        self.assertIn("LEAVE IT UP", body)          # the free one
        self.assertIn("--force", body)              # the deliberate one
        self.assertIn("--wire", body)               # the retry

    def test_it_states_what_the_power_cut_COSTS(self):
        """"Do not do this" without the price is a rule; the price is what
        makes it a decision."""
        body = self.text[self.text.index("def print_the_third_option"):]
        body = body[:body.index("def force_power_cut")]
        self.assertIn("Disk First Aid", body)

    def test_force_asks_the_guard_before_quitting(self):
        """MUTATION: move quit_a_shut_down_machine above the verdict check
        and this fails."""
        body = self.text[self.text.index("def force_power_cut"):]
        body = body[:body.index("def front_process")]
        self.assertLess(body.index("guard.verdict"),
                        body.index("quit_a_shut_down_machine"))
        self.assertIn('if not v["allowed"]', body)

    def test_force_stamps_the_disk_it_cut(self):
        """The damage is invisible until something boots the image. A
        sidecar outlives the process; a printed warning does not.

        MUTATION: delete the .power-cut write and this fails."""
        body = self.text[self.text.index("def force_power_cut"):]
        body = body[:body.index("def front_process")]
        self.assertIn(".power-cut", body)

    def test_the_scope_preflight_runs_before_any_route_is_tried(self):
        """The refusal stated up front is a route list; stated three
        minutes in it reads as a broken machine."""
        main = self.text[self.text.index("def main():"):]
        self.assertLess(main.index("print_scope_preflight"),
                        main.index("_graceful(a)"))

    def test_the_preflight_says_the_script_route_is_shut_for_everyone(self):
        """The lab tool calls it "a scope decision", which reads as though
        another session would fare better. None would: the scope is a
        static worker.session baked into both base images.

        MUTATION: soften this to "may not be available" and this fails."""
        body = self.text[self.text.index("def routes("):]
        body = body[:body.index("def print_scope_preflight")]
        self.assertIn("every machine in this rig", body)
        self.assertIn("Not a per-session decision", body)

    def test_launch_being_IN_scope_is_stated_not_assumed(self):
        """The false half of the lab tool's message is the expensive half:
        `launch` IS in the baked scope, which is why a graceful route
        exists at all."""
        doc = self.text[:self.text.index("import argparse")]
        self.assertIn("`launch` IS in", doc)
        self.assertIn("the baked scope", doc)

    def test_a_completed_route_is_not_success_until_hfs_says_clean(self):
        """MUTATION: return zero directly after `_graceful` and this fails.

        Disk quiet was previously printed as "already unmounted" even though
        the same file documents three quiet, dirty applet exits. The result is
        a volume fact, so the volume must be the final authority.
        """
        main = self.text[self.text.index("def main():"):]
        main = main[:main.index("def _graceful")]
        self.assertIn("return verify_clean_volume(a.sock, a.disk)", main)
        self.assertNotIn("quitting the already-unmounted machine", self.text)

    def test_volclean_is_directly_executable_as_documented(self):
        first = (TOOLS / "volclean.py").read_text().splitlines()[0]
        self.assertEqual(first, "#!/usr/bin/env python3")


class RoutesReadTheMachineRatherThanAssumeIt(unittest.TestCase):
    """The route list is derived from the anchor's own hello, so an unusual
    machine is described rather than mis-described."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "shutdown_guest", TOOLS / "shutdown-guest.py")
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)

    def test_the_canonical_scope_leaves_two_routes_open_and_one_shut(self):
        """The exact 24 verbs read out of both base images on 2026-08-07."""
        canonical = {
            "put-open", "put", "close", "fetch", "get-open", "get", "list",
            "read", "stat", "write", "mkdir", "move", "delete", "launch",
            "observe", "gestalt", "echo", "capture", "screenshot",
            "shotdata", "axsnap", "click", "key", "type"}
        self.assertEqual(len(canonical), 24)
        self.assertNotIn("script", canonical)
        opened = {name: is_open for name, is_open, _ in
                  self.mod.routes(canonical, wire=5311, applet_staged=True)}
        self.assertEqual(list(opened.values()), [True, True, False])

    def test_without_wire_the_clean_route_is_reported_as_skipped(self):
        """MUTATION: report it open regardless of --wire and this fails.
        A route listed as open and never taken is how the dirty route came
        to be the default."""
        canonical = {"launch", "observe"}
        rows = self.mod.routes(canonical, wire=None, applet_staged=True)
        self.assertFalse(rows[0][1])
        self.assertIn("NOT ATTEMPTED", rows[0][2])

    def test_an_anchor_that_did_not_answer_is_not_reported_as_narrow(self):
        """None means unknown. Reporting unknown as "your scope is too
        small" sends the reader to fix the wrong thing."""
        rows = self.mod.routes(None, wire=None, applet_staged=True)
        self.assertTrue(rows[1][1], "an unknown scope must not close the "
                                    "applet route on a guess")

    def test_an_anchor_missing_launch_is_flagged_as_NOT_canonical(self):
        """Every base image has `launch`. An anchor without it is not the
        one this rig bakes - most likely another lane's machine on a port
        you did not expect, which is a documented hazard here."""
        rows = self.mod.routes({"observe"}, wire=None, applet_staged=True)
        self.assertFalse(rows[1][1])
        self.assertIn("not the canonical anchor", rows[1][2])


if __name__ == "__main__":
    unittest.main()
