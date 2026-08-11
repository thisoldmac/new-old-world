#!/usr/bin/env python3
"""Capture the scene fixture the host's IR gates read, from a live guest.

    scripts/probes/capture-scene-fixture.py --port 5251

`now-host/Tests/HostTests/Fixtures/now-scene-ir-v1.json` is the document
three host gates parse, draw and hit-test. Its whole value is that a guest
actually emitted it, so it is refreshed by running this against a machine
- never by editing the file until a test passes, which would leave a
fixture that describes nothing.

It puts the machine into the state the gates need before it asks:

  - the Finder in front, so `menubar` is a foreign application's;
  - a folder window open, so there is a window with REAL scrollbars and
    a live range (About This Computer's bars are memory graphs, and a
    control whose min==max exercises no scrollbar geometry at all);
  - About This Computer open, for a second foreign window.

A capture that does not contain those is rejected here rather than
committed, because every one of them is a field that has already broken:
the gates can only hold what the fixture exercises.
"""
import argparse
import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import nowwire                                          # noqa: E402

DEFAULT_OUT = (pathlib.Path(__file__).resolve().parents[2]
               / "now-host/Tests/HostTests/Fixtures/now-scene-ir-v1.json")


def stimulus(link):
    """Put the machine somewhere worth photographing."""
    link.command("front", line="Finder")
    time.sleep(1)
    link.command("script", {"source":
                            'tell application "Finder" to open folder '
                            '"System Folder" of startup disk'})
    time.sleep(4)


def complaints(scene):
    """What this capture cannot hold. Empty means it is worth committing."""
    out = []
    wins = scene.get("windows") or []
    foreign = [w for w in wins if w.get("app") != "New Old World"]
    if not foreign:
        out.append("no FOREIGN window - the scene would describe only NOW")

    controls = [c for w in wins for c in (w.get("controls") or [])]
    if not controls:
        out.append("no window carries a control - `role`, `rect` and the "
                   "hit-test round trip go untested")
    if not any(c.get("rect") for c in controls):
        out.append("no control carries a rect - the hit-test gate would "
                   "assert nothing")
    live = [c for c in controls
            if c.get("role") == "scrollbar"
            and isinstance(c.get("min"), int) and isinstance(c.get("max"), int)
            and c["max"] > c["min"] + 1]
    if not live:
        out.append("no control has a live range (max > min+1), so scrollbar "
                   "part geometry is untested - open a folder window whose "
                   "contents overflow")

    bar = scene.get("menubar") or {}
    menus = bar.get("menus") or []
    if not menus:
        out.append("no menu bar - `apple` and `cmd` go untested")
    elif not any(m.get("apple") for m in menus):
        out.append("no menu is flagged `apple`")
    elif not any(m.get("items") for m in menus):
        out.append("every menu is empty, so `cmd` on an item is untested")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    nowwire.add_link_args(ap)
    ap.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT)
    ap.add_argument("--force", action="store_true",
                    help="write even when the capture is thin (say why in "
                         "the commit message)")
    args = ap.parse_args()

    link = nowwire.link_from_args(args)
    stimulus(link)
    scene, envelope = link.scene()

    bad = complaints(scene)
    if bad:
        print("this capture cannot hold the gates:", file=sys.stderr)
        for line in bad:
            print(f"  - {line}", file=sys.stderr)
        if not args.force:
            return 1
        print("  (--force: writing anyway)", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(scene, indent=1, sort_keys=False) + "\n")

    wins = scene.get("windows") or []
    print(f"wrote {args.out}")
    print(f"  {len(wins)} windows, "
          f"{sum(len(w.get('controls') or []) for w in wins)} controls, "
          f"{len((scene.get('menubar') or {}).get('menus') or [])} menus")
    print(f"  envelope: {json.dumps(envelope)[:160]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
