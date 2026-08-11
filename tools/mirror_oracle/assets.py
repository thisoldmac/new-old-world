"""Derive private, profile-scoped render assets from attributed oracle pixels."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
from typing import Any

from .images import load, transparent_crop, write_png
from .model import VisualProfile


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_json(path: Path, value: Any) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def _link_or_copy(source: str, destination: str) -> str:
    try:
        os.link(source, destination)
        return destination
    except OSError:
        return shutil.copy2(source, destination)


def _rect(value: Any, label: str) -> tuple[int, int, int, int]:
    if not (isinstance(value, list) and len(value) == 4 and
            all(isinstance(part, int) for part in value)):
        raise ValueError(f"profile {label}.rect must be four integers")
    return tuple(value)  # type: ignore[return-value]


def _rgb(value: Any, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or len(value.removeprefix("#")) != 6:
        raise ValueError(f"profile {label}.background must be #RRGGBB")
    try:
        integer = int(value.removeprefix("#"), 16)
    except ValueError as error:
        raise ValueError(
            f"profile {label}.background must be #RRGGBB"
        ) from error
    return integer >> 16, (integer >> 8) & 0xFF, integer & 0xFF


def _extract_asset(source, specification: Any, label: str, output: Path) -> dict:
    if not isinstance(specification, dict):
        raise ValueError(f"profile {label} extraction contract must be an object")
    rect = _rect(specification.get("rect"), label)
    background = _rgb(specification.get("background"), label)
    write_png(transparent_crop(source, rect, background), output)
    return {
        "path": str(output.relative_to(output.parent.parent)),
        "rect": list(rect),
        "transparentRGB": "#%02X%02X%02X" % background,
        "sha256": _sha256(output),
    }


def extract_chrome(profile: VisualProfile, guest: Path, base_assets: Path,
                   output: Path) -> dict[str, Any]:
    """Clone a complete pack and add profile-specific oracle chrome.

    The base is never mutated. Files are hard-linked where possible and
    copied across filesystems, while `manifest.json` is atomically replaced
    last so AssetPack cannot discover an incomplete destination.
    """
    source_manifest = base_assets / "manifest.json"
    if not source_manifest.is_file():
        raise ValueError(f"base asset pack has no manifest.json: {base_assets}")
    if output.exists():
        raise ValueError(f"asset-pack destination already exists: {output}")
    chrome = profile.raw.get("chromeAssets", {}).get("appleMenu", {})
    if not isinstance(chrome, dict):
        raise ValueError(f"profile {profile.id} has no Apple-menu extraction contract")
    app_icons = profile.raw.get("chromeAssets", {}).get(
        "applicationMenuIcons", {})
    if not isinstance(app_icons, dict):
        raise ValueError("profile chromeAssets.applicationMenuIcons must be an object")
    source = load(guest)
    if (source.width, source.height) != (profile.width, profile.height):
        raise ValueError(
            f"oracle capture is {source.width}x{source.height}; profile requires "
            f"{profile.width}x{profile.height}"
        )

    try:
        shutil.copytree(base_assets, output, copy_function=_link_or_copy)
        # It was copied only so the base could be validated. Remove it before
        # writing any derived content: a half-built pack must not look valid.
        (output / "manifest.json").unlink()
        chrome_dir = output / "chrome"
        chrome_dir.mkdir(exist_ok=True)
        apple_path = chrome_dir / "apple-menu.png"
        apple = _extract_asset(source, chrome, "chromeAssets.appleMenu", apple_path)
        applications: dict[str, dict] = {}
        for signature, specification in sorted(app_icons.items()):
            if not (1 <= len(signature) <= 4 and all(
                    32 < ord(character) < 127 and character not in "/\\:"
                    for character in signature)):
                raise ValueError(f"invalid application-menu icon signature: {signature!r}")
            path = chrome_dir / f"application-menu-{signature}.png"
            applications[signature] = _extract_asset(
                source, specification,
                f"chromeAssets.applicationMenuIcons.{signature}", path,
            )
        receipt = {
            "schema": "now-mirror-oracle-assets/v1",
            "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "profile": profile.id,
            "sourceCapture": {"path": str(guest), "sha256": _sha256(guest)},
            "baseAssets": {
                "path": str(base_assets), "manifestSha256": _sha256(source_manifest),
            },
            "appleMenu": apple,
            "applicationMenuIcons": applications,
        }
        _write_json(chrome_dir / "provenance.json", receipt)
        manifest = json.loads(source_manifest.read_text())
        manifest["pack"] = output.parent.name if output.name == "Resources" else output.name
        manifest["oracleChrome"] = receipt
        _write_json(output / "manifest.json", manifest)
        return receipt
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        raise
