#!/usr/bin/env python3
"""Dependency-free contract tests for shared asset-pack parsing policy."""

from __future__ import annotations

from pathlib import Path
import sys
import types


REPO = Path(__file__).resolve().parent.parent

# `fileicons` delegates actual bitmap construction to icons.py, whose Pillow
# dependency belongs to extraction, not to this cheap policy gate. Supplying a
# descriptor source here keeps the test runnable on a fresh checkout while
# still exercising the shared route-selection code every acquisition adapter
# imports.
fake_icons = types.ModuleType("icons")
fake_icons.extract_icons = lambda _fork: []
sys.modules["icons"] = fake_icons
sys.path.insert(0, str(REPO / "tools" / "asset-pack"))

import fileicons  # noqa: E402


def descriptor(resource_id: int, dim: int) -> dict:
    return {
        "id": resource_id,
        "dim": dim,
        "color_type": "icl8" if dim == 32 else "ics8",
        "mask_type": "ICN#" if dim == 32 else "ics#",
        "image": object(),
    }


def main() -> None:
    info = fileicons.finder_info(b"adrpaplt\x85\x00" + b"\0" * 22)
    assert info == {
        "type": b"adrp", "creator": b"aplt", "flags": 0x8500,
    }
    assert info["flags"] & fileicons.FD_HAS_CUSTOM_ICON
    assert fileicons.finder_info(b"short") is None

    fake_icons.extract_icons = lambda _fork: [
        descriptor(-16496, 32), descriptor(-16496, 16),
    ]
    suite = fileicons.extract_custom_icon(object())
    assert suite is not None
    assert suite["id"] == -16496
    assert suite["large"]["dim"] == 32
    assert suite["small"]["dim"] == 16

    # A lone large member is still useful for an icon view; the renderer may
    # fall back to it for a small row rather than inventing art.
    fake_icons.extract_icons = lambda _fork: [descriptor(7, 32)]
    assert fileicons.extract_custom_icon(object())["small"] is None

    # Two large resources are an application-like fork requiring a BNDL/FREF
    # join. The file-icon route must refuse rather than pick the first.
    fake_icons.extract_icons = lambda _fork: [
        descriptor(1, 32), descriptor(2, 32), descriptor(1, 16),
    ]
    assert fileicons.extract_custom_icon(object()) is None

    # Both acquisition adapters end at the same bytes-only decoder. Transport
    # concerns never enter icon selection or custom-icon policy.
    class FakeFork:
        def __init__(self, raw):
            assert raw == b"resource-fork"

    old_fork = fileicons.resfork.ResourceFork
    old_extract = fileicons.extract_custom_icon
    try:
        fileicons.resfork.ResourceFork = FakeFork
        fileicons.extract_custom_icon = lambda _fork: {
            "id": -16496, "large": descriptor(-16496, 32), "small": None,
        }
        decoded = fileicons.decode_custom_icon(
            b"adrpaplt\x04\x00" + b"\0" * 22, b"resource-fork")
        assert decoded["finder"]["type"] == b"adrp"
        assert decoded["suite"]["id"] == -16496
        assert fileicons.decode_custom_icon(
            b"adrpaplt\0\0" + b"\0" * 22, b"resource-fork") is None
    finally:
        fileicons.resfork.ResourceFork = old_fork
        fileicons.extract_custom_icon = old_extract

    print("asset-pack: 5 shared file-icon behaviors passed")
    acquisition_contract()


def load_extractor():
    """Import the extractor without running it.

    It has no `.py` suffix and its heavy imports are deferred inside
    `load_extractors()`, so this stays runnable on a machine with no
    Pillow — which is the whole reason this gate is cheap.
    """
    import importlib.util

    path = REPO / "tools" / "extract-assets-offline"
    spec = importlib.util.spec_from_loader(
        "extract_assets_offline",
        importlib.machinery.SourceFileLoader(
            "extract_assets_offline", str(path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def acquisition_contract() -> None:
    """The list a fetching transport is handed.

    `--required-files` is the ONE statement of what a machine must give
    up, precisely so the host does not keep a second copy that drifts.
    That makes its shape a contract, and these are the properties the
    host's decoder and its required/optional branch actually rely on.
    """
    import importlib.machinery  # noqa: F401  (used via load_extractor)

    module = load_extractor()
    files = module.acquisition_files()

    assert files, "the extractor must name the files it opens"
    for entry in files:
        assert set(entry) == {"path", "role", "required", "why"}, entry
        assert isinstance(entry["required"], bool), entry
        assert entry["path"] and not entry["path"].startswith("/"), entry

    paths = [e["path"] for e in files]
    assert len(paths) == len(set(paths)), "a file is named twice"

    # Every hard gate in the extractor reads one of these. The System file
    # and the theme file raise SystemExit outright when absent, and the
    # required font suitcases are where REQUIRED_SHEETS comes from — so a
    # transport that skipped any of them would fail at extraction rather
    # than write a short pack, and must therefore treat them as required.
    required = {e["path"] for e in files if e["required"]}
    assert module.SYSTEM_FILE in required
    assert module.THEME_FILE in required
    for face in module.FACES:
        assert f"{module.FONTS_DIR}/{face}" in required, face

    # Derived from a DIFFERENT constant on purpose. The font gate refuses a
    # pack missing any of REQUIRED_SHEETS, and those sheet names carry the
    # face they need; the pull list is built from FACES. Checking one
    # against the other is the only assertion here that could fail without
    # this list being edited — add `monaco-9` to REQUIRED_SHEETS without
    # adding Monaco to FACES and every wire ingestion refuses at the last
    # step, having already spent the transfer.
    for sheet in module.REQUIRED_SHEETS:
        face = sheet.rsplit("-", 1)[0]
        wanted = {f.lower() for f in module.FACES}
        assert face.lower() in wanted, (
            f"{sheet!r} is required but {face!r} is not in FACES, so no "
            "transport would ever fetch it")

    # The two that degrade honestly instead. `desktop_state` reports an
    # unresolved desktop and `extract_appearance_patterns` returns a
    # count of zero with its own error string, so a machine without these
    # still yields a pack and the manifest says what is missing.
    optional = {e["path"] for e in files if not e["required"]}
    assert module.APPEARANCE_CP in optional
    assert module.DESKTOP_PREFS in optional

    print(f"asset-pack: acquisition contract passed "
          f"({len(required)} required, {len(optional)} optional)")


if __name__ == "__main__":
    main()
