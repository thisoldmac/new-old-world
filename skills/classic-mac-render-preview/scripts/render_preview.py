#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

from classic_preview.contracts import load_scene, validate_scene
from classic_preview.render import render_scene


def main():
    parser = argparse.ArgumentParser(description="Render a capability-gated Classic Mac preview")
    parser.add_argument("scene")
    parser.add_argument("--output", required=True)
    parser.add_argument("--report")
    parser.add_argument("--normalized")
    args = parser.parse_args()
    scene_path = Path(args.scene)
    try:
        scene = load_scene(scene_path)
        normalized, report = validate_scene(scene, scene_path.parent)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"input error: {error}", file=sys.stderr)
        return 2
    if not report["valid"]:
        print(json.dumps(report, indent=2), file=sys.stderr)
        return 2
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    render_scene(normalized, report).save_png(output_path)
    report["output"] = {
        "path": str(output_path),
        "width": normalized["screen"]["width"],
        "height": normalized["screen"]["height"],
        "depth": normalized["screen"]["depth"],
        "format": "indexed-png",
    }
    report_text = json.dumps(report, indent=2) + "\n"
    if args.report:
        Path(args.report).write_text(report_text, encoding="utf-8")
    if args.normalized:
        Path(args.normalized).write_text(json.dumps(normalized, indent=2) + "\n", encoding="utf-8")
    print(f"rendered {output_path} ({report['output']['width']}x{report['output']['height']}x{report['output']['depth']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
