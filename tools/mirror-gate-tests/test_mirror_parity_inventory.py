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
        source = (SOURCE_ROOT / "mirror" / "host" / "MirrorKit" / "Sources"
                  / "MirrorApp" / "Serve.swift").read_text()
        methods = set(re.findall(r'case "(mirror\.[a-z.]+)"', source))
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
        source = (SOURCE_ROOT / "mirror" / "host" / "MirrorKit" / "Sources"
                  / "MirrorKit" / "InteractionPolicy.swift").read_text()
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


if __name__ == "__main__":
    unittest.main()
