"""Expose the release feature catalog to pages and render derived tables."""

from __future__ import annotations

from pathlib import Path

import yaml


RELEASE_TABLE = "<!-- release-feature-table -->"
EXTENSION_MATRIX = "<!-- extension-feature-matrix -->"


def _load(config):
    root = Path(config.config_file_path).resolve().parent
    catalog = yaml.safe_load((root / "docs/feature-catalog.yaml").read_text())
    active_id = catalog["active_profile"]
    profile = dict(catalog["profiles"][active_id])
    profile["id"] = active_id
    resolved = {}
    for feature_id, feature in catalog["features"].items():
        item = dict(feature)
        item.update(profile["features"][feature_id])
        item["id"] = feature_id
        resolved[feature_id] = item
    profile["features"] = resolved
    catalog["active"] = profile
    return catalog


def on_config(config):
    catalog = _load(config)
    config.extra["feature_catalog"] = catalog
    return config


def _release_table(catalog) -> str:
    rows = [
        "| Product area | Alpha state | Runtime binding | Notes |",
        "|---|---|---|---|",
    ]
    for feature in catalog["active"]["features"].values():
        binding = feature["runtime_binding"]
        if feature.get("flag_key"):
            binding = f"Planned `{feature['flag_key']}` flag; not implemented"
        rows.append(
            f"| {feature['title']} | **{feature['state'].title()}** | "
            f"{binding} | {feature['note']} |"
        )
    return "\n".join(rows)


def _coverage_table(features) -> str:
    rows = [
        "| Feature | Without the Extension | Extension required? | Current status |",
        "|---|---|---|---|",
    ]
    for feature in features:
        required = "**Yes**" if feature["extension_required"] else "No"
        rows.append(
            f"| **{feature['title']}** | {feature['without_extension']} | "
            f"{required} | {feature['status']} |"
        )
    return "\n".join(rows)


def _feature_matrices(catalog) -> str:
    return "\n\n".join(
        (
            "### Application features",
            _coverage_table(catalog["module_feature_coverage"]),
            "### Extension-backed Mirror features",
            _coverage_table(catalog["extension_feature_coverage"]),
        )
    )


def on_page_markdown(markdown, page, config, files):
    catalog = config.extra["feature_catalog"]
    return markdown.replace(RELEASE_TABLE, _release_table(catalog)).replace(
        EXTENSION_MATRIX, _feature_matrices(catalog)
    )
