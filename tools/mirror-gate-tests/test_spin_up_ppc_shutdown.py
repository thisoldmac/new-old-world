#!/usr/bin/env python3
"""The visible Mirror spin must not manufacture an unclean OS 9 boot."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "spin-up-ppc"


class SpinUpPPCShutdownTests(unittest.TestCase):
    def test_staged_guest_is_shut_down_from_inside_before_cold_boot(self):
        text = SCRIPT.read_text()
        staged = text.index("== stage the extension and the app ==")
        cold = text.index("boot cold; wait_anchor")
        reboot = text[staged:cold]

        self.assertIn("tools/shutdown-guest", reboot)
        self.assertNotIn('tools/qmp" "$QMP" quit', reboot)

    def test_printed_stop_recipe_is_guest_clean_not_qmp_quit(self):
        text = SCRIPT.read_text()
        stop = text[text.index('echo "stop:'):]

        self.assertIn("shutdown-guest", stop)
        self.assertNotIn("QMP quit", stop)

    def test_readiness_never_hides_a_dirty_base_with_qmp_input(self):
        self.assertNotIn("send-key", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
