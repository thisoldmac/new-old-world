#!/usr/bin/env python3
"""Keep the resident's installable product name canonical.

The CMake target and C identifiers may use ``NowExt`` internally, but every
artifact that a person, deployment tool, or host catalog sees is exactly
``NOW Extension``.  The two names previously alternated between builds and
handoffs, which also allowed stale abbreviated packages back into onboarding.
"""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ExtensionProductNameTests(unittest.TestCase):

    def read(self, relative):
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_build_emits_only_the_canonical_installable_names(self):
        cmake = self.read("ext/CMakeLists.txt")
        self.assertIn('OUTPUT "NOW Extension.bin" "NOW Extension.dsk"',
                      cmake)
        self.assertIn('-o "NOW Extension.bin"', cmake)
        self.assertIn('--cc "NOW Extension.dsk"', cmake)
        self.assertNotIn("OUTPUT NowExt.bin", cmake)
        self.assertNotIn("-o NowExt.bin", cmake)

    def test_stager_and_emulator_default_to_the_canonical_binary(self):
        spin = self.read("scripts/spin-up-ppc")
        stage = self.read("tools/stage-ext.py")
        self.assertIn("$OUT/ext/NOW Extension.bin", spin)
        self.assertIn('"ext", "NOW Extension.bin"', spin)
        self.assertIn("built NOW Extension.bin", stage)
        self.assertNotIn("built NowExt.bin", stage)

    def test_host_catalog_does_not_accept_the_abbreviated_alias(self):
        catalog = self.read("now-host/Sources/Host/OnboardingAssets.swift")
        self.assertIn('named: ["NOW Extension.bin"]', catalog)
        self.assertNotIn('"NowExt.bin"', catalog)


if __name__ == "__main__":
    unittest.main(verbosity=2)
