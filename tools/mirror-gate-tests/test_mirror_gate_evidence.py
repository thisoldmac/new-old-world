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
            {"snapshotId": "snapshot-7", "sceneGeneration": 17,
             "contentGeneration": 9, "guest": "mac99",
             "session": "session-7"}))
        (self.evidence_dir / "guest.oracle.json").write_text(json.dumps({
            "schema": "now-mirror-oracle-capture/v1",
            "source": "qmp-screendump",
            "capturedAt": "2026-08-03T16:00:01Z",
            "path": str(self.evidence_dir / "guest.ppm"),
            "guest": "mac99", "session": "session-7",
            "build": "build-abc", "vmName": "Fixture VM",
            "qmpSocket": "/private/tmp/fixture/qmp.sock",
        }))
        (self.evidence_dir / "plane.json").write_text(json.dumps(
            {"snapshotId": "snapshot-7", "ownerEpoch": 4,
             "planes": {"structure": "active", "semantics": "active",
                        "content": "active", "interaction": "active"}}))
        (self.evidence_dir / "operation.json").write_text(json.dumps(
            {"id": "operation-12", "source": "human"}))
        (self.evidence_dir / "settlement.json").write_text(json.dumps(
            {"operationId": "operation-12", "terminal": True,
             "outcome": "confirmed"}))
        (self.evidence_dir / "host.log").write_text(
            "operation-12 confirmed by host\n")
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
                "capturedAt": "2026-08-03T16:00:01Z",
                "identityPath": "guest.oracle.json",
                "guest": "mac99", "session": "session-7",
                "build": "build-abc", "vmName": "Fixture VM",
                "qmpSocket": "/private/tmp/fixture/qmp.sock",
            },
            "state": {"path": "scene.json", "snapshotId": "snapshot-7"},
            "plane": {"path": "plane.json", "snapshotId": "snapshot-7"},
            "operation": {
                "path": "operation.json", "id": "operation-12",
                "source": "human",
            },
            "settlement": {
                "path": "settlement.json", "operationId": "operation-12",
            },
            "hostLog": {"path": "host.log", "operationId": "operation-12"},
            "guestLog": {"path": "guest.log", "operationId": "operation-12"},
            "quiescence": {
                "nonterminalOperations": 0,
                "pollIntervalMs": 250,
                "before": [
                    {"sceneGeneration": 17, "contentGeneration": 9,
                     "ownerEpoch": 4},
                    {"sceneGeneration": 17, "contentGeneration": 9,
                     "ownerEpoch": 4},
                ],
                "after": {"sceneGeneration": 17, "contentGeneration": 9,
                          "ownerEpoch": 4},
            },
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

    def test_plane_state_is_required(self):
        manifest = self.manifest()
        value = json.loads(manifest.read_text())
        del value["plane"]
        manifest.write_text(json.dumps(value))
        result = self.score(manifest)
        self.assert_refused(result, "missing object 'plane'")

    def test_terminal_settlement_is_required(self):
        result = self.score(self.manifest(settlement__path="missing.json"))
        self.assert_refused(result, "settlement.path does not exist")

    def test_host_and_guest_logs_must_both_correlate_the_operation(self):
        result = self.score(self.manifest(hostLog__operationId="operation-99"))
        self.assert_refused(result, "hostLog.operationId must match")

    def test_capture_requires_two_unchanged_pre_capture_polls(self):
        manifest = self.manifest()
        value = json.loads(manifest.read_text())
        value["quiescence"]["before"][1]["sceneGeneration"] = 18
        manifest.write_text(json.dumps(value))
        result = self.score(manifest)
        self.assert_refused(result, "two unchanged pre-capture polls")

    def test_capture_is_discarded_when_generation_changes_afterward(self):
        manifest = self.manifest()
        value = json.loads(manifest.read_text())
        value["quiescence"]["after"]["contentGeneration"] = 10
        manifest.write_text(json.dumps(value))
        result = self.score(manifest)
        self.assert_refused(result, "changed during capture")

    def test_capture_requires_no_nonterminal_operation(self):
        result = self.score(self.manifest(
            quiescence__nonterminalOperations=1))
        self.assert_refused(result, "nonterminal operation")

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
        manifest = self.manifest(
            guest__capturedAt="2026-08-03T16:00:03Z")
        capture = json.loads(
            (self.evidence_dir / "guest.oracle.json").read_text())
        capture["capturedAt"] = "2026-08-03T16:00:03Z"
        (self.evidence_dir / "guest.oracle.json").write_text(
            json.dumps(capture))
        result = self.score(manifest)
        self.assert_refused(result, "not the same settled moment")

    def test_qmp_is_observation_only_and_is_named_as_the_guest_source(self):
        result = self.score(self.manifest(guest__source="mirror-screenshot"))
        self.assert_refused(result, "guest.source must be qmp-screendump")

    def test_guest_identity_must_match_the_state_session(self):
        result = self.score(self.manifest(guest__session="another-session"))
        self.assert_refused(result, "guest session must match state artifact")

    def test_guest_build_must_match_the_oracle_capture(self):
        result = self.score(self.manifest(guest__build="another-build"))
        self.assert_refused(result, "guest build must match oracle capture")

    def test_oracle_capture_sidecar_is_required(self):
        result = self.score(self.manifest(guest__identityPath="missing.json"))
        self.assert_refused(result, "guest.identityPath does not exist")

    def test_oracle_capture_requires_an_explicit_socket(self):
        manifest = self.manifest()
        capture = json.loads(
            (self.evidence_dir / "guest.oracle.json").read_text())
        capture["qmpSocket"] = "qmp.sock"
        (self.evidence_dir / "guest.oracle.json").write_text(
            json.dumps(capture))
        result = self.score(manifest)
        self.assert_refused(result, "absolute explicit QMP socket")

    def test_the_mirror_frame_is_named_as_the_window_under_test(self):
        result = self.score(self.manifest(mirror__source="guest-framebuffer"))
        self.assert_refused(result, "mirror.source must be now-mirror-window")

    def test_capture_times_require_a_timezone(self):
        result = self.score(self.manifest(
            mirror__capturedAt="2026-08-03T16:00:00"))
        self.assert_refused(result, "mirror.capturedAt must include a timezone")

    def test_slice_rows_cannot_run_before_the_sanity_preflight_is_attempted(self):
        value = json.loads(self.state.read_text())
        value["cycles"][0]["rows"].insert(0, {
            "id": "p.workshop-fidelity", "rung": 0,
            "what": "compare Workshop", "result": None, "note": "",
        })
        self.state.write_text(json.dumps(value, indent=2))

        result = self.run_gate("row", "r1.move", "blocked", "not yet")
        self.assert_refused(result, "sanity preflight must be attempted")

    def test_a_red_preflight_does_not_hide_independent_slice_coverage(self):
        value = json.loads(self.state.read_text())
        value["cycles"][0]["rows"].insert(0, {
            "id": "p.workshop-fidelity", "rung": 0,
            "what": "compare Workshop", "result": "fail", "note": "red",
        })
        self.state.write_text(json.dumps(value, indent=2))

        result = self.run_gate("row", "r1.move", "blocked", "independent red")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_cycle_begins_with_the_complete_ordered_preflight(self):
        value = json.loads(self.state.read_text())
        value["cycles"] = []
        self.state.write_text(json.dumps(value, indent=2))

        opened = self.run_gate(
            "begin", "25", "--rungs", "1,2,3", "--app", "Date & Time")
        self.assertEqual(opened.returncode, 0, opened.stderr)
        rows = json.loads(self.state.read_text())["cycles"][0]["rows"]
        self.assertEqual([row["id"] for row in rows[:8]], [
            "p.workshop-fidelity",
            "p.menubar-fidelity",
            "p.apple-menu",
            "p.workshop-resize",
            "p.workshop-close",
            "p.hd-open",
            "p.finder-fidelity",
            "p.finder-hide",
        ])
        self.assertEqual(rows[8]["id"], "r1.hide")

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
