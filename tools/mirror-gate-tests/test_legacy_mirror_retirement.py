#!/usr/bin/env python3
"""The production Mirror path is NOW-only and has no private guest runtime."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LegacyMirrorRetirementTests(unittest.TestCase):
    def test_production_path_has_no_legacy_runtime_or_transport(self):
        stage = (ROOT / "tools" / "stage-ext.py").read_text()
        spin = (ROOT / "scripts" / "spin-up-ppc").read_text()
        host = "\n".join((ROOT / "now-host" / "Sources" / "Host" / name)
                         .read_text() for name in (
                             "MirrorControlModel.swift",
                             "MirrorControlView.swift"))
        for forbidden in (
            'os.environ.get("NOW_STAGE_MIRROR"',
            'os.environ.get("NOW_MIRROR_DIR"',
            'if STAGE_MIRROR:', 'MIRROR_DEV =', 'MIRROR_PORT =',
            '("AXPeek",', '("QDPeek",', '("Portal",',
            'push_verified(f"{MIRROR_DEV}:mirror-agent"',
            'write_verified(f"{MIRROR_DEV}:mirror.port"',
        ):
            self.assertNotIn(forbidden, stage,
                             f"stager restored retired path {forbidden}")
        for forbidden in ("NOW_MIRROR_AGENT_PORT", "MIRROR_AGENT=", ":1420"):
            self.assertNotIn(forbidden, spin,
                             f"launcher restored retired transport {forbidden}")
        for forbidden in (
            "AXPeek", "QDPeek", "Portal", "mirror-agent",
            "forwardedAgentPort", "qmpSocketPath", "MirrorProcessSpawner",
            "MirrorTCPProbe",
        ):
            self.assertNotIn(forbidden, host,
                             f"host restored retired runtime {forbidden}")

    def test_spin_up_forwards_only_the_anchor(self):
        spin = (ROOT / "scripts" / "spin-up-ppc").read_text()
        hostfwd = next(line for line in spin.splitlines()
                       if line.startswith('HOSTFWD='))
        self.assertEqual(hostfwd.count("hostfwd="), 1)
        self.assertIn("${ANCHOR}-:1400", hostfwd)

    def test_one_host_model_and_one_native_window_remain(self):
        sources = ROOT / "now-host" / "Sources" / "Host"
        self.assertFalse((sources / "MirrorProduct.swift").exists())
        # Two axes, two controls. The single Open/Close button meant both
        # "run the poll" and "put it on screen"; 019 split them, and the
        # window is now one of two containers rather than the only one.
        view = (sources / "MirrorControlView.swift").read_text()
        self.assertIn('"Stop" : "Start"', view)
        self.assertIn('"Attach" : "Detach"', view)
        module = (sources / "MirrorModuleView.swift").read_text()
        self.assertIn("NOWMirrorWindow", module)
        self.assertIn("MirrorPaneView", module)


if __name__ == "__main__":
    unittest.main()
