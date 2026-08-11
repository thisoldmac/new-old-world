#!/usr/bin/env python3
"""Keep the recovered baseline and strangler inventories derived from code."""

from collections import Counter
import json
import os
from pathlib import Path
import re
import runpy
import unittest


HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("NOW_REPO_ROOT", HERE.parent.parent))
SOURCE_ROOT = Path(os.environ.get("NOW_SOURCE_ROOT", ROOT))
INVENTORY = ROOT / "docs" / "mirror-foldin-inventory.md"
LEGACY_FIXTURE = HERE / "legacy-parity-fixture.json"


def legacy_fixture():
    """The public, source-digested census of the retired private lineage."""
    fixture = json.loads(LEGACY_FIXTURE.read_text())
    if fixture.get("schema") != 1:
        raise ValueError("unknown legacy parity fixture schema")
    return fixture


def table_under(text, heading):
    body = text.split(heading, 1)[1]
    rows = []
    for line in body.splitlines():
        if line.startswith("#"):
            break
        if not line.startswith("| `"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        rows.append([cell.strip("`") for cell in cells])
    return rows


class MirrorParityInventoryTests(unittest.TestCase):
    def test_frozen_legacy_fixture_carries_its_source_identity(self):
        fixture = legacy_fixture()
        digests = fixture["provenance"]["sourceSHA256"]
        self.assertEqual(len(digests), 7)
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", digest)
                            for digest in digests.values()))
        self.assertEqual(len(fixture["legacyCapabilities"]), 64)
        self.assertEqual(len(set(fixture["legacyCapabilities"])), 64)
        self.assertEqual(len(fixture["oldServiceMethods"]), 15)
        self.assertEqual(len(set(fixture["oldServiceMethods"])), 15)

    def test_now_mirror_runtime_has_no_qemu_actuation(self):
        source = (SOURCE_ROOT / "now-host" / "Sources" / "Host"
                  / "NOWMirrorSource.swift").read_text()
        source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
        source = re.sub(r"//.*", "", source)
        forbidden = re.compile(
            r"qmpClick|QMP|sendkey|mouse_(?:move|button|set)|input-send-event",
            re.IGNORECASE)
        self.assertIsNone(
            forbidden.search(source),
            "NOW Mirror production actuation must work on a real Macintosh; "
            "QEMU/QMP is an observation-only development oracle")

    def test_cycle_18_before_state_is_complete_and_unchanged(self):
        fixture = json.loads((HERE / "cycle-18-results.json").read_text())
        gate = runpy.run_path(str(ROOT / "tools" / "mirror-gate"),
                              run_name="mirror_gate_inventory")
        expected = {
            row_id
            for _, rows in gate["RUNGS"].values()
            for row_id, _ in rows
            if not row_id.startswith("r5.") and not row_id.startswith("r6.")
        }
        self.assertEqual(set(fixture["rows"]), expected)
        self.assertEqual(Counter(fixture["rows"].values()), Counter({
            "pass": 15, "fail": 20, "blocked": 3, "n/a": 2,
        }))

    def test_every_old_service_method_has_one_disposition(self):
        methods = set(legacy_fixture()["oldServiceMethods"])
        rows = table_under(INVENTORY.read_text(),
                           "### Old Mirror method disposition")
        documented = [row[0] for row in rows]
        self.assertEqual(len(documented), len(set(documented)),
                         "old Mirror method appears twice in inventory")
        self.assertEqual(set(documented), methods)
        allowed = {
            "canonical broker primitive", "compatibility adapter",
            "explicit refusal", "retirement blocker",
        }
        for row in rows:
            self.assertEqual(len(row), 4)
            self.assertIn(row[3], allowed, row[0])

    def test_every_human_action_case_has_one_disposition(self):
        source = (SOURCE_ROOT / "now-host" / "Packages" / "MirrorKit"
                  / "Sources" / "MirrorKit"
                  / "InteractionPolicy.swift").read_text()
        enum_body = source.split("public enum InteractionPlan", 1)[1]
        enum_body = enum_body.split("public enum FinderContainer", 1)[0]
        cases = set(re.findall(r"^\s*case\s+([A-Za-z][A-Za-z0-9]*)",
                               enum_body, re.MULTILINE))
        rows = table_under(INVENTORY.read_text(), "### Human action catalog")
        documented = [row[0] for row in rows]
        self.assertEqual(len(documented), len(set(documented)),
                         "human action appears twice in inventory")
        self.assertEqual(set(documented), cases)
        allowed = {"canonical broker primitive", "explicit refusal"}
        for row in rows:
            self.assertEqual(len(row), 2)
            self.assertIn(row[1], allowed, row[0])

    def test_every_legacy_runtime_capability_has_a_goal_facing_disposition(self):
        rows = table_under(INVENTORY.read_text(),
                           "### Legacy runtime capability disposition")
        documented = [row[0] for row in rows]
        self.assertEqual(len(documented), len(set(documented)),
                         "legacy capability appears twice in inventory")
        self.assertEqual(
            set(documented), set(legacy_fixture()["legacyCapabilities"]),
            "legacy capability inventory drifted from its source-digested "
            "public fixture; add a disposition and proof owner for every row")
        allowed = {
            "same-capability", "outcome-equivalent-through-NOW",
            "prohibited-mechanism/no-consumer", "explicit-bounded-refusal",
            "retained-as-fixture", "retirement-blocker",
        }
        retirement_closures = {
            "same-capability", "outcome-equivalent-through-NOW",
            "prohibited-mechanism/no-consumer",
        }
        for row in rows:
            self.assertEqual(len(row), 6, row[0])
            capability, source, outcome, relevance, disposition, owner = row
            self.assertTrue(source, capability)
            self.assertTrue(outcome, capability)
            self.assertIn(relevance, {"goal", "legacy-only"}, capability)
            self.assertIn(disposition, allowed, capability)
            self.assertTrue(owner, capability)
            if relevance == "goal":
                self.assertIn(
                    disposition, retirement_closures,
                    "%s is goal-relevant and cannot close as refusal, fixture, "
                    "or blocker" % capability)


if __name__ == "__main__":
    unittest.main()
