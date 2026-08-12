"""Derive private, profile-scoped render assets from attributed oracle pixels."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
from typing import Any

from .images import Image, load, transparent_crop, write_png
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


def _relative_asset(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"profile {label}.asset must be a relative path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"profile {label}.asset must stay inside the asset pack")
    return path


def _capture_provenance(profile: VisualProfile, guest: Path,
                        receipt_path: Path) -> dict[str, Any]:
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(
            f"cannot read capture receipt {receipt_path}: {error}"
        ) from error
    if not isinstance(receipt, dict) or receipt.get("kind") != "capture":
        raise ValueError("chrome extraction requires a mirror-oracle capture receipt")
    receipt_profile = receipt.get("profile")
    if not isinstance(receipt_profile, dict) \
            or receipt_profile.get("id") != profile.id:
        raise ValueError("capture receipt profile does not match chrome profile")
    accepted = receipt.get("acceptedCapture")
    if not isinstance(accepted, dict):
        raise ValueError("capture receipt has no accepted capture")
    expected = accepted.get("sha256")
    actual = _sha256(guest)
    if expected != actual:
        raise ValueError(
            "chrome source does not match the capture receipt: "
            f"receipt {expected}, file {actual}"
        )
    return {
        "path": str(receipt_path),
        "sha256": _sha256(receipt_path),
        "case": receipt.get("case", {}).get("id")
            if isinstance(receipt.get("case"), dict) else None,
        "evidenceStatus": receipt.get("evidenceStatus"),
    }


def _prove_desktop_pattern(profile: VisualProfile, source, output: Path,
                           specification: Any) -> dict[str, Any]:
    label = "desktopPattern"
    if not isinstance(specification, dict):
        raise ValueError(f"profile {label} extraction contract must be an object")
    name = specification.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError(f"profile {label}.name must be a non-empty string")
    asset = _relative_asset(specification.get("asset"), label)
    tile_path = output / asset
    if not tile_path.is_file():
        raise ValueError(f"profile {label}.asset is absent from the base pack: {asset}")
    origin = specification.get("tileOrigin")
    if not (isinstance(origin, list) and len(origin) == 2 and
            all(isinstance(part, int) for part in origin)):
        raise ValueError(f"profile {label}.tileOrigin must be two integers")
    regions = specification.get("proofRegions")
    if not isinstance(regions, list) or not regions:
        raise ValueError(f"profile {label}.proofRegions must be non-empty")

    tile = load(tile_path)
    proved = 0
    for index, value in enumerate(regions):
        rect = _rect(value, f"{label}.proofRegions[{index}]")
        left, top, right, bottom = rect
        # Validate bounds before indexing so a bad profile names its own
        # rectangle instead of leaking an image-array error.
        if not (0 <= left < right <= source.width and
                0 <= top < bottom <= source.height):
            raise ValueError(
                f"profile {label}.proofRegions[{index}] is outside "
                f"{source.width}x{source.height}"
            )
        for y in range(top, bottom):
            for x in range(left, right):
                expected = tile.pixel(
                    (x - origin[0]) % tile.width,
                    (y - origin[1]) % tile.height,
                )[:3]
                actual = source.pixel(x, y)[:3]
                if actual != expected:
                    raise ValueError(
                        f"profile {label} does not match {asset} at ({x},{y}): "
                        f"capture {actual}, tile {expected}"
                    )
                proved += 1
    return {
        "name": name,
        "asset": str(asset),
        "tileOrigin": origin,
        "proofRegions": regions,
        "provedPixels": proved,
        "verdict": "exact",
    }


def _baseline_icon(tile: Image, tile_origin: list[int], rect: tuple[int, int, int, int],
                   icon: Image) -> Image:
    """Compose one extracted icon over its measured repeating desktop."""
    left, top, right, bottom = rect
    width, height = right - left, bottom - top
    if (icon.width, icon.height) != (width, height):
        raise ValueError(
            f"alias badge proof icon is {icon.width}x{icon.height}; "
            f"capture rectangle is {width}x{height}"
        )
    rgba = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            background = tile.pixel(
                (left + x - tile_origin[0]) % tile.width,
                (top + y - tile_origin[1]) % tile.height,
            )
            foreground = icon.pixel(x, y)
            alpha = foreground[3]
            target = (y * width + x) * 4
            for channel in range(3):
                rgba[target + channel] = (
                    foreground[channel] * alpha
                    + background[channel] * (255 - alpha) + 127
                ) // 255
            rgba[target + 3] = 255
    return Image(width, height, bytes(rgba))


def _derive_alias_badge(source: Image, asset_root: Path,
                        desktop: dict[str, Any] | None,
                        specification: Any) -> dict[str, Any] | None:
    """Derive Finder's alias transform from independent file-icon proofs.

    The captured pixels are accepted only where multiple extracted source
    icons independently leave the same opaque residual. This makes the output
    a profile-scoped Finder transform, not a crop of any one desktop item.
    """
    if specification is None:
        return None
    label = "chromeAssets.aliasBadge"
    if not isinstance(specification, dict):
        raise ValueError(f"profile {label} extraction contract must be an object")
    proofs = specification.get("proofs")
    if not isinstance(proofs, list) or len(proofs) < 2:
        raise ValueError(f"profile {label}.proofs must contain at least two items")
    if desktop is None:
        raise ValueError(f"profile {label} requires a proved desktopPattern")

    manifest_path = asset_root / "fileicons" / "manifest.json"
    try:
        file_manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read file-icon manifest: {error}") from error
    items = file_manifest.get("items") if isinstance(file_manifest, dict) else None
    if not isinstance(items, dict):
        raise ValueError("file-icon manifest has no items object")

    tile = load(asset_root / desktop["asset"])
    tile_origin = desktop["tileOrigin"]
    evidence: list[dict[str, Any]] = []
    targets: list[list[tuple[int, int, int]]] = []
    changed_sets: list[set[int]] = []
    dimensions: tuple[int, int] | None = None
    for index, proof in enumerate(proofs):
        proof_label = f"{label}.proofs[{index}]"
        if not isinstance(proof, dict):
            raise ValueError(f"profile {proof_label} must be an object")
        item_path = proof.get("path")
        if not isinstance(item_path, str) or not item_path:
            raise ValueError(f"profile {proof_label}.path must be non-empty")
        row = items.get(item_path)
        asset_value = row.get("large") if isinstance(row, dict) else None
        asset = _relative_asset(asset_value, proof_label)
        icon_path = asset_root / asset
        if not icon_path.is_file():
            raise ValueError(f"profile {proof_label} asset is absent: {asset}")
        rect = _rect(proof.get("rect"), proof_label)
        left, top, right, bottom = rect
        if not (0 <= left < right <= source.width and
                0 <= top < bottom <= source.height):
            raise ValueError(f"profile {proof_label}.rect is outside the capture")
        size = right - left, bottom - top
        if dimensions is None:
            dimensions = size
        elif dimensions != size:
            raise ValueError(f"profile {label} proof rectangles must have one size")
        baseline = _baseline_icon(tile, tile_origin, rect, load(icon_path))
        target_pixels: list[tuple[int, int, int]] = []
        changed: set[int] = set()
        for y in range(size[1]):
            for x in range(size[0]):
                pixel = source.pixel(left + x, top + y)[:3]
                flat = y * size[0] + x
                target_pixels.append(pixel)
                if pixel != baseline.pixel(x, y)[:3]:
                    changed.add(flat)
        if not changed:
            raise ValueError(f"profile {proof_label} has no residual pixels")
        targets.append(target_pixels)
        changed_sets.append(changed)
        evidence.append({
            "path": item_path,
            "rect": list(rect),
            "baseAsset": str(asset),
            "baseAssetSha256": _sha256(icon_path),
            "changedPixels": len(changed),
        })

    assert dimensions is not None
    union = set().union(*changed_sets)
    common = set.intersection(*changed_sets)
    rgba = bytearray(dimensions[0] * dimensions[1] * 4)
    for flat in sorted(union):
        values = {pixels[flat] for pixels in targets}
        if len(values) != 1:
            x, y = flat % dimensions[0], flat // dimensions[0]
            raise ValueError(
                f"profile {label} residual disagrees at ({x},{y}): {sorted(values)}"
            )
        if sum(flat in changed for changed in changed_sets) < 2:
            x, y = flat % dimensions[0], flat // dimensions[0]
            raise ValueError(
                f"profile {label} residual at ({x},{y}) has only one proof"
            )
        target = flat * 4
        rgba[target : target + 3] = bytes(values.pop())
        rgba[target + 3] = 255
    badge = Image(dimensions[0], dimensions[1], bytes(rgba))
    output = asset_root / "chrome" / "alias-badge.png"
    write_png(badge, output)
    xs = [flat % dimensions[0] for flat in union]
    ys = [flat // dimensions[0] for flat in union]
    return {
        "path": str(output.relative_to(asset_root)),
        "sha256": _sha256(output),
        "proofs": evidence,
        "provedPixels": sum(len(changed) for changed in changed_sets),
        "commonPixels": len(common),
        "outputPixels": len(union),
        "opaqueBounds": [min(xs), min(ys), max(xs) + 1, max(ys) + 1],
        "verdict": "cross-proof-exact",
    }


def extract_chrome(profile: VisualProfile, guest: Path,
                   capture_receipt: Path, base_assets: Path,
                   output: Path) -> dict[str, Any]:
    """Clone a complete pack and add profile-specific oracle chrome.

    The base is never mutated. Files are hard-linked where possible and
    copied across filesystems, while `manifest.json` is atomically replaced
    last so AssetPack cannot discover an incomplete destination.
    """
    source_manifest = base_assets / "manifest.json"
    if not source_manifest.is_file():
        raise ValueError(f"base asset pack has no manifest.json: {base_assets}")
    manifest = json.loads(source_manifest.read_text())
    if not isinstance(manifest, dict):
        raise ValueError("base asset-pack manifest must be an object")
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
    capture_provenance = _capture_provenance(
        profile, guest, capture_receipt,
    )
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
        desktop_specification = profile.raw.get("desktopPattern")
        desktop = (_prove_desktop_pattern(
            profile, source, output, desktop_specification,
        ) if desktop_specification is not None else None)
        alias_badge = _derive_alias_badge(
            source, output, desktop,
            profile.raw.get("chromeAssets", {}).get("aliasBadge"),
        )
        receipt = {
            "schema": "now-mirror-oracle-assets/v1",
            "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "profile": profile.id,
            "sourceCapture": {"path": str(guest), "sha256": _sha256(guest)},
            "captureReceipt": capture_provenance,
            "baseAssets": {
                "path": str(base_assets), "manifestSha256": _sha256(source_manifest),
            },
            "appleMenu": apple,
            "applicationMenuIcons": applications,
            "aliasBadge": alias_badge,
            "desktopPattern": desktop,
        }
        _write_json(chrome_dir / "provenance.json", receipt)
        manifest["pack"] = output.parent.name if output.name == "Resources" else output.name
        manifest["oracleChrome"] = receipt
        if desktop is not None:
            manifest["desktop"] = {
                "kind": "pattern",
                "name": desktop["name"],
                "file": desktop["asset"],
                "tileOrigin": desktop["tileOrigin"],
                "source": f"visual profile {profile.id}",
                "confidence": (
                    f"exactly matched {desktop['provedPixels']} native "
                    "framebuffer pixels in profile-declared proof regions"
                ),
                "proof": desktop,
            }
        _write_json(output / "manifest.json", manifest)
        return receipt
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        raise
