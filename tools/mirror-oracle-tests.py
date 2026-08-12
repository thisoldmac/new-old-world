#!/usr/bin/env python3
"""Mutation-shaped host tests for the Mirror visual-oracle loop."""

from __future__ import annotations

from dataclasses import replace
import hashlib
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
from mirror_oracle.model import (OracleCase, VisualProfile, list_cases,
                                 list_profiles, load_case,
                                 resolve_regions)  # noqa: E402
from mirror_oracle.runner import compare, render_scene, stable_capture  # noqa: E402
from mirror_oracle.state import STATE_SCHEMA, state_proof_template  # noqa: E402


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
    assert len(cases) == 11
    assert {case.id for case in cases} == {
        "finder-desktop", "finder-front-icon-view", "finder-inactive-window",
        "finder-list-selection", "finder-file-menu-open", "finder-apple-menu-open",
        "finder-buttons-view", "finder-edit-menu-open", "finder-view-menu-open",
        "finder-special-menu-open", "finder-help-menu-open",
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

        template = state_proof_template(
            stable_dir / "capture.json", masked_case, fixture_profile())
        assert template["maskedFramebufferSha256"] == masked_digest(
            base, [(3, 0, 4, 1)])
        assert template["observer"] == ""
        assert template["assertions"] == [{
            "requirement": "fixture state",
            "verdict": "unobserved",
            "evidence": "",
        }]

        proof_path = root / "state-proof.json"
        proof_path.write_text(json.dumps({
            "schema": STATE_SCHEMA,
            "case": "test",
            "profile": "test",
            "observer": "fixture observer",
            "observedAt": "2026-08-11T12:00:00Z",
            "maskedFramebufferSha256": masked_digest(
                base, [(3, 0, 4, 1)]),
            "assertions": [{
                "requirement": "fixture state",
                "verdict": "observed",
                "evidence": "the fixture declares its one visible state",
            }],
        }) + "\n")
        proved_dir = root / "state-proved"
        proved = stable_capture(
            FakeBackend([base, clock_changed]), masked_case,
            fixture_profile(), proved_dir, settle_seconds=0,
            state_proof=proof_path,
        )
        assert proved["evidenceStatus"] == "state-proof-validated"
        assert proved["stateProof"]["observer"] == "fixture observer"
        assert len(proved["stateProof"]["assertions"]) == 1

        wrong_digest = json.loads(proof_path.read_text())
        wrong_digest["maskedFramebufferSha256"] = "0" * 64
        wrong_digest_path = root / "wrong-digest-proof.json"
        wrong_digest_path.write_text(json.dumps(wrong_digest))
        refused_proof_dir = root / "refused-proof"
        assert_raises(ValueError, lambda: stable_capture(
            FakeBackend([base, clock_changed]), masked_case,
            fixture_profile(), refused_proof_dir, settle_seconds=0,
            state_proof=wrong_digest_path,
        ), "different masked framebuffer")
        assert not (refused_proof_dir / "capture.json").exists()
        assert (refused_proof_dir / "capture-failure.json").is_file()

        missing_assertion = json.loads(proof_path.read_text())
        missing_assertion["assertions"] = []
        missing_assertion_path = root / "missing-assertion-proof.json"
        missing_assertion_path.write_text(json.dumps(missing_assertion))
        assert_raises(ValueError, lambda: stable_capture(
            FakeBackend([base, clock_changed]), masked_case,
            fixture_profile(), root / "missing-assertion", settle_seconds=0,
            state_proof=missing_assertion_path,
        ), "assertions do not match requiredState")

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
        chrome_capture_receipt = root / "chrome-capture.json"
        chrome_capture_receipt.write_text(json.dumps({
            "kind": "capture",
            "case": {"id": "test"},
            "profile": {"id": chrome_profile.id},
            "acceptedCapture": {
                "path": str(chrome_guest),
                "sha256": hashlib.sha256(chrome_guest.read_bytes()).hexdigest(),
            },
            "evidenceStatus": "reference-only",
        }))
        derived_assets = root / "derived-assets"
        asset_receipt = extract_chrome(chrome_profile, chrome_guest,
                                       chrome_capture_receipt,
                                       base_assets, derived_assets)
        assert (derived_assets / "kept.txt").read_text() == "immutable base\n"
        extracted = load(derived_assets / "chrome" / "apple-menu.png")
        assert extracted.pixel(0, 0)[3] == 0
        assert extracted.pixel(1, 0) == (50, 60, 70, 255)
        assert asset_receipt["baseAssets"]["manifestSha256"]
        assert asset_receipt["captureReceipt"]["evidenceStatus"] == "reference-only"
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
            mismatched_profile, chrome_guest, chrome_capture_receipt,
            base_assets, refused_assets,
        ), "desktopPattern does not match")
        assert not refused_assets.exists()

        wrong_capture = root / "wrong-chrome-guest.png"
        write_png(base, wrong_capture)
        assert_raises(ValueError, lambda: extract_chrome(
            chrome_profile, wrong_capture, chrome_capture_receipt,
            base_assets, root / "wrong-capture-assets",
        ), "does not match the capture receipt")

        # A Finder alias badge is not accepted from one convenient crop. Two
        # independently extracted icons must leave the same opaque residual
        # over the already-proved desktop tile.
        fileicons = base_assets / "fileicons"
        fileicons.mkdir()
        icon_a = solid(2, 2, (30, 40, 50))
        icon_b = solid(2, 2, (60, 70, 80))
        write_png(icon_a, fileicons / "a.png")
        write_png(icon_b, fileicons / "b.png")
        (fileicons / "manifest.json").write_text(json.dumps({
            "items": {
                "Desktop Folder:A": {"large": "fileicons/a.png"},
                "Desktop Folder:B": {"large": "fileicons/b.png"},
            },
        }))
        alias_pixels = bytearray(solid(4, 3, (20, 20, 20)).rgba)
        for origin, icon in ((0, icon_a), (2, icon_b)):
            for y in range(2):
                for x in range(2):
                    source_offset = (y * 2 + x) * 4
                    target_offset = (y * 4 + origin + x) * 4
                    alias_pixels[target_offset : target_offset + 4] = \
                        icon.rgba[source_offset : source_offset + 4]
        for x in (0, 2):
            offset = (1 * 4 + x) * 4
            alias_pixels[offset : offset + 4] = bytes((9, 8, 7, 255))
        alias_source = Image(4, 3, bytes(alias_pixels))
        alias_guest = root / "alias-guest.png"
        write_png(alias_source, alias_guest)
        alias_profile_raw = dict(fixture_profile().raw)
        alias_profile_raw["desktopPattern"] = {
            "name": "Mac OS Default", "asset": "patterns/desktop.png",
            "tileOrigin": [0, 0], "proofRegions": [[0, 2, 4, 3]],
        }
        alias_profile_raw["chromeAssets"] = {
            "appleMenu": {"rect": [0, 2, 1, 3], "background": "#141414"},
            "aliasBadge": {"proofs": [
                {"path": "Desktop Folder:A", "rect": [0, 0, 2, 2]},
                {"path": "Desktop Folder:B", "rect": [2, 0, 4, 2]},
            ]},
        }
        alias_profile = replace(fixture_profile(), raw=alias_profile_raw)
        alias_capture = root / "alias-capture.json"
        alias_capture.write_text(json.dumps({
            "kind": "capture", "case": {"id": "test"},
            "profile": {"id": alias_profile.id},
            "acceptedCapture": {
                "path": str(alias_guest),
                "sha256": hashlib.sha256(alias_guest.read_bytes()).hexdigest(),
            },
            "evidenceStatus": "state-proof-validated",
        }))
        alias_assets = root / "alias-assets"
        alias_receipt = extract_chrome(
            alias_profile, alias_guest, alias_capture, base_assets, alias_assets)
        alias_badge = load(alias_assets / "chrome" / "alias-badge.png")
        assert alias_badge.pixel(0, 1) == (9, 8, 7, 255)
        assert alias_badge.pixel(1, 1)[3] == 0
        assert alias_receipt["aliasBadge"]["outputPixels"] == 1
        assert alias_receipt["aliasBadge"]["commonPixels"] == 1
        assert alias_receipt["aliasBadge"]["verdict"] == "cross-proof-exact"

        disagreeing = changed(alias_source, 2, 1, (6, 5, 4))
        disagreeing_guest = root / "alias-disagreeing.png"
        write_png(disagreeing, disagreeing_guest)
        disagreeing_capture = json.loads(alias_capture.read_text())
        disagreeing_capture["acceptedCapture"]["path"] = str(disagreeing_guest)
        disagreeing_capture["acceptedCapture"]["sha256"] = hashlib.sha256(
            disagreeing_guest.read_bytes()).hexdigest()
        disagreeing_receipt = root / "alias-disagreeing-capture.json"
        disagreeing_receipt.write_text(json.dumps(disagreeing_capture))
        assert_raises(ValueError, lambda: extract_chrome(
            alias_profile, disagreeing_guest, disagreeing_receipt,
            base_assets, root / "alias-disagreeing-assets",
        ), "residual disagrees")

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

        overlay_case = fixture_case()
        overlay_case.render.update({"finderView": "button",
                                    "finderSelectedName": "Applications"})
        overlay_output = root / "renderer-overlay.png"
        overlay_receipt = render_scene(REPO, overlay_case, scene_path,
                                       overlay_output, run=fake_run)
        assert overlay_receipt["command"][-4:] == [
            "--finder-view", "button",
            "--finder-selected-name", "Applications",
        ]
        metadata_case = fixture_case()
        metadata_case.render.update({
            "finderView": "name",
            "finderMetadata": {"Read Me": {"modified": 3869307060}},
        })
        metadata_output = root / "renderer-metadata.png"
        metadata_receipt = render_scene(
            REPO, metadata_case, scene_path, metadata_output, run=fake_run)
        assert metadata_receipt["command"][-2] == "--finder-metadata-json"
        assert json.loads(metadata_receipt["command"][-1]) == {
            "Read Me": {"modified": 3869307060},
        }
        available_case = fixture_case()
        available_case.render.update({"finderView": "icon",
                                      "finderAvailableBytes": 1073637376})
        available_output = root / "renderer-available.png"
        available_receipt = render_scene(
            REPO, available_case, scene_path, available_output, run=fake_run)
        assert available_receipt["command"][-2:] == [
            "--finder-available-bytes", "1073637376",
        ]

        apple_profile_case = replace(
            fixture_case(), render={"openMenu": 0,
                                    "appleMenuProfile": "macos-8.6"})
        apple_profile_output = root / "apple-profile-output.png"
        apple_profile_receipt = render_scene(
            REPO, apple_profile_case, scene_path, apple_profile_output,
            run=fake_run)
        assert apple_profile_receipt["command"][-2:] == [
            "--apple-menu-profile", "macos-8.6",
        ]

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
        file_menu = load_case("finder-file-menu-open")
        apple_menu = load_case("finder-apple-menu-open")
        desktop = load_case("finder-desktop")
        assert file_menu.input_actions[:-2] == desktop.input_actions
        assert apple_menu.input_actions[:-2] == desktop.input_actions
        assert file_menu.input_actions[-2:] == ["move 55 10", "down 0"]
        assert apple_menu.input_actions[-2:] == ["move 22 10", "down 0"]
        assert apple_menu.render["appleMenuProfile"] == "macos-8.6"
        assert apple_menu.regions[1]["name"] == "apple-menu"
        assert apple_menu.regions[1]["rect"] == [9, 19, 207, 403]
        assert load_case("finder-buttons-view").input_actions[-4:] == [
            "move 130 10", "down 0", "move 145 42", "up 0",
        ]
        assert load_case("finder-front-icon-view").render == {
            "finderView": "icon",
            "finderAvailableBytes": 1073637376,
        }
        list_case = load_case("finder-list-selection")
        assert list_case.render["finderView"] == "name"
        assert list_case.render["finderSelectedName"] == "Applications"
        assert list_case.render["finderAvailableBytes"] == 1073637376
        assert list_case.render["finderMetadata"]["Applications"] == {
            "modified": 3869316420,
        }
        assert [load_case(case).render["openMenu"] for case in (
            "finder-file-menu-open", "finder-edit-menu-open",
            "finder-view-menu-open", "finder-special-menu-open",
            "finder-help-menu-open",
        )] == [1, 2, 3, 4, 5]

    print("mirror-oracle: 35 capture, state, image, profile, asset, and diff behaviors passed")


if __name__ == "__main__":
    main()
