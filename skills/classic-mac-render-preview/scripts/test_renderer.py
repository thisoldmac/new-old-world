#!/usr/bin/env python3
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from classic_preview.contracts import load_scene, validate_scene
from classic_preview.raster import Raster
from classic_preview.render import render_scene

FIXTURES = Path(__file__).parent / "fixtures"
EVIDENCE = (
    Path(__file__).parents[1]
    / "references" / "evidence" / "carbonlib-16-os91"
)


class RendererTests(unittest.TestCase):
    def test_carbon_calibration_contains_only_accepted_native_exemplars(self):
        expected = {
            "ide.png", "ui-explorer.png", "guest-share.png",
            "chat.png", "chat-generating.png",
        }
        self.assertEqual(
            {path.name for path in EVIDENCE.glob("*.png")},
            expected,
        )
        for name in expected:
            data = (EVIDENCE / name).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            width, height = struct.unpack(">II", data[16:24])
            self.assertEqual((width, height), (800, 600))

    def test_all_supported_presets_validate_and_render_exact_indexed_pngs(self):
        expected = {
            "system6-compact.json": (512, 342, 1),
            "system7-classic.json": (640, 480, 4),
            "platinum-toolbox.json": (800, 600, 8),
            "platinum-carbonlib.json": (800, 600, 8),
        }
        with tempfile.TemporaryDirectory() as directory:
            for name, dimensions in expected.items():
                with self.subTest(name=name):
                    scene = load_scene(FIXTURES / name)
                    normalized, report = validate_scene(scene, FIXTURES)
                    self.assertTrue(report["valid"], report["errors"])
                    output = Path(directory) / f"{name}.png"
                    render_scene(normalized, report).save_png(output)
                    data = output.read_bytes()
                    self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                    width, height, depth, color_type = struct.unpack(">IIBB", data[16:26])
                    self.assertEqual((width, height, depth), dimensions)
                    self.assertEqual(color_type, 3)
                    self.assertIn(b"measured-preview", data)

    def test_databrowser_fails_on_system7_without_explicit_fallback(self):
        scene = load_scene(FIXTURES / "invalid-system7-databrowser.json")
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        self.assertIn("unsupported", {error["code"] for error in report["errors"]})

    def test_databrowser_list_fallback_is_reported(self):
        scene = load_scene(FIXTURES / "invalid-system7-databrowser.json")
        scene["components"][0]["fallback"] = "list"
        _, report = validate_scene(scene, FIXTURES)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["components"][0]["status"], "fallback-used")

    def test_reference_asset_is_audited_but_not_renderable(self):
        scene = load_scene(FIXTURES / "system6-compact.json")
        scene["assets"] = [{
            "id": "visual-reference",
            "status": "reference-only",
            "source": "local screenshot",
            "rights": "reference use only",
        }]
        _, report = validate_scene(scene, FIXTURES)
        self.assertTrue(report["valid"], report["errors"])
        self.assertFalse(report["assets"][0]["renderable"])

    def test_system6_screen_override_fails(self):
        scene = load_scene(FIXTURES / "system6-compact.json")
        scene["screen"] = {"width": 640, "height": 480, "depth": 1}
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        self.assertIn("compact-screen", {error["code"] for error in report["errors"]})

    def test_carbonlib_defaults_to_platinum_chrome_and_named_native_primitives(self):
        scene = load_scene(FIXTURES / "platinum-carbonlib.json")
        normalized, report = validate_scene(scene, FIXTURES)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["presentation"]["resolved_chrome"], "appearance-manager-platinum")
        self.assertFalse(report["presentation"]["intentional_override"])
        self.assertIn("SetThemeWindowBackground", report["presentation"]["chrome_routes"])
        self.assertEqual(
            report["calibration"]["id"],
            "macos91-carbonlib16-native-exemplar-v4",
        )
        self.assertEqual(report["renderer"]["version"], "1.6.0")
        primitives = {item["type"]: item["primitive"] for item in report["components"]}
        self.assertEqual(
            primitives["tabs"],
            "CreateTabsControl + CreateUserPaneControl + EmbedControl",
        )
        self.assertEqual(primitives["databrowser"], "CreateDataBrowserControl")
        self.assertEqual(primitives["bevel_button"], "CreateBevelButtonControl")
        self.assertEqual(
            primitives["placard"],
            "CreatePlacardControl + CreateStaticTextControl",
        )
        rendered = render_scene(normalized, report)
        pixels = set(rendered.pixels)
        self.assertTrue({0, 1, 2, 3, 5, 12}.issubset(pixels), pixels)
        self.assertEqual(rendered.pixels[440 * rendered.width + 110], 2)
        self.assertEqual(rendered.pixels[398 * rendered.width + 121], 2)
        self.assertEqual(rendered.pixels[296 * rendered.width + 153], 0)

    def test_carbon_tabs_reject_detached_strip_without_declared_pane(self):
        scene = load_scene(FIXTURES / "platinum-carbonlib.json")
        tabs = scene["components"][0]
        tabs["height"] = 28
        tabs.pop("pane_for")
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        codes = {error["code"] for error in report["errors"]}
        self.assertIn("tab-pane", codes)
        self.assertIn("tab-pane-for", codes)

    def test_cross_era_chrome_requires_explicit_override_and_is_reported(self):
        scene = load_scene(FIXTURES / "platinum-carbonlib.json")
        scene["presentation"] = {"chrome": "classic-monochrome"}
        _, report = validate_scene(scene, FIXTURES)
        self.assertTrue(report["valid"], report["errors"])
        self.assertTrue(report["presentation"]["intentional_override"])
        self.assertIn("intentional-era-override", {warning["code"] for warning in report["warnings"]})
        self.assertEqual(report["presentation"]["resolved_chrome"], "classic-monochrome")

    def test_planning_font_preserves_mixed_case(self):
        upper = Raster(8, 9, 1)
        lower = Raster(8, 9, 1)
        upper.text(1, 1, "A")
        lower.text(1, 1, "a")
        self.assertNotEqual(upper.pixels, lower.pixels)

    def test_carbon_only_workspace_controls_need_fallback_on_system7(self):
        scene = load_scene(FIXTURES / "system7-classic.json")
        scene["components"].append({
            "id": "status",
            "type": "placard",
            "x": 20,
            "y": 250,
            "width": 200,
            "height": 20,
            "text": "Connected",
        })
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        self.assertIn("unsupported", {error["code"] for error in report["errors"]})

    def test_carbon_showcase_controls_validate_render_and_report_primitives(self):
        scene = {
            "target": "platinum-carbonlib",
            "screen": {"width": 800, "height": 600, "depth": 8},
            "application": "Showcase",
            "window": {"x": 70, "y": 50, "width": 660, "height": 500, "title": "Carbon 1.6 Showcase"},
            "components": [
                {"id": "popup", "type": "popup", "x": 20, "y": 20, "width": 150, "height": 20, "items": ["One", "Two"], "selected": 1},
                {"id": "slider", "type": "slider", "x": 20, "y": 55, "width": 180, "height": 24, "min": 0, "max": 10, "value": 6, "ticks": 6},
                {"id": "arrows", "type": "little_arrows", "x": 215, "y": 52, "width": 18, "height": 28, "min": 0, "max": 10, "value": 6},
                {"id": "details", "type": "disclosure", "x": 20, "y": 92, "width": 180, "height": 18, "text": "Details", "open": True},
                {"id": "well", "type": "image_well", "x": 260, "y": 20, "width": 100, "height": 100, "symbol": "folder", "caption": "System Folder"},
                {"id": "icon", "type": "system_icon", "x": 390, "y": 24, "width": 80, "height": 60, "symbol": "disk", "text": "Disk"},
                {"id": "editor", "type": "text_area", "x": 20, "y": 140, "width": 300, "height": 160, "lines": ["int main(void)", "return 0;"], "line_numbers": True},
                {"id": "canvas", "type": "quickdraw_canvas", "x": 340, "y": 140, "width": 270, "height": 160, "mode": "charts", "allow_custom": True},
            ],
            "assets": [],
        }
        normalized, report = validate_scene(scene)
        self.assertTrue(report["valid"], report["errors"])
        primitives = {item["type"]: item["primitive"] for item in report["components"]}
        self.assertEqual(primitives["popup"], "CreatePopupButtonControl")
        self.assertEqual(primitives["slider"], "CreateSliderControl")
        self.assertEqual(primitives["little_arrows"], "CreateLittleArrowsControl")
        self.assertEqual(primitives["disclosure"], "CreateDisclosureTriangleControl")
        self.assertEqual(primitives["image_well"], "CreateImageWellControl")
        self.assertEqual(primitives["system_icon"], "CreateIconControl + GetIconRef")
        self.assertEqual(
            primitives["text_area"],
            "TXNNewObject + TXNSetBackground (MLTE)",
        )
        self.assertEqual(primitives["quickdraw_canvas"], "QuickDraw offscreen GWorld + CopyBits")
        render_scene(normalized, report)

    def test_slider_rejects_invalid_range(self):
        scene = load_scene(FIXTURES / "platinum-carbonlib.json")
        scene["components"].append({
            "id": "bad-slider", "type": "slider", "x": 20, "y": 410,
            "width": 120, "height": 20, "min": 10, "max": 10, "value": 10,
        })
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        self.assertIn("component-range", {error["code"] for error in report["errors"]})

    def test_application_basis_is_explicitly_reported_and_validated(self):
        scene = load_scene(FIXTURES / "platinum-carbonlib.json")
        scene["application_basis"] = "verified-implementation"
        _, report = validate_scene(scene, FIXTURES)
        self.assertTrue(report["valid"], report["errors"])
        self.assertEqual(report["application_basis"], "verified-implementation")

        scene["application_basis"] = "shipping-because-it-looks-good"
        _, report = validate_scene(scene, FIXTURES)
        self.assertFalse(report["valid"])
        self.assertIn("application-basis", {error["code"] for error in report["errors"]})


if __name__ == "__main__":
    unittest.main()
