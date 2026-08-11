#!/usr/bin/env python3
"""Mutation-shaped host tests for the Mirror visual-oracle loop."""

from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

from mirror_oracle.backends import QMPBackend, SheepShaverBackend  # noqa: E402
from mirror_oracle.assets import extract_chrome  # noqa: E402
from mirror_oracle.images import (Image, compare as compare_images, load,
                                  masked_digest, transparent_crop, write_png)  # noqa: E402
from mirror_oracle.model import OracleCase, VisualProfile, list_cases, list_profiles, resolve_regions  # noqa: E402
from mirror_oracle.runner import compare, render_scene, stable_capture  # noqa: E402


def assert_raises(expected, function, contains: str):
    try:
        function()
    except expected as error:
        assert contains in str(error), (contains, str(error))
        return
    raise AssertionError(f"expected {expected.__name__}: {contains}")


def solid(width: int, height: int, rgb=(0, 0, 0)) -> Image:
    return Image(width, height, bytes((*rgb, 255)) * width * height)


def changed(image: Image, x: int, y: int, rgb) -> Image:
    pixels = bytearray(image.rgba)
    offset = (y * image.width + x) * 4
    pixels[offset : offset + 4] = bytes((*rgb, 255))
    return Image(image.width, image.height, bytes(pixels))


class FakeBackend:
    name = "fake"
    extension = ".png"
    repo = REPO

    def __init__(self, frames, *, input_failure=False):
        self.frames = list(frames)
        self.index = 0
        self.inputs = []
        self.cleanup_count = 0
        self.input_failure = input_failure

    def capture(self, destination):
        frame = self.frames[min(self.index, len(self.frames) - 1)]
        self.index += 1
        write_png(frame, destination)

    def input(self, actions):
        self.inputs.append(list(actions))
        if self.input_failure:
            raise RuntimeError("injected input failure")

    def cleanup_input(self):
        self.cleanup_count += 1

    def provenance(self):
        return {"fixture": True}


def fixture_profile() -> VisualProfile:
    raw = {
        "id": "test", "systemVersion": "8.6", "visualFamily": "platinum",
        "theme": "default", "screen": {"width": 4, "height": 3, "depth": 32},
        "assetPolicy": "fixture",
    }
    return VisualProfile("test", "8.6", "platinum", 4, 3, 32, "default", "fixture", raw)


def fixture_case(*, actions=None, masks=None, regions=None) -> OracleCase:
    raw = {
        "id": "test", "profile": "test", "title": "Fixture",
        "requiredState": ["fixture state"], "inputActions": actions or [],
        "regions": regions or [{"name": "screen", "source": "screen", "rect": [0, 0, 4, 3]}],
        "masks": masks or [], "render": {},
    }
    return OracleCase("test", "test", "Fixture", ["fixture state"], actions or [],
                      raw["regions"], raw["masks"], {}, raw)


def bmp_fixture() -> bytes:
    # Two pixels, bottom-up: red then green in BGR storage.
    width, height, stride = 2, 1, 8
    pixels = bytes((0, 0, 255, 0, 255, 0, 0, 0))
    header = bytearray(54)
    header[0:2] = b"BM"
    struct.pack_into("<I", header, 2, len(header) + len(pixels))
    struct.pack_into("<I", header, 10, 54)
    struct.pack_into("<I", header, 14, 40)
    struct.pack_into("<ii", header, 18, width, height)
    struct.pack_into("<HH", header, 26, 1, 24)
    struct.pack_into("<I", header, 34, stride * height)
    return bytes(header) + pixels


