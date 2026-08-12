"""Expose module maturity and future domain metadata to rendered pages."""

from pathlib import Path

import yaml


def on_config(config):
    root = Path(config.config_file_path).resolve().parent
    manifest = yaml.safe_load((root / "docs/module-manifest.yaml").read_text())
    config.extra["module_taxonomy"] = {
        row["id"]: row for row in manifest["modules"]
    }
    return config
