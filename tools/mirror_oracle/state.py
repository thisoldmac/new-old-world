"""Validation for attributable target-state observations."""

from __future__ import annotations

from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from .model import OracleCase, VisualProfile


STATE_SCHEMA = "now-mirror-oracle-state/v1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def state_proof_template(capture_receipt: Path, case: OracleCase,
                         profile: VisualProfile) -> dict[str, Any]:
    """Create an explicitly incomplete observation form for one capture.

    The capture receipt owns the volatile-mask digest. Copying that value by
    hand is both tedious and an easy way to attest to a different frame. The
    generated assertions remain unobserved, so this helper cannot turn an
    automated capture into human evidence by itself.
    """
    try:
        receipt = json.loads(capture_receipt.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(
            f"cannot read capture receipt {capture_receipt}: {error}"
        ) from error
    if not isinstance(receipt, dict) or receipt.get("kind") != "capture":
        raise ValueError("state template requires a mirror-oracle capture receipt")
    receipt_case = receipt.get("case")
    receipt_profile = receipt.get("profile")
    if not isinstance(receipt_case, dict) or receipt_case.get("id") != case.id:
        raise ValueError("capture receipt case does not match the requested case")
    if not isinstance(receipt_profile, dict) or receipt_profile.get("id") != profile.id:
        raise ValueError("capture receipt profile does not match the requested case")
    stability = receipt.get("stability")
    attempts = stability.get("attempts") if isinstance(stability, dict) else None
    if not isinstance(attempts, list) or not attempts:
        raise ValueError("capture receipt has no stable framebuffer attempt")
    last_attempt = attempts[-1]
    digest = (last_attempt.get("maskedFramebufferSha256")
              if isinstance(last_attempt, dict) else None)
    if not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise ValueError("capture receipt has no valid masked framebuffer digest")
    accepted = receipt.get("acceptedCapture")
    if not isinstance(accepted, dict):
        raise ValueError("capture receipt has no accepted capture")
    accepted_path = accepted.get("path")
    accepted_sha = accepted.get("sha256")
    if not isinstance(accepted_path, str) or not isinstance(accepted_sha, str):
        raise ValueError("capture receipt accepted capture is incomplete")
    return {
        "schema": STATE_SCHEMA,
        "case": case.id,
        "profile": profile.id,
        "observer": "",
        "observedAt": "",
        "maskedFramebufferSha256": digest,
        "referenceCapture": {
            "path": accepted_path,
            "sha256": accepted_sha,
        },
        "assertions": [{
            "requirement": requirement,
            "verdict": "unobserved",
            "evidence": "",
        } for requirement in case.required_state],
    }


def validate_state_proof(path: Path, case: OracleCase, profile: VisualProfile,
                         framebuffer_digest: str) -> dict[str, Any]:
    """Validate that an observation names this exact stable target state.

    The proof is deliberately coupled to the masked framebuffer digest rather
    than the BMP file hash: the case's clock mask may change between the frame
    an observer inspected and the consecutive frames the harness accepts.
    """
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read state proof {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("state proof must be a JSON object")
    if value.get("schema") != STATE_SCHEMA:
        raise ValueError(f"state proof must use {STATE_SCHEMA}")
    if value.get("case") != case.id or value.get("profile") != profile.id:
        raise ValueError("state proof case/profile does not match the capture")
    observer = value.get("observer")
    if not isinstance(observer, str) or not observer.strip():
        raise ValueError("state proof observer must be non-empty")
    observed_at = value.get("observedAt")
    if not isinstance(observed_at, str):
        raise ValueError("state proof observedAt must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("state proof observedAt must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError("state proof observedAt must include a timezone")

    expected_digest = value.get("maskedFramebufferSha256")
    if not isinstance(expected_digest, str) or not SHA256.fullmatch(expected_digest):
        raise ValueError("state proof maskedFramebufferSha256 must be lowercase SHA-256")
    if expected_digest != framebuffer_digest:
        raise ValueError(
            "state proof names a different masked framebuffer: "
            f"proof {expected_digest}, capture {framebuffer_digest}"
        )

    assertions = value.get("assertions")
    if not isinstance(assertions, list):
        raise ValueError("state proof assertions must be an array")
    by_requirement: dict[str, dict[str, Any]] = {}
    for assertion in assertions:
        if not isinstance(assertion, dict):
            raise ValueError("every state proof assertion must be an object")
        requirement = assertion.get("requirement")
        if not isinstance(requirement, str) or requirement in by_requirement:
            raise ValueError("state proof assertions must name each requirement once")
        if assertion.get("verdict") != "observed":
            raise ValueError(f"state proof did not observe required state: {requirement}")
        evidence = assertion.get("evidence")
        if not isinstance(evidence, str) or not evidence.strip():
            raise ValueError(f"state proof assertion has no evidence: {requirement}")
        by_requirement[requirement] = assertion
    if set(by_requirement) != set(case.required_state):
        missing = sorted(set(case.required_state) - set(by_requirement))
        extra = sorted(set(by_requirement) - set(case.required_state))
        raise ValueError(
            f"state proof assertions do not match requiredState; missing={missing}, extra={extra}"
        )

    return {
        "path": str(path),
        "sha256": _sha256(path),
        "schema": STATE_SCHEMA,
        "observer": observer,
        "observedAt": observed_at,
        "maskedFramebufferSha256": expected_digest,
        "assertions": [by_requirement[requirement]
                       for requirement in case.required_state],
    }
