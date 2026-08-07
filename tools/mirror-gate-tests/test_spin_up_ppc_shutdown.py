#!/usr/bin/env python3
"""The visible Mirror spin must not manufacture an unclean OS 9 boot."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "spin-up-ppc"


class SpinUpPPCShutdownTests(unittest.TestCase):
    def test_staged_guest_is_shut_down_from_inside_before_cold_boot(self):
        text = SCRIPT.read_text()
        staged = text.index("python3 \"$NOW/tools/stage-ext.py\"")
        cold = text.index("boot cold; wait_anchor")
        reboot = text[staged:cold]

        self.assertIn("tools/shutdown-guest.py", reboot)
        self.assertNotIn('tools/qmp" "$QMP" quit', reboot)

    def test_the_default_base_is_the_stage_oracle_not_the_plain_runner(self):
        """The stale-oracle failure, one layer below where it is gated.

        AGENTS.md enforces "the stage image is the resident under test" at
        the BAKE layer. This default sat at the SPIN-UP layer and pointed
        at `os91-runner.qcow2` — a plain base last touched in July — so
        every lane that spun up during the 019 arc cloned a July image and
        staged a fresh build into the clone. Whatever a clone cannot
        restage was July's, and nothing said so.

        A caller that wants the plain base asks by name through
        NOW_SPIN_BASE. The default is the oracle.
        """
        text = SCRIPT.read_text()
        default = [l for l in text.split("\n") if l.startswith("BASE=")]
        self.assertEqual(len(default), 1, f"expected one BASE=, got {default}")
        self.assertIn("now-mirror-stage.qcow2", default[0])
        self.assertNotIn("os91-runner.qcow2", default[0])

    def test_the_run_says_which_base_it_cloned(self):
        """The defect was not only that the default went stale — defaults
        do — but that nineteen days of runs never named the image they
        cloned, so no reader could notice. A run that names its base can
        be checked; one that does not has to be trusted."""
        text = SCRIPT.read_text()
        self.assertIn("== base image", text,
                      "spin-up-ppc must announce the base it cloned")

    def test_the_applet_that_does_the_asking_is_staged(self):
        """The shutdown is a guest-side APPLICATION, not a message: the
        anchor worker has no `script` verb and QMP input never reaches
        this guest, so nothing outside the machine can ask. A run that
        stages no applet has no route in at all, and would discover that
        three minutes and one boot later."""
        text = SCRIPT.read_text()
        self.assertIn("NOW_SHUTDOWN_BIN=\"$SHUTDOWN_BIN\"", text)
        # Checked before the boot rather than at the shutdown step.
        preamble = text[:text.index("boot fresh; wait_anchor")]
        self.assertIn("NowShutDown.bin", preamble)

    def test_printed_stop_recipe_is_guest_clean_not_qmp_quit(self):
        text = SCRIPT.read_text()
        stop = text[text.index('echo "stop:'):]

        self.assertIn("shutdown-guest", stop)
        self.assertNotIn("QMP quit", stop)

    def test_readiness_never_hides_a_dirty_base_with_qmp_input(self):
        self.assertNotIn("send-key", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
