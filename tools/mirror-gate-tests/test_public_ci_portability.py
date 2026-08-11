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

    def test_new_sdk_glass_has_an_xcode_16_fallback(self):
        """MUTATION: expose any glass API outside its compiler fence."""
        source = (ROOT / "now-host" / "Sources" / "Host"
                  / "GlassStyle.swift").read_text()
        implementation = source[source.index("private struct NowGlassPanel"):]
        sections = implementation.split("#if compiler(>=6.2)")[1:]
        self.assertEqual(len(sections), 3)
        guarded = [section.partition("#else")[0] for section in sections]
        self.assertTrue(all("#else" in section for section in sections))
        self.assertIn("glassEffect", guarded[0])
        self.assertIn("glassEffect", guarded[1])
        self.assertIn("buttonStyle(.glass)", guarded[2])
        fallbacks = [section.partition("#else")[2].partition("#endif")[0]
                     for section in sections]
        self.assertTrue(all("content.glassEffect" not in fallback
                            for fallback in fallbacks))
        self.assertTrue(all("content.buttonStyle(.glass)" not in fallback
                            for fallback in fallbacks))

    def test_data_mutation_buffers_name_the_raw_overload(self):
        """MUTATION: remove the types and Xcode 16 sees two overloads."""
        source = (ROOT / "now-host" / "Sources" / "Host"
                  / "ClassicDither.swift").read_text()
        annotation = "(out: UnsafeMutableRawBufferPointer) -> Void in"
        self.assertEqual(source.count(annotation), 2)

    def test_avfoundation_test_marks_the_legacy_sdk_boundary(self):
        """MUTATION: drop preconcurrency and Xcode 16 rejects AVAssetTrack."""
        source = (ROOT / "now-host" / "Tests" / "HostTests"
                  / "StreamRecorderTests.swift").read_text()
        self.assertTrue(source.startswith(
            "@preconcurrency import AVFoundation\n"))

    def test_deferred_socket_stress_still_runs_in_the_host_gate(self):
        """MUTATION: defer the stress case without its isolated invocation."""
        script = (ROOT / "scripts" / "test-host").read_text()
        test = (ROOT / "now-host" / "Tests" / "HostTests"
                / "AgentIntegrationSocketTests.swift").read_text()
        flag = "NOW_DEFER_CONCURRENT_SOCKET_TEST"
        case = ("AgentIntegrationSocketTests."
                "testConcurrentHealthCallsReceiveIndependentReplies")
        self.assertIn(flag, test)
        self.assertEqual(script.count(flag + "=1"), 2)
        self.assertEqual(script.count("\n    " + case + "\n"), 1)
        self.assertIn("Task.detached { [endpoint] in", test)
        self.assertIn(
            "AgentIntegrationLocalClient(endpoint: endpoint)", test)
        self.assertEqual(test.count(
            "updateProvider: UpdateProvider(snapshot: .empty)"), 2)

    def test_projection_registries_bridge_swift_diagnostics(self):
        """MUTATION: leave either Swift compiler with the wrong declaration."""
        paths = [
            ROOT / "now-host" / "Sources" / "NOWAgentIntegration"
            / "Projection" / "HostProjectionCatalog.swift",
            ROOT / "now-host" / "Sources" / "NOWAgentIntegration"
            / "Projection" / "MirrorActProjections.swift",
        ]
        for path in paths:
            source = path.read_text()
            self.assertIn("#if compiler(>=6.2)", source)
            self.assertIn("public nonisolated(unsafe) static let", source)
            self.assertIn("#else\n    public static let", source)


if __name__ == "__main__":
    unittest.main()