def bitfield_bmp_fixture() -> bytes:
    width, height = 2, 1
    pixels = struct.pack("<II", 0xFFFF0000, 0xFF00FF00)
    header = bytearray(138)
    header[0:2] = b"BM"
    struct.pack_into("<I", header, 2, len(header) + len(pixels))
    struct.pack_into("<I", header, 10, 138)
    struct.pack_into("<I", header, 14, 124)
    struct.pack_into("<ii", header, 18, width, height)
    struct.pack_into("<HH", header, 26, 1, 32)
    struct.pack_into("<I", header, 30, 3)
    struct.pack_into("<I", header, 34, len(pixels))
    struct.pack_into("<IIII", header, 54,
                     0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    return bytes(header) + pixels


def main() -> None:
    profiles = list_profiles()
    cases = list_cases()
    assert [profile.id for profile in profiles] == ["platinum.macos-8.6.default"]
    assert len(cases) == 6
    assert {case.id for case in cases} == {
        "finder-desktop", "finder-front-icon-view", "finder-inactive-window",
        "finder-list-selection", "finder-file-menu-open", "finder-apple-menu-open",
    }

    with tempfile.TemporaryDirectory(prefix="now-mirror-oracle-tests.") as temporary:
        root = Path(temporary)
        png = root / "roundtrip.png"
        original = changed(solid(2, 2), 1, 0, (3, 4, 5))
        write_png(original, png)
        assert load(png) == original

        chrome_source = changed(solid(3, 2, (221, 221, 221)), 1, 0,
                                (12, 34, 56))
        chrome = transparent_crop(chrome_source, (0, 0, 3, 2),
                                  (221, 221, 221))
        assert chrome.pixel(0, 0) == (221, 221, 221, 0)
        assert chrome.pixel(1, 0) == (12, 34, 56, 255)
        zero_alpha = Image(1, 1, bytes((9, 8, 7, 0)))
        assert transparent_crop(zero_alpha, (0, 0, 1, 1),
                                (221, 221, 221)).pixel(0, 0) == (9, 8, 7, 255)

        bmp = root / "fixture.bmp"
        bmp.write_bytes(bmp_fixture())
        decoded_bmp = load(bmp)
        assert decoded_bmp.pixel(0, 0)[:3] == (255, 0, 0)
        assert decoded_bmp.pixel(1, 0)[:3] == (0, 255, 0)

        bitfield_bmp = root / "bitfield.bmp"
        bitfield_bmp.write_bytes(bitfield_bmp_fixture())
        decoded_bitfield = load(bitfield_bmp)
        assert decoded_bitfield.pixel(0, 0) == (255, 0, 0, 255)
        assert decoded_bitfield.pixel(1, 0) == (0, 255, 0, 255)

        ppm = root / "fixture.ppm"
        ppm.write_bytes(b"P6\n2 1\n255\n" + bytes((1, 2, 3, 4, 5, 6)))
        decoded_ppm = load(ppm)
        assert decoded_ppm.pixel(1, 0)[:3] == (4, 5, 6)

        base = solid(4, 3, (20, 20, 20))
        clock_changed = changed(base, 3, 0, (99, 99, 99))
        assert masked_digest(base, [(3, 0, 4, 1)]) == masked_digest(
            clock_changed, [(3, 0, 4, 1)]
        )
        assert masked_digest(base, []) != masked_digest(clock_changed, [])

        report, heatmap = compare_images(
            changed(base, 1, 1, (21, 20, 20)), base,
            [("body", (0, 0, 4, 3))], [],
        )
        assert report[0]["changedPixels"] == 1
        assert report[0]["changeBounds"] == [1, 1, 2, 2]
        assert heatmap.pixel(1, 1) == (255, 0, 0, 255)
        masked_report, _ = compare_images(clock_changed, base,
                                          [("body", (0, 0, 4, 3))], [(3, 0, 4, 1)])
        assert masked_report[0]["changedPixels"] == 0

        scene = {
            "windows": [
                {"app": "Other", "front": True, "visible": True,
                 "rect": {"l": 1, "t": 1, "r": 4, "b": 3}},
                {"app": "Finder", "front": False, "visible": True,
                 "rect": {"l": 0, "t": 0, "r": 3, "b": 2}},
            ]
        }
        dynamic = fixture_case(regions=[
            {"name": "finder", "source": "window", "app": "Finder", "front": False,
             "inset": [0, 0, 1, 0]}
        ])
        assert resolve_regions(dynamic, scene) == [("finder", (0, 0, 2, 2))]

        stable_dir = root / "stable"
        stable_backend = FakeBackend([base, clock_changed])
        masked_case = fixture_case(masks=[{"name": "clock", "rect": [3, 0, 4, 1]}])
        capture_receipt = stable_capture(stable_backend, masked_case, fixture_profile(),
                                         stable_dir, settle_seconds=0)
        assert capture_receipt["stability"]["attempts"][-1]["matchingRunLength"] == 2
        assert capture_receipt["evidenceStatus"] == "reference-only"
        assert (stable_dir / "capture.json").is_file()

        unstable_dir = root / "unstable"
        alternating = FakeBackend([base, changed(base, 0, 0, (1, 1, 1)), base])
        assert_raises(RuntimeError, lambda: stable_capture(
            alternating, fixture_case(), fixture_profile(), unstable_dir,
            consecutive=2, max_attempts=3, settle_seconds=0,
        ), "did not stabilize")
        failure = json.loads((unstable_dir / "capture-failure.json").read_text())
        assert len(failure["stability"]["attempts"]) == 3

        input_dir = root / "input-failure"
        input_backend = FakeBackend([base], input_failure=True)
        assert_raises(RuntimeError, lambda: stable_capture(
            input_backend, fixture_case(actions=["down 0"]), fixture_profile(), input_dir,
            apply_input=True, settle_seconds=0,
        ), "injected input failure")
        assert input_backend.cleanup_count == 1
        assert json.loads((input_dir / "capture-failure.json").read_text())["inputCleanupAttempted"]

        guest = root / "guest.png"
        rendered = root / "render.png"
        write_png(base, guest)
        write_png(changed(base, 2, 2, (30, 20, 20)), rendered)
        comparison = compare(fixture_case(), fixture_profile(), guest, rendered,
                             root / "comparison")
        assert comparison["verdict"] == "mismatch"
        assert (root / "comparison" / "pair.png").is_file()
        assert (root / "comparison" / "diff.png").is_file()

        base_assets = root / "base-assets"
        base_assets.mkdir()
        (base_assets / "manifest.json").write_text(
            '{"pack":"base","desktop":{"kind":"unresolved"}}\n')
        (base_assets / "kept.txt").write_text("immutable base\n")
        (base_assets / "patterns").mkdir()
        write_png(solid(1, 1, (20, 20, 20)),
                  base_assets / "patterns" / "desktop.png")
        profile_raw = dict(fixture_profile().raw)
        profile_raw["chromeAssets"] = {
            "appleMenu": {"rect": [0, 0, 2, 2], "background": "#141414"}
        }
        profile_raw["desktopPattern"] = {
            "name": "Mac OS Default", "asset": "patterns/desktop.png",
            "tileOrigin": [0, 0], "proofRegions": [[0, 1, 4, 3]],
        }
        chrome_profile = replace(fixture_profile(), raw=profile_raw)
        chrome_guest = root / "chrome-guest.png"
        write_png(changed(base, 1, 0, (50, 60, 70)), chrome_guest)
        derived_assets = root / "derived-assets"
        asset_receipt = extract_chrome(chrome_profile, chrome_guest,
                                       base_assets, derived_assets)
        assert (derived_assets / "kept.txt").read_text() == "immutable base\n"
        extracted = load(derived_assets / "chrome" / "apple-menu.png")
        assert extracted.pixel(0, 0)[3] == 0
        assert extracted.pixel(1, 0) == (50, 60, 70, 255)
        assert asset_receipt["baseAssets"]["manifestSha256"]
        derived_manifest = json.loads(
            (derived_assets / "manifest.json").read_text())
        assert derived_manifest["oracleChrome"]
        assert derived_manifest["desktop"]["kind"] == "pattern"
        assert derived_manifest["desktop"]["file"] == "patterns/desktop.png"
        assert asset_receipt["desktopPattern"]["provedPixels"] == 8
        assert json.loads((base_assets / "manifest.json").read_text()) == {
            "pack": "base", "desktop": {"kind": "unresolved"}}

        mismatched_profile_raw = dict(profile_raw)
        mismatched_profile_raw["desktopPattern"] = dict(
            profile_raw["desktopPattern"])
        mismatched_profile_raw["desktopPattern"]["proofRegions"] = [[0, 0, 4, 3]]
        mismatched_profile = replace(
            fixture_profile(), raw=mismatched_profile_raw)
        refused_assets = root / "refused-assets"
        assert_raises(ValueError, lambda: extract_chrome(
            mismatched_profile, chrome_guest, base_assets, refused_assets,
        ), "desktopPattern does not match")
        assert not refused_assets.exists()

        scene_path = root / "scene.json"
        scene_path.write_text("{}")
        render_output = root / "renderer-output.png"

        def fake_run(command, **kwargs):
            output = Path(command[command.index("--output") + 1])
            write_png(base, output)
            return subprocess.CompletedProcess(command, 0, "rendered\n", "")

        render_receipt = render_scene(REPO, fixture_case(), scene_path, render_output,
                                      run=fake_run)
        assert render_receipt["render"]["sha256"]
        assert "mirror-render" in render_receipt["command"]

        qemu = QMPBackend(REPO, root / "qmp.sock")
        assert_raises(ValueError, lambda: qemu.input(["move 1 1"]), "not implemented")

        calls = []
        def record_run(command, **kwargs):
            calls.append((command, kwargs.get("env", {})))
            return subprocess.CompletedProcess(command, 0, "", "")

        sheep = SheepShaverBackend(REPO, root / "run.sheepvm", run=record_run)
        sheep.input(["move 10 10", "down 0", "up 0"])
        assert [call[0][-1] for call in calls] == ["move 10 10", "down 0", "up 0"]
        assert all(call[0][-2] == "input" for call in calls)
        calls.clear()
        sheep.cleanup_input()
        assert len(calls) == 1
        assert calls[0][1]["NOW_SHEEPSHAVER_INPUT_SETTLE"] == "0"
        assert calls[0][0][-8:] == [
            "up 0", "up 1", "up 2", "keyup 55", "keyup 56",
            "keyup 57", "keyup 58", "keyup 59",
        ]

        listing = subprocess.run([str(REPO / "tools" / "mirror-oracle"), "list"],
                                 text=True, capture_output=True, check=True).stdout
        assert "profile platinum.macos-8.6.default" in listing
        assert "case finder-file-menu-open" in listing

    print("mirror-oracle: 24 capture, image, profile, asset, and diff behaviors passed")


if __name__ == "__main__":
    main()
