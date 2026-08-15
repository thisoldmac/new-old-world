"""Finder-owned custom icon extraction, independent of acquisition route.

Classic files with ``fdHasCustomIcon`` carry their large/small Finder art in
their own resource fork.  The stopped-volume adapter reads that fork from a
mounted HFS+ copy; the future connected adapter can obtain the same bytes via
NOW's fork-bearing ``file.*`` transport.  This module deliberately knows
nothing about either transport or about pack output paths.
"""

from __future__ import annotations

from typing import Any

import icons
import resfork


# Finder flags in the first 16 bytes of FileInfo.
FD_HAS_CUSTOM_ICON = 0x0400


def finder_info(raw: bytes) -> dict[str, Any] | None:
    """Decode the fields needed to attribute a file-specific icon."""
    if len(raw) < 10:
        return None
    return {
        "type": raw[0:4],
        "creator": raw[4:8],
        "flags": int.from_bytes(raw[8:10], "big"),
    }


def extract_custom_icon(fork: resfork.ResourceFork) -> dict[str, Any] | None:
    """Return one unambiguous custom icon suite from an item's fork.

    The custom-icon resource id is not stable across every classic Finder
    producer.  What *is* stable at this boundary is stronger: a file whose
    Finder flags assert custom art and whose own fork contains exactly one
    32-pixel colour icon.  Multiple large icons need a BNDL/FREF identity
    join and are application bundles, not an answer this file-icon route may
    guess.  A matching 16-pixel member is optional but must share the id.
    """
    descriptors = icons.extract_icons(fork)
    large = [item for item in descriptors if item["dim"] == 32]
    if len(large) != 1:
        return None
    picked = large[0]
    small = next((item for item in descriptors
                  if item["dim"] == 16 and item["id"] == picked["id"]), None)
    return {
        "id": picked["id"],
        "large": picked,
        "small": small,
    }


def decode_custom_icon(finder_info_raw: bytes,
                       resource_fork_raw: bytes) -> dict[str, Any] | None:
    """Decode one acquired file without knowing how its bytes arrived.

    This is the adapter boundary shared by stopped-volume and connected-guest
    acquisition. An adapter supplies the classic file's FinderInfo bytes and
    resource-fork bytes; this domain parser alone decides whether they form a
    usable custom Finder icon. Session selection, file transfer and mounted
    volumes therefore cannot grow competing icon rules.
    """
    info = finder_info(finder_info_raw)
    if info is None or not info["flags"] & FD_HAS_CUSTOM_ICON:
        return None
    suite = extract_custom_icon(resfork.ResourceFork(resource_fork_raw))
    if suite is None:
        return None
    return {"finder": info, "suite": suite}
