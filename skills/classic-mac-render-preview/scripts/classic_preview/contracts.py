import copy
import json
from pathlib import Path

from . import VERSION
from .profiles import FALLBACKS, PROFILES, component_primitive, component_status

ASSET_STATUSES = {
    "generated-original",
    "bundled-cleared",
    "runtime-system-rendered",
    "local-user-supplied",
    "reference-only",
    "excluded",
}
RENDERABLE_ASSET_STATUSES = {"generated-original", "bundled-cleared", "local-user-supplied"}
COMPONENT_TYPES = {
    "label", "separator", "button", "checkbox", "radio", "field", "group",
    "list", "scrollbar", "tabs", "progress", "databrowser", "bevel_button",
    "placard", "popup", "slider", "little_arrows", "disclosure", "image_well",
    "system_icon", "text_area", "icon",
    "quickdraw_canvas",
}
CHROME_MODELS = {"target-native", "classic-monochrome"}
APPLICATION_BASES = {
    "verified-implementation",
    "evidence-backed-prototype",
    "design-concept",
}


def load_scene(path):
    with Path(path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("scene root must be a JSON object")
    return value


def audit_assets(scene, base_dir=None):
    errors, warnings, results = [], [], []
    assets = scene.get("assets", [])
    if not isinstance(assets, list):
        return [{"code": "assets-not-array", "message": "assets must be an array"}], [], []
    seen = set()
    base = Path(base_dir or ".")
    for index, asset in enumerate(assets):
        if not isinstance(asset, dict):
            errors.append({"code": "asset-not-object", "message": f"asset {index} must be an object"})
            continue
        asset_id = asset.get("id")
        status = asset.get("status")
        item = {"id": asset_id, "status": status, "renderable": False}
        if not asset_id or asset_id in seen:
            errors.append({"code": "asset-id", "message": f"asset {index} needs a unique id"})
        else:
            seen.add(asset_id)
        if status not in ASSET_STATUSES:
            errors.append({"code": "asset-status", "message": f"asset {asset_id or index} has invalid status"})
        elif status in RENDERABLE_ASSET_STATUSES:
            item["renderable"] = status == "generated-original"
            if status != "generated-original":
                warnings.append({
                    "code": "external-raster-unsupported",
                    "message": f"asset {asset_id} passed provenance gating but the renderer does not composite external rasters",
                })
            if status == "local-user-supplied":
                supplied = asset.get("path")
                if not supplied or not (base / supplied).exists():
                    errors.append({"code": "asset-path", "message": f"asset {asset_id} local path is missing"})
        if not asset.get("source") or not asset.get("rights"):
            errors.append({"code": "asset-provenance", "message": f"asset {asset_id or index} needs source and rights"})
        results.append(item)
    return errors, warnings, results


def validate_scene(scene, base_dir=None):
    normalized = copy.deepcopy(scene)
    errors, warnings, component_results, fallbacks = [], [], [], []
    application_basis = scene.get("application_basis", "design-concept")
    if application_basis not in APPLICATION_BASES:
        errors.append({
            "code": "application-basis",
            "message": (
                "application_basis must be one of "
                + ", ".join(sorted(APPLICATION_BASES))
            ),
        })
        application_basis = "design-concept"
    normalized["application_basis"] = application_basis
    target = scene.get("target")
    if target not in PROFILES:
        errors.append({"code": "target", "message": f"target must be one of {', '.join(PROFILES)}"})
        profile = None
    else:
        profile = copy.deepcopy(PROFILES[target])

    requested_presentation = scene.get("presentation", {})
    if not isinstance(requested_presentation, dict):
        errors.append({"code": "presentation", "message": "presentation must be an object"})
        requested_presentation = {}
    requested_chrome = requested_presentation.get("chrome", "target-native")
    if requested_chrome not in CHROME_MODELS:
        errors.append({
            "code": "chrome",
            "message": f"presentation.chrome must be one of {', '.join(sorted(CHROME_MODELS))}",
        })
        requested_chrome = "target-native"
    resolved_chrome = profile["chrome_model"] if profile and requested_chrome == "target-native" else requested_chrome
    intentional_override = bool(profile and resolved_chrome != profile["chrome_model"])
    if intentional_override:
        warnings.append({
            "code": "intentional-era-override",
            "message": (
                f"{target} normally uses {profile['chrome_model']}; "
                f"rendering explicit {resolved_chrome} chrome without changing the API target"
            ),
        })
    normalized["presentation"] = {**requested_presentation, "chrome": requested_chrome}

    if profile:
        supplied_screen = scene.get("screen", {})
        if not isinstance(supplied_screen, dict):
            errors.append({"code": "screen", "message": "screen must be an object"})
            supplied_screen = {}
        screen = {**profile["screen"], **supplied_screen}
        if target == "system6-compact" and screen != profile["screen"]:
            errors.append({"code": "compact-screen", "message": "system6-compact is fixed at 512x342x1"})
        if screen.get("width", 0) < 512 or screen.get("height", 0) < 342:
            errors.append({"code": "screen-size", "message": "screen must be at least 512x342"})
        if screen.get("depth") not in profile["allowed_depths"]:
            errors.append({"code": "screen-depth", "message": "depth is not allowed by target"})
        normalized["screen"] = screen
        profile["screen"] = screen

    window = scene.get("window")
    if not isinstance(window, dict):
        errors.append({"code": "window", "message": "window must be an object"})
    else:
        required = ("x", "y", "width", "height", "title")
        for key in required:
            if key not in window:
                errors.append({"code": "window-field", "message": f"window needs {key}"})
        if profile and all(isinstance(window.get(k), int) for k in ("x", "y", "width", "height")):
            s = profile["screen"]
            if window["y"] < 20 or window["x"] < 0 or window["x"] + window["width"] > s["width"] or window["y"] + window["height"] > s["height"]:
                errors.append({"code": "window-bounds", "message": "window must fit below the menu bar"})

    components = scene.get("components", [])
    if not isinstance(components, list):
        errors.append({"code": "components", "message": "components must be an array"})
        components = []
    component_by_id = {
        component.get("id"): (index, component)
        for index, component in enumerate(components)
        if isinstance(component, dict) and component.get("id")
    }
    seen = set()
    for index, component in enumerate(components):
        if not isinstance(component, dict):
            errors.append({"code": "component-object", "message": f"component {index} must be an object"})
            continue
        component_id = component.get("id")
        kind = component.get("type")
        if not component_id or component_id in seen:
            errors.append({"code": "component-id", "message": f"component {index} needs a unique id"})
        else:
            seen.add(component_id)
        if kind not in COMPONENT_TYPES:
            errors.append({"code": "component-type", "message": f"component {component_id or index} has unsupported type {kind}"})
            continue
        if kind in {"popup", "tabs", "list", "databrowser"} and not isinstance(component.get("items", []), list):
            errors.append({"code": "component-items", "message": f"component {component_id} items must be an array"})
        if kind == "text_area" and not isinstance(component.get("lines", []), list):
            errors.append({"code": "component-lines", "message": f"component {component_id} lines must be an array"})
        if target == "platinum-carbonlib" and kind == "tabs":
            pane_for = component.get("pane_for")
            tab_height = component.get("height")
            if not isinstance(tab_height, int) or tab_height < 60:
                errors.append({
                    "code": "tab-pane",
                    "message": (
                        f"component {component_id} must render a connected "
                        "Carbon tab pane at least 60 pixels high"
                    ),
                })
            if not isinstance(pane_for, list) or not pane_for:
                errors.append({
                    "code": "tab-pane-for",
                    "message": (
                        f"component {component_id} needs a nonempty pane_for "
                        "list; floating Carbon tab strips are not valid"
                    ),
                })
            else:
                tab_keys = ("x", "y", "width", "height")
                tab_has_rect = all(
                    isinstance(component.get(key), int) for key in tab_keys
                )
                for child_id in pane_for:
                    child_entry = component_by_id.get(child_id)
                    if child_entry is None:
                        errors.append({
                            "code": "tab-pane-child",
                            "message": (
                                f"component {component_id} references unknown "
                                f"pane child {child_id}"
                            ),
                        })
                        continue
                    child_index, child = child_entry
                    if child_index <= index:
                        errors.append({
                            "code": "tab-pane-order",
                            "message": (
                                f"pane child {child_id} must follow tab "
                                f"component {component_id}"
                            ),
                        })
                    child_has_rect = all(
                        isinstance(child.get(key), int) for key in tab_keys
                    )
                    if tab_has_rect and child_has_rect:
                        inside = (
                            child["x"] >= component["x"] + 2
                            and child["y"] >= component["y"] + 18
                            and child["x"] + child["width"]
                            <= component["x"] + component["width"] - 2
                            and child["y"] + child["height"]
                            <= component["y"] + component["height"] - 2
                        )
                        if not inside:
                            errors.append({
                                "code": "tab-pane-bounds",
                                "message": (
                                    f"pane child {child_id} must fit inside "
                                    f"tab component {component_id}"
                                ),
                            })
        if kind in {"slider", "little_arrows"}:
            minimum = component.get("min", 0)
            maximum = component.get("max", 100)
            value = component.get("value", minimum)
            if not all(isinstance(item, int) for item in (minimum, maximum, value)) or minimum >= maximum or not minimum <= value <= maximum:
                errors.append({"code": "component-range", "message": f"component {component_id} needs integer min < max and value in range"})
        for key in ("x", "y"):
            if not isinstance(component.get(key), int):
                errors.append({"code": "component-position", "message": f"component {component_id} needs integer {key}"})
        if isinstance(window, dict) and all(isinstance(component.get(k), int) for k in ("x", "y")):
            default_width = 100
            default_height = 7 if kind == "label" else 18
            component_width = component.get("width", default_width)
            component_height = component.get("height", default_height)
            if not isinstance(component_width, int) or not isinstance(component_height, int) or component_width <= 0 or component_height <= 0:
                errors.append({"code": "component-size", "message": f"component {component_id} needs positive integer dimensions"})
            elif (
                component["x"] < 0 or component["y"] < 0
                or component["x"] + component_width > window.get("width", 0) - 2
                or component["y"] + component_height > window.get("height", 0) - 21
            ):
                errors.append({"code": "component-bounds", "message": f"component {component_id} does not fit the window content area"})
        status = component_status(target, kind) if profile else "unresolved"
        fallback = component.get("fallback")
        if fallback:
            if fallback not in FALLBACKS.get(kind, set()):
                errors.append({"code": "fallback", "message": f"component {component_id} has invalid fallback {fallback}"})
            else:
                status = "fallback-used"
                fallbacks.append({"id": component_id, "from": kind, "to": fallback})
        elif status == "unsupported":
            errors.append({"code": "unsupported", "message": f"component {component_id} ({kind}) is unsupported on {target}"})
        elif status == "custom-required" and not component.get("allow_custom"):
            errors.append({"code": "custom-not-approved", "message": f"component {component_id} ({kind}) requires allow_custom or fallback"})
        effective_type = fallback if status == "fallback-used" else kind
        primitive = component_primitive(target, effective_type) if profile else "unresolved"
        if target == "platinum-carbonlib" and kind == "placard" and component.get("text"):
            if component.get("label_mode") != "adjacent-static-text":
                errors.append({
                    "code": "placard-label-route",
                    "message": (
                        f"component {component_id} needs "
                        "label_mode adjacent-static-text because "
                        "CreatePlacardControl does not draw the label"
                    ),
                })
            else:
                primitive += " + CreateStaticTextControl"
        component_results.append({
            "id": component_id,
            "type": kind,
            "status": status,
            "primitive": primitive,
        })

    asset_errors, asset_warnings, asset_results = audit_assets(scene, base_dir)
    errors.extend(asset_errors)
    warnings.extend(asset_warnings)
    report = {
        "renderer": {"name": "classic-mac-render-preview", "version": VERSION},
        "preview_status": "measured-preview",
        "application_basis": application_basis,
        "target": target,
        "profile": profile,
        "presentation": {
            "requested_chrome": requested_chrome,
            "resolved_chrome": resolved_chrome,
            "intentional_override": intentional_override,
            "chrome_routes": profile.get("chrome_routes", []) if profile else [],
        },
        "calibration": profile.get("calibration") if profile else None,
        "components": component_results,
        "target_facilities": (
            (profile.get("chrome_routes", []) if profile else [])
            + list(dict.fromkeys(item["primitive"] for item in component_results))
        ),
        "fallbacks": fallbacks,
        "assets": asset_results,
        "errors": errors,
        "warnings": warnings,
        "valid": not errors,
    }
    return normalized, report
