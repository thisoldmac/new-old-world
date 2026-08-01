#!/usr/bin/env python3
"""Lane H2: does `position of` move when the window is SCROLLED?

If the Finder reports window-content coordinates, scrolling shifts what is on
screen but not the reported position — and a naive content-origin mapping then
clicks the wrong file. This is the question that decides whether items can be
addressed at all, so it is measured, not assumed.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2probe import agent_call, qmp                   # noqa: E402
from h2calib import selection, deselect, window_items, sc   # noqa: E402


def scrollbar(win_title):
    """The Finder window's live vertical scrollbar, from the axtree plane.

    Raw axtree control rects are GLOBAL (the host's SceneBuilder is what makes
    them content-local later) — so the returned rect can be clicked directly.
    """
    tree = agent_call("axtree", {"scope": "all"})["result"]
    for app in tree.get("apps", []):
        for w in app.get("windows", []):
            if w.get("title") != win_title:
                continue
            for c in w.get("controls", []):
                r = c.get("rect")
                if not r or not c.get("visible"):
                    continue
                if (r[3] - r[1]) > (r[2] - r[0]):     # taller than wide
                    return w, c
    return None, None


def main():
    rect, items = window_items()
    print("before scroll:", rect)
    for name, x, y in items[:3]:
        print(f"   {name:30s} ({x},{y})")

    w, sb = scrollbar("TimBotTu")
    print("vertical scrollbar:", sb and {k: sb.get(k) for k in
                                         ("rect", "value", "min", "max")})
    if sb is None:
        sys.exit("no vertical scrollbar found — cannot test the scrolled case")

    # Press the DOWN ARROW a few times with a real click: the Control Manager
    # tracks the hardware button, which the wire click cannot drive.
    r = sb["rect"]                     # already global
    ax = (r[0] + r[2]) // 2
    ay = r[3] - 8
    print(f"clicking the down arrow at ({ax},{ay})")
    for _ in range(6):
        qmp("click", f'{{"x":{ax},"y":{ay}}}')
        time.sleep(0.25)
    time.sleep(1.0)

    rect2, items2 = window_items()
    print("after scroll:", rect2)
    for name, x, y in items2[:3]:
        print(f"   {name:30s} ({x},{y})")

    same = {n: (x, y) for n, x, y in items} == {n: (x, y) for n, x, y in items2}
    print("positions unchanged by scrolling:", same)

    # And the decisive part: does the naive mapping still hit?
    hits = tried = 0
    for name, ix, iy in items2:
        px = rect2[0] + ix + 16
        py = rect2[1] + iy + 16
        if not (rect2[0] <= px < rect2[2] and rect2[1] <= py < rect2[3]):
            continue
        tried += 1
        deselect()
        agent_call("click", {"x": px, "y": py, "count": 1})
        time.sleep(0.4)
        got = selection()
        hits += (got == name)
        print(f"   {name:30s} -> ({px},{py}) selected={got!r}")
    print(f"naive-mapping hits after scrolling: {hits}/{tried}")


if __name__ == "__main__":
    main()
