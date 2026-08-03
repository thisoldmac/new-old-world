#!/usr/bin/env python3
"""Regression coverage for the scored-row UX evidence contract.

Run directly or through ``scripts/test-native``. The tests copy the real gate
into an isolated worktree-shaped directory so no developer sweep state is
created or changed.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
DEFAULT_GATE = HERE.parent / "mirror-gate"


class MirrorGateEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mirror-gate-test-")
        self.root = Path(self.temp.name)
        (self.root / "tools").mkdir()
        (self.root / "docs" / "local").mkdir(parents=True)
        source = Path(os.environ.get("NOW_MIRROR_GATE_UNDER_TEST",
                                     DEFAULT_GATE))
        shutil.copy2(source, self.root / "tools" / "mirror-gate")
        (self.root / "docs" / "mirror-drive-loop.md").write_text(
            "## 1. The rules, recited every pass\nDrive the Mirror.\n---\n")
        (self.root / "docs" / "local" / "mirror-drive-notes.md").write_text(
            "test notes\n")
        self.state = self.root / "docs" / "local" / "mirror-sweep-state.json"
        self.state.write_text(json.dumps({
            "cycles": [{
                "n": "test", "state": "open", "rungs": [1], "app": None,
                "findings": [],
                "rows": [{
                    "id": "r1.move", "rung": 1,
                    "what": "drag it by the title bar",
                    "result": None, "note": "",
                }],
            }],
            "done": None, "pause": None, "fruitless_blocks": 0,
        }, indent=2))

        self.evidence_dir = self.root / "docs" / "local" / "evidence"
        self.evidence_dir.mkdir()
        (self.evidence_dir / "mirror.png").write_text("mirror pixels\n")
        (self.evidence_dir / "guest.ppm").write_text("guest pixels\n")
        (self.evidence_dir / "scene.json").write_text(json.dumps(
            {"snapshotId": "snapshot-7"}))
        (self.evidence_dir / "operation.json").write_text(json.dumps(
            {"id": "operation-12", "source": "human"}))
        (self.evidence_dir / "guest.log").write_text(
            "operation-12 dispatched by guest\n")

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self, **changes):
        value = {
            "schema": "now-mirror-ux-evidence/v1",
            "row": "r1.move",
            "input": {
                "device": "mouse", "target": "NOW Mirror",
                "source": "computer-use",
                "event": "dragged the visible title bar",
            },
            "mirror": {
                "path": "mirror.png", "snapshotId": "snapshot-7",
                "source": "now-mirror-window",
                "capturedAt": "2026-08-03T16:00:00Z",
            },
            "guest": {
                "path": "guest.ppm", "source": "qmp-screendump",
                "capturedAt": "2026-08-03T16:00:03Z",
            },
            "state": {"path": "scene.json", "snapshotId": "snapshot-7"},
            "operation": {
                "path": "operation.json", "id": "operation-12",
                "source": "human",
            },
            "guestLog": {"path": "guest.log", "operationId": "operation-12"},
        }
        for dotted, replacement in changes.items():
            section, field = dotted.split("__", 1)
            value[section][field] = replacement
        path = self.evidence_dir / "manifest.json"
        path.write_text(json.dumps(value, indent=2))
        return path

    def run_gate(self, *args):
        return subprocess.run(
            [str(self.root / "tools" / "mirror-gate"), *args],
            cwd=self.root, text=True, capture_output=True, check=False)

    def score(self, manifest=None):
        args = ["row", "r1.move", "pass"]
        if manifest is not None:
            args += ["--evidence", str(manifest)]
        return self.run_gate(*args)

    def assert_refused(self, result, phrase):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(phrase, result.stderr)

    def test_a_complete_correlated_manifest_scores_the_row(self):
        manifest = self.manifest()
        result = self.score(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(self.state.read_text())["cycles"][0]["rows"][0]
        self.assertEqual(row["result"], "pass")
        self.assertEqual(row["evidence"], str(manifest))
        self.assertEqual(row["shot"], "guest.ppm")

    def test_mcp_only_input_cannot_score_ux(self):
        result = self.score(self.manifest(input__device="mcp"))
        self.assert_refused(result, "keyboard or mouse")

    def test_an_mcp_operation_cannot_pose_as_human_input(self):
        result = self.score(self.manifest(operation__source="mcp"))
        self.assert_refused(result, "operation.source must be human")

    def test_api_input_cannot_pose_as_computer_use(self):
        result = self.score(self.manifest(input__source="mcp"))
        self.assert_refused(result, "input.source must be computer-use")

    def test_a_guest_screendump_alone_cannot_score_ux(self):
        result = self.score()
        self.assert_refused(result, "MCP-only success or a guest screendump")

    def test_the_legacy_shot_flag_is_explicitly_refused(self):
        result = self.run_gate(
            "row", "r1.move", "pass", "--shot",
            str(self.evidence_dir / "guest.ppm"))
        self.assert_refused(result, "--shot is no longer sufficient")

    def test_a_missing_mirror_frame_is_refused(self):
        result = self.score(self.manifest(mirror__path="missing.png"))
        self.assert_refused(result, "mirror.path does not exist")

    def test_a_missing_guest_frame_is_refused(self):
        result = self.score(self.manifest(guest__path="missing.ppm"))
        self.assert_refused(result, "guest.path does not exist")

    def test_state_must_describe_the_displayed_snapshot(self):
        result = self.score(self.manifest(state__snapshotId="snapshot-8"))
        self.assert_refused(result, "state.snapshotId must match")

    def test_guest_logs_must_name_the_operation(self):
        result = self.score(self.manifest(guestLog__operationId="operation-99"))
        self.assert_refused(result, "guestLog.operationId must match")

    def test_the_pair_must_be_captured_at_the_same_settled_moment(self):
        result = self.score(self.manifest(
            guest__capturedAt="2026-08-03T16:00:12Z"))
        self.assert_refused(result, "not the same settled moment")

    def test_qmp_is_observation_only_and_is_named_as_the_guest_source(self):
        result = self.score(self.manifest(guest__source="mirror-screenshot"))
        self.assert_refused(result, "guest.source must be qmp-screendump")

    def test_the_mirror_frame_is_named_as_the_window_under_test(self):
        result = self.score(self.manifest(mirror__source="guest-framebuffer"))
        self.assert_refused(result, "mirror.source must be now-mirror-window")

    def test_capture_times_require_a_timezone(self):
        result = self.score(self.manifest(
            mirror__capturedAt="2026-08-03T16:00:00"))
        self.assert_refused(result, "mirror.capturedAt must include a timezone")

    def test_slice_rows_cannot_run_before_the_sanity_preflight(self):
        value = json.loads(self.state.read_text())
        value["cycles"][0]["rows"].insert(0, {
            "id": "p.workshop-fidelity", "rung": 0,
            "what": "compare Workshop", "result": None, "note": "",
        })
        self.state.write_text(json.dumps(value, indent=2))

        result = self.run_gate("row", "r1.move", "blocked", "not yet")
        self.assert_refused(result, "sanity preflight must pass")

    def test_failed_preflight_closes_without_pretending_slice_coverage(self):
        value = json.loads(self.state.read_text())
        value["cycles"][0]["rows"] = [
            {"id": "p.workshop-fidelity", "rung": 0,
             "what": "compare Workshop", "result": None, "note": ""},
            {"id": "r1.move", "rung": 1, "what": "move",
             "result": None, "note": ""},
        ]
        self.state.write_text(json.dumps(value, indent=2))

        blocked = self.run_gate(
            "row", "p.workshop-fidelity", "blocked", "Workshop regressed")
        self.assertEqual(blocked.returncode, 0, blocked.stderr)
        closed = self.run_gate("close")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        rows = json.loads(self.state.read_text())["cycles"][0]["rows"]
        self.assertEqual(rows[1]["result"], "blocked")
        self.assertIn("preflight failed", rows[1]["note"])


if __name__ == "__main__":
    unittest.main()
