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
