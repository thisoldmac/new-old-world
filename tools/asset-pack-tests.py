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


if __name__ == "__main__":
    main()
