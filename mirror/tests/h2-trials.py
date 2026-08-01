#!/usr/bin/env python3
"""Lane H2 acceptance: N independent trials of "a click computed from an
item's reported position selects THAT item on the guest".

Independence is the part that has burned this project before (the famous
"~9 actuations per boot" was an accumulating oracle). So each trial:

  1. clears the Finder's selection and CONFIRMS it is empty;
  2. picks a target the previous trial did not use;
  3. runs a fresh MirrorApp process — its own poll, its own hit-test, its own
     dispatch — with `--act-window-item NAME`. The host computes the point
     from the item's reported position; nothing here does that arithmetic.
  4. asks the FINDER what is selected. That, not MirrorApp's own report, is
     the oracle. A trial passes only when the Finder names the item we aimed
     at.

Trials are also run against a scrolled window, because a scroll moves every
reported position and is the case a saved-grid implementation gets wrong.
"""
import json
import random
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIRROR = HERE.parent
sys.path.insert(0, str(HERE))
from h2probe import agent_call, ports                        # noqa: E402
from h2calib import deselect, selection, sc, window_items    # noqa: E402

APP = MIRROR / "host/MirrorKit/.build/debug/MirrorApp"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20
FOLDER = "Macintosh HD:TimBotTu"


def act(name):
    """One MirrorApp run: poll → hit-test → dispatch. Returns (ok, stdout)."""
    _, agent_port = ports()
    r = subprocess.run(
        [str(APP), "--host", "127.0.0.1", "--port", str(agent_port),
         "--machine", "mac99", "--scope", "all",
         "--qmp", str(MIRROR / "run/qmp.sock"),
         "--act-window-item", name],
        capture_output=True, text=True, timeout=180)
    return r.returncode == 0, r.stdout + r.stderr


def scroll_lines(n, x, y):
    for _ in range(n):
        agent_call("click", {"x": x, "y": y, "count": 1})
        time.sleep(0.3)
    time.sleep(1.0)


def vertical_scrollbar():
    tree = agent_call("axtree", {"scope": "all"})["result"]
    for app in tree.get("apps", []):
        for w in app.get("windows", []):
            if w.get("app") == "Finder" or True:
                for c in w.get("controls", []):
                    r = c.get("rect")
                    if (r and c.get("visible")
                            and (r[3] - r[1]) > (r[2] - r[0])
                            and w.get("title") == "TimBotTu"):
                        return r
    return None


def trials(n, label, rng):
    rect, items = window_items()
    visible = [(name, x, y) for name, x, y in items
               if rect[0] <= rect[0] + x + 16 < rect[2]
               and rect[1] + 20 <= rect[1] + y + 16 < rect[3] - 15]
    if not visible:
        print(f"{label}: no visible items — cannot run trials")
        return []
    print(f"{label}: {len(visible)} visible of {len(items)}; {n} trials")
    results = []
    last = None
    for i in range(n):
        pool = [v for v in visible if v[0] != last] or visible
        name, ix, iy = rng.choice(pool)
        last = name
        deselect()
        pre = selection()
        if pre != "":
            results.append({"trial": i, "item": name, "hit": False,
                            "why": f"selection not cleared: {pre!r}"})
            continue
        ok, out = act(name)
        time.sleep(0.5)
        got = selection()
        results.append({"trial": i, "item": name, "selected": got,
                        "hit": ok and got == name,
                        "pos": [ix, iy],
                        "app_ok": ok,
                        "why": "" if ok else out.strip().splitlines()[-1:]})
        mark = "HIT " if results[-1]["hit"] else "MISS"
        print(f"  {i:2d} {mark} aimed={name!r} selected={got!r}")
    hits = sum(r["hit"] for r in results)
    print(f"{label}: {hits}/{len(results)}")
    return results


def main():
    rng = random.Random(20260731)
    # Start from a known state: close and reopen, so the "unscrolled" block is
    # actually unscrolled rather than however the last run left it.
    sc('tell application "Finder"\nclose every window\nend tell')
    time.sleep(1)
    sc(f'tell application "Finder"\nopen folder "{FOLDER}"\nend tell')
    time.sleep(2)

    out = {"unscrolled": trials(N, "unscrolled", rng)}

    bar = vertical_scrollbar()
    if bar:
        print(f"\nscrolling the window (down arrow at "
              f"{(bar[0] + bar[2]) // 2},{bar[3] - 8})")
        scroll_lines(8, (bar[0] + bar[2]) // 2, bar[3] - 8)
        out["scrolled"] = trials(N, "scrolled", rng)
    else:
        print("no vertical scrollbar — scrolled trials SKIPPED")
        out["scrolled"] = []

    total = sum(r["hit"] for v in out.values() for r in v)
    count = sum(len(v) for v in out.values())
    print(f"\nTOTAL {total}/{count}")
    (HERE / "h2-trials-result.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
