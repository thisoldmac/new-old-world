#!/usr/bin/env python3
"""The framebuffer helper must never guess which QEMU session it observes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SHOT = HERE.parent / "shot"


class ExplicitOracleShotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="now-shot-test-")
        self.root = Path(self.temp.name)
        (self.root / "now" / "tools").mkdir(parents=True)
        (self.root / "tools").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy2(SHOT, self.root / "now" / "tools" / "shot")
        (self.root / "tools" / "lib.sh").write_text("# fixture\n")
        self.socket = self.root / "oracle.sock"
        self.socket.write_text("fixture")
        guessed = self.root / "now" / "run" / "guessed" / "qmp.sock"
        guessed.parent.mkdir(parents=True)
        guessed.write_text("the old helper would silently select this")
        self.identity = self.root / "identity.json"
        self.write_identity()

        qmp = self.root / "tools" / "qmp"
        qmp.write_text("""#!/usr/bin/env python3
import json, pathlib, sys
if sys.argv[2] == "query-name":
    print(json.dumps({"return": {"name": "Fixture VM"}}))
else:
    args = json.loads(sys.argv[3])
    pathlib.Path(args["filename"]).write_text("P3\\n1 1\\n255\\n\\0")
    print(json.dumps({"return": {}}))
""")
        qmp.chmod(0o755)
        sips = self.root / "bin" / "sips"
        sips.write_text("""#!/bin/sh
set -eu
cp "$4" "$6"
""")
        sips.chmod(0o755)
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.root / 'bin'}:{self.env['PATH']}"
        self.env["NOW_SHOT_DIR"] = str(self.root / "captures")

    def tearDown(self):
        self.temp.cleanup()

    def write_identity(self, **changes):
        value = {
            "schema": "now-mirror-oracle-identity/v1",
            "guest": "mac99",
            "session": "session-7",
            "build": "build-abc",
            "vmName": "Fixture VM",
            "qmpSocket": str(self.socket),
        }
        value.update(changes)
        self.identity.write_text(json.dumps(value))

    def run_shot(self, *args):
        return subprocess.run(
            [str(self.root / "now" / "tools" / "shot"), *args],
            text=True, capture_output=True, env=self.env, check=False)

    def test_socket_discovery_is_refused(self):
        result = self.run_shot("old-style-name")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--qmp is required", result.stderr)

    def test_guest_build_identity_is_required(self):
        result = self.run_shot("--qmp", str(self.socket), "proof")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--identity is required", result.stderr)

    def test_explicit_socket_must_match_the_identity_artifact(self):
        other = self.root / "other.sock"
        other.write_text("fixture")
        result = self.run_shot(
            "--qmp", str(other), "--identity", str(self.identity), "proof")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match oracle identity", result.stderr)

    def test_qmp_vm_name_must_match_the_identity_artifact(self):
        self.write_identity(vmName="Another VM")
        result = self.run_shot(
            "--qmp", str(self.socket), "--identity", str(self.identity),
            "proof")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QMP VM identity mismatch", result.stderr)

    def test_capture_writes_correlated_identity_sidecar(self):
        result = self.run_shot(
            "--qmp", str(self.socket), "--identity", str(self.identity),
            "proof")
        self.assertEqual(result.returncode, 0, result.stderr)
        image = Path(result.stdout.strip())
        self.assertTrue(image.is_file())
        artifact = json.loads(
            image.with_suffix(".oracle.json").read_text())
        self.assertEqual(artifact["source"], "qmp-screendump")
        self.assertEqual(artifact["guest"], "mac99")
        self.assertEqual(artifact["session"], "session-7")
        self.assertEqual(artifact["build"], "build-abc")
        self.assertEqual(artifact["vmName"], "Fixture VM")
        self.assertEqual(artifact["qmpSocket"], str(self.socket))


if __name__ == "__main__":
    unittest.main()
