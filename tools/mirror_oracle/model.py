"""Declarative visual profiles and cases."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from .images import Rect


DATA_ROOT = Path(__file__).resolve().parent.parent / "mirror_oracle_data"


@dataclass(frozen=True)
class VisualProfile:
    id: str
    system_version: str
    visual_family: str
    width: int
    height: int
    depth: int
    theme: str
    asset_policy: str
    raw: dict[str, Any]


@dataclass(frozen=True)
class OracleCase:
    id: str
    profile: str
    title: str
    required_state: list[str]
    input_actions: list[str]
    regions: list[dict[str, Any]]
    masks: list[dict[str, Any]]
    render: dict[str, Any]
    raw: dict[str, Any]


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def load_profile(profile_id: str) -> VisualProfile:
    path = DATA_ROOT / "profiles" / f"{profile_id}.json"
    value = _load_json(path)
    screen = value.get("screen")
    if value.get("id") != profile_id or not isinstance(screen, dict):
        raise ValueError(f"visual profile identity or screen is invalid: {path}")
    profile = VisualProfile(
        id=profile_id,
        system_version=str(value.get("systemVersion", "")),
        visual_family=str(value.get("visualFamily", "")),
        width=int(screen.get("width", 0)),
        height=int(screen.get("height", 0)),
        depth=int(screen.get("depth", 0)),
        theme=str(value.get("theme", "")),
        asset_policy=str(value.get("assetPolicy", "")),
        raw=value,
    )
    if not all((profile.system_version, profile.visual_family, profile.width,
                profile.height, profile.depth, profile.theme, profile.asset_policy)):
        raise ValueError(f"visual profile is incomplete: {path}")
    return profile


def load_case(case_id: str) -> OracleCase:
    path = DATA_ROOT / "cases" / f"{case_id}.json"
    value = _load_json(path)
    if value.get("id") != case_id:
        raise ValueError(f"oracle case identity is invalid: {path}")
    for key in ("profile", "title", "requiredState", "regions", "masks", "render"):
        if key not in value:
            raise ValueError(f"oracle case lacks {key}: {path}")
    actions: list[str] = []
    sequence = value.get("inputSequence")
    if sequence is not None:
        if not isinstance(sequence, str) or not sequence:
            raise ValueError(f"oracle inputSequence must be text: {path}")
        sequence_path = DATA_ROOT / "input-sequences" / f"{sequence}.json"
        sequence_value = _load_json(sequence_path)
        if sequence_value.get("id") != sequence:
            raise ValueError(
                f"oracle input sequence identity is invalid: {sequence_path}")
        actions.extend(sequence_value.get("actions", []))
    actions.extend(value.get("inputActions", []))
    case = OracleCase(
        id=case_id,
        profile=str(value["profile"]),
        title=str(value["title"]),
        required_state=list(value["requiredState"]),
        input_actions=actions,
        regions=list(value["regions"]),
        masks=list(value["masks"]),
        render=dict(value["render"]),
        raw=value,
    )
    load_profile(case.profile)
    for action in case.input_actions:
        if not isinstance(action, str):
            raise ValueError(f"oracle input action must be text: {path}")
    return case


def list_cases() -> list[OracleCase]:
    return [load_case(path.stem) for path in sorted((DATA_ROOT / "cases").glob("*.json"))]


def list_profiles() -> list[VisualProfile]:
    return [load_profile(path.stem) for path in sorted((DATA_ROOT / "profiles").glob("*.json"))]


def _rect(value: Any, label: str) -> Rect:
    if not (isinstance(value, list) and len(value) == 4 and
            all(isinstance(part, int) for part in value)):
        raise ValueError(f"{label} must be [left, top, right, bottom]")
    return tuple(value)  # type: ignore[return-value]


def resolve_regions(case: OracleCase, scene: dict[str, Any] | None) -> list[tuple[str, Rect]]:
    resolved: list[tuple[str, Rect]] = []
    for item in case.regions:
        name = str(item.get("name", ""))
        if not name:
            raise ValueError(f"case {case.id} has an unnamed region")
        source = item.get("source", "screen")
        if source == "screen":
            rect = _rect(item.get("rect"), f"region {name}")
        elif source in ("frontWindow", "window"):
            if scene is None:
                raise ValueError(f"region {name} requires --scene")
            windows = scene.get("windows")
            if not isinstance(windows, list):
                raise ValueError("scene has no windows array")
            if source == "frontWindow":
                window = next((candidate for candidate in windows
                               if candidate.get("front") is True and
                               candidate.get("visible") is True), None)
            else:
                app = item.get("app")
                front = item.get("front")
                window = next((candidate for candidate in windows
                               if candidate.get("visible") is True and
                               (app is None or candidate.get("app") == app) and
                               (front is None or candidate.get("front") is front)), None)
            if window is None or not isinstance(window.get("rect"), dict):
                raise ValueError("scene has no visible front window")
            source_rect = window["rect"]
            inset = _rect(item.get("inset", [0, 0, 0, 0]), f"region {name} inset")
            rect = (
                int(source_rect["l"]) + inset[0],
                int(source_rect["t"]) + inset[1],
                int(source_rect["r"]) - inset[2],
                int(source_rect["b"]) - inset[3],
            )
        else:
            raise ValueError(f"region {name} has unsupported source {source}")
        resolved.append((name, rect))
    return resolved


def resolve_masks(case: OracleCase) -> list[Rect]:
    return [_rect(item.get("rect"), f"mask {item.get('name', '?')}") for item in case.masks]
