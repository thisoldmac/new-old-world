"""Stable capture, rendering, comparison, and evidence receipts."""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
from typing import Any

from . import SCHEMA_VERSION
from .images import compare as compare_images
from .images import load, masked_digest, pair, write_png
from .model import OracleCase, VisualProfile, resolve_masks, resolve_regions
from .state import validate_state_proof


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _json(path: Path, value: Any) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def repo_revision(repo: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"],
        text=True, capture_output=True, check=True,
    ).stdout.strip()


def stable_capture(backend, case: OracleCase, profile: VisualProfile, output: Path,
                   *, consecutive: int = 2, max_attempts: int = 8,
                   settle_seconds: float = 0.25, apply_input: bool = False,
                   state_proof: Path | None = None) -> dict:
    if consecutive < 2:
        raise ValueError("stable capture requires at least two consecutive matching frames")
    if max_attempts < consecutive:
        raise ValueError("max attempts must be at least the consecutive-frame requirement")
    output.mkdir(parents=True, exist_ok=False)
    samples = output / "samples"
    samples.mkdir()
    masks = resolve_masks(case)
    attempts: list[dict] = []
    prior = None
    run_length = 0
    accepted: Path | None = None
    started = _utc_now()
    input_applied = False
    failure: Exception | None = None
    proof = None
    try:
        if apply_input:
            if not case.input_actions:
                raise ValueError(f"case {case.id} has no validated input actions")
            # A transport failure can still leave a down transition delivered.
            # Arm cleanup before asking the backend to send the first action.
            input_applied = True
            backend.input(case.input_actions)
        for attempt in range(1, max_attempts + 1):
            capture = samples / f"frame-{attempt:02d}{backend.extension}"
            capture_started = time.time()
            backend.capture(capture)
            capture_ended = time.time()
            image = load(capture)
            if (image.width, image.height) != (profile.width, profile.height):
                raise ValueError(
                    f"capture is {image.width}x{image.height}; profile requires "
                    f"{profile.width}x{profile.height}"
                )
            digest = masked_digest(image, masks)
            run_length = run_length + 1 if digest == prior else 1
            attempts.append({
                "attempt": attempt,
                "path": str(capture),
                "sha256": _sha256(capture),
                "maskedFramebufferSha256": digest,
                "captureStartedAt": capture_started,
                "captureEndedAt": capture_ended,
                "matchingRunLength": run_length,
            })
            prior = digest
            if run_length >= consecutive:
                accepted = output / f"guest{backend.extension}"
                shutil.copy2(capture, accepted)
                break
            time.sleep(settle_seconds)
        if accepted is None:
            raise RuntimeError(
                f"framebuffer did not stabilize for {consecutive} consecutive reads "
                f"within {max_attempts} attempts"
            )
        if state_proof is not None:
            proof = validate_state_proof(
                state_proof, case, profile,
                attempts[-1]["maskedFramebufferSha256"],
            )
    except Exception as error:  # retain an attributable failed attempt
        failure = error
    finally:
        if input_applied:
            try:
                backend.cleanup_input()
            except Exception as cleanup_error:
                if failure is None:
                    failure = cleanup_error

    if failure is not None:
        _json(output / "capture-failure.json", {
            "schema": SCHEMA_VERSION,
            "kind": "capture-failure",
            "createdAt": _utc_now(),
            "startedAt": started,
            "case": case.raw,
            "profile": profile.raw,
            "backend": backend.name,
            "error": str(failure),
            "inputCleanupAttempted": input_applied,
            "stability": {
                "requiredConsecutiveFrames": consecutive,
                "maximumAttempts": max_attempts,
                "volatileMasks": case.masks,
                "attempts": attempts,
            },
        })
        raise failure

    receipt = {
        "schema": SCHEMA_VERSION,
        "kind": "capture",
        "createdAt": _utc_now(),
        "startedAt": started,
        "case": case.raw,
        "profile": profile.raw,
        "nowRevision": repo_revision(backend.repo),
        "backend": backend.name,
        "backendProvenance": backend.provenance(),
        "requiredState": case.required_state,
        "stateProof": proof,
        "evidenceStatus": "state-proof-validated" if proof else "reference-only",
        "inputActionsApplied": case.input_actions if input_applied else [],
        "stability": {
            "requiredConsecutiveFrames": consecutive,
            "maximumAttempts": max_attempts,
            "volatileMasks": case.masks,
            "attempts": attempts,
        },
        "acceptedCapture": {"path": str(accepted), "sha256": _sha256(accepted)},
    }
    _json(output / "capture.json", receipt)
    return receipt


