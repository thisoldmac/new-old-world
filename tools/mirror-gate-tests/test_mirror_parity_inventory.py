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
ARCHIVE_RELATIVE = Path("archive/mirror-standalone-2026-08-09")


def legacy_root(source_root):
    """The frozen source of retired capability names, never production."""
    return source_root / ARCHIVE_RELATIVE


def legacy_capabilities(source_root):
    """Derive the inventory keys from the legacy component contracts."""
    capabilities = set()
    legacy = legacy_root(source_root)

    ax = (legacy / "guest" / "extensions" / "axpeek"
          / "src" / "axshared.h").read_text()
    sample = ax.split("typedef struct {", 1)[1].split("} AXContextSample", 1)[0]
    fields = re.findall(r"(?:uint32_t|unsigned char)\s+(\w+)(?:\[|;)", sample)
    capabilities.update("AXPeek:" + field for field in fields)
    capabilities.add("AXPeek:sample-throttle")

    qd = (legacy / "guest" / "extensions" / "qdpeek"
          / "src" / "qdshared.h").read_text()
    capabilities.update(
        "QDPeek:" + name.lower().replace("_", "-")
        for name in re.findall(r"^#define QD_OP_([A-Z0-9_]+)\s+\d+", qd,
                               re.MULTILINE)
        if name != "WRAP")

    portal = (legacy / "guest" / "extensions" / "portal"
              / "src" / "ptshared.h").read_text()
    capabilities.update(
        "Portal:" + name.lower().replace("_", "-")
        for name in re.findall(r"\bPT_OP_([A-Z0-9_]+)\s*=\s*\d+", portal)
        if name != "NONE")
    capabilities.update(
        "Portal:window-" + name.lower().replace("_", "-")
        for name in re.findall(r"\bPT_WIN_([A-Z0-9_]+)\s*=\s*\d+", portal))

    agent = (legacy / "guest" / "app" / "src"
             / "mirrorverbs.c").read_text()
    dispatch = agent.split("static int dispatch_verb", 1)[1]
    dispatch = dispatch.split("int mirror_verb_handle", 1)[0]
    capabilities.update(
        "mirror-agent:" + verb
        for verb in re.findall(r'strcmp\(verb, "([a-z-]+)"\)', dispatch))

    # After U7 the production NOW stager and launcher must contain none of
    # this runtime. Derive the historical staging/transport rows from the
    # preserved legacy Mirror tools instead of requiring retired code to stay
    # executable in NOW's path merely so the inventory can remember it.
    staging = (legacy / "tools" / "stage-agent.py").read_text()
    spin_up = (legacy / "tools" / "spin-up.sh").read_text()
    host_service = (legacy / "host" / "MirrorKit" / "Sources"
                    / "MirrorApp" / "Serve.swift").read_text()
    if all(name in staging for name in ("AXPeek", "QDPeek", "Portal")):
        capabilities.add("staging:TB-residents")
    if "mirror-agent" in staging:
        capabilities.add("staging:mirror-agent")
    if "mirror.port" in staging:
        capabilities.add("transport:mirror.port")
    if "1420" in staging or "1420" in spin_up:
        capabilities.add("transport:port-1420")
    if "--serve" in host_service:
        capabilities.add("MirrorApp:--serve")
    return capabilities


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
        source = (legacy_root(SOURCE_ROOT) / "host" / "MirrorKit" / "Sources"
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
            set(documented), legacy_capabilities(SOURCE_ROOT),
            "legacy capability inventory drifted from dispatch/shared headers/"
            "staging paths; add a disposition and proof owner for every row")
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
