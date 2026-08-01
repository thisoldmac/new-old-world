#!/usr/bin/env python3
"""Lane H2, calibration: where on the SCREEN is the item the Finder placed at
`position`?

The oracle is guest state, never our own arithmetic: for each item we compute a
point, click it, and ask the Finder what is now selected. An item counts as hit
only when the Finder names it. Offsets that merely look plausible do not count.

Usage: h2-calibrate.py [dx dy]   (extra offset applied to the icon centre)
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2probe import agent_call                        # noqa: E402
from h2calib import ICON, deselect, selection, window_items   # noqa: E402


def main():
    dx = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    dy = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    rect, items = window_items()
    print(f"window content rect {rect}, {len(items)} items, "
          f"extra offset ({dx},{dy})")
    hits = tried = 0
    for name, ix, iy in items:
        px = rect[0] + ix + ICON // 2 + dx
        py = rect[1] + iy + ICON // 2 + dy
        if not (rect[0] <= px < rect[2] and rect[1] <= py < rect[3]):
            print(f"  {name:34s} pos=({ix},{iy}) -> ({px},{py}) OUTSIDE window")
            continue
        tried += 1
        deselect()
        agent_call("click", {"x": px, "y": py, "count": 1})
        time.sleep(0.4)
        got = selection()
        ok = (got == name)
        hits += ok
        print(f"  {name:34s} pos=({ix},{iy}) -> ({px},{py}) "
              f"selected={got!r} {'HIT' if ok else 'MISS'}")
    print(f"hits {hits}/{tried} (of {len(items)} items; the rest are below "
          f"the fold)")


if __name__ == "__main__":
    main()
