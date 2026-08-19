#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

from classic_preview.contracts import audit_assets, load_scene


def main():
    parser = argparse.ArgumentParser(description="Audit Classic Mac preview asset provenance")
    parser.add_argument("scene")
    parser.add_argument("--report")
    args = parser.parse_args()
    scene_path = Path(args.scene)
    try:
        scene = load_scene(scene_path)
        errors, warnings, assets = audit_assets(scene, scene_path.parent)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors, warnings, assets = [{"code": "input", "message": str(error)}], [], []
    report = {"valid": not errors, "assets": assets, "errors": errors, "warnings": warnings}
    output = json.dumps(report, indent=2) + "\n"
    if args.report:
        Path(args.report).write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0 if report["valid"] else 2


if __name__ == "__main__":
    sys.exit(main())