def render_scene(repo: Path, case: OracleCase, scene: Path, output: Path,
                 *, run=subprocess.run) -> dict:
    if output.exists():
        raise ValueError(f"render destination already exists: {output}")
    command = [
        "swift", "run", "--package-path", str(repo / "now-host" / "Packages" / "MirrorKit"),
        "mirror-render", "--scene", str(scene), "--output", str(output),
    ]
    if case.render.get("openMenu") is not None:
        command += ["--open-menu", str(case.render["openMenu"])]
    if case.render.get("hoveredItem") is not None:
        command += ["--hovered-item", str(case.render["hoveredItem"])]
    if case.render.get("finderView") is not None:
        command += ["--finder-view", str(case.render["finderView"])]
    if case.render.get("finderSelectedName") is not None:
        command += ["--finder-selected-name",
                    str(case.render["finderSelectedName"])]
    if case.render.get("finderMetadata") is not None:
        command += ["--finder-metadata-json",
                    json.dumps(case.render["finderMetadata"],
                               separators=(",", ":"), sort_keys=True)]
    if case.render.get("finderAvailableBytes") is not None:
        command += ["--finder-available-bytes",
                    str(case.render["finderAvailableBytes"])]
    if case.render.get("appleMenuProfile") is not None:
        command += ["--apple-menu-profile",
                    str(case.render["appleMenuProfile"])]
    completed = run(command, text=True, capture_output=True, check=True)
    receipt = {
        "schema": SCHEMA_VERSION,
        "kind": "render",
        "createdAt": _utc_now(),
        "case": case.id,
        "nowRevision": repo_revision(repo),
        "scene": {"path": str(scene), "sha256": _sha256(scene)},
        "render": {"path": str(output), "sha256": _sha256(output)},
        "command": command,
        "stdout": completed.stdout.splitlines(),
        "stderr": completed.stderr.splitlines(),
    }
    _json(output.with_suffix(".render.json"), receipt)
    return receipt


def compare(case: OracleCase, profile: VisualProfile, guest: Path, render: Path,
            output: Path, scene: Path | None = None) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    guest_image = load(guest)
    render_image = load(render)
    if (guest_image.width, guest_image.height) != (profile.width, profile.height):
        raise ValueError("guest image dimensions do not match the visual profile")
    scene_value = json.loads(scene.read_text()) if scene else None
    regions = resolve_regions(case, scene_value)
    masks = resolve_masks(case)
    reports, heatmap = compare_images(guest_image, render_image, regions, masks)
    write_png(pair(guest_image, render_image), output / "pair.png")
    write_png(heatmap, output / "diff.png")
    changed = sum(report["changedPixels"] for report in reports)
    receipt = {
        "schema": SCHEMA_VERSION,
        "kind": "comparison",
        "createdAt": _utc_now(),
        "case": case.id,
        "profile": profile.id,
        "guest": {"path": str(guest), "sha256": _sha256(guest)},
        "render": {"path": str(render), "sha256": _sha256(render)},
        "scene": {"path": str(scene), "sha256": _sha256(scene)} if scene else None,
        "masks": case.masks,
        "regions": reports,
        "verdict": "match" if changed == 0 else "mismatch",
        "artifacts": {"pair": str(output / "pair.png"), "diff": str(output / "diff.png")},
    }
    _json(output / "comparison.json", receipt)
    return receipt
