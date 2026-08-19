#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

from classic_preview.contracts import load_scene, validate_scene


def main():
    parser = argparse.ArgumentParser(description="Validate a capability-gated Classic Mac preview scene")
    parser.add_argument("scene")
    parser.add_argument("--report")
    parser.add_argument("--normalized")
    args = parser.parse_args()
    scene_path = Path(args.scene)
    try:
        scene = load_scene(scene_path)
        normalized, report = validate_scene(scene, scene_path.parent)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"valid": False, "errors": [{"code": "input", "message": str(error)}]}, indent=2))
        return 2
    output = json.dumps(report, indent=2) + "\n"
    if args.report:
        Path(args.report).write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    if args.normalized:
        Path(args.normalized).write_text(json.dumps(normalized, indent=2) + "\n", encoding="utf-8")
    return 0 if report["valid"] else 2


if __name__ == "__main__":
    sys.exit(main())
