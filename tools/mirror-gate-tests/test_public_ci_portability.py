#!/usr/bin/env python3
"""Public CI must not depend on this Mac's runner or userland defaults."""

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class PublicCIPortabilityTests(unittest.TestCase):
    def test_host_job_selects_a_swift_6_runner(self):
        """MUTATION: restore macos-14 and this names the Swift 5.10 runner."""
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        host = workflow[workflow.index("  host:"):workflow.index("  hygiene:")]
        self.assertIn("runs-on: macos-15", host)
        self.assertNotIn("runs-on: macos-14", host)

    def test_disposition_census_has_canonical_spacing(self):
        """MUTATION: remove the final awk and BSD/GNU padding leaks in."""
        doc = (ROOT / "docs" / "mcp-coverage.md").read_text()
        start = doc.index("derive disposition-census ")
        lines = doc[start:].splitlines()[1:]
        command_lines = []
        for line in lines:
            if not line.startswith("    "):
                break
            command_lines.append(line.strip())
        command = "\n".join(command_lines)
        proc = subprocess.run(
            ["bash", "-o", "pipefail", "-c", command],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = proc.stdout.splitlines()
        self.assertGreater(len(rows), 0)
        self.assertEqual(
            {row.rsplit(" ", 1)[1] for row in rows},
            {"deliberate", "planned", "unnoticed"})
        for row in rows:
            self.assertRegex(row, r"^[0-9]+ (deliberate|planned|unnoticed)$")


if __name__ == "__main__":
    unittest.main()
