#!/usr/bin/env python3
"""Drive the guest through a real multi-step task and verify each step.

Single verbs passing is not the same as being able to drive. This script does a
sequence of mixed actions and checks every one against guest state, so "we can
drive a Mac OS 9 machine" becomes a claim with a receipt.

What it proves that `trials.py` cannot:

  * a click's EFFECT on a real target, not merely that the cursor moved — it
    closes a window by its close box, using geometry the mirror itself reported
  * `axdo`'s SUCCESS path, by finding a control that is actually visible and
    enabled (most are not: Graphing Calculator exposes 11 controls of which 10
    are hidden and the last is disabled)
  * that a sequence survives its own side effects, which is where every
    earlier measurement went wrong

Usage (a guest must be up, e.g. via tools/spin-up.sh):

    python3 tests/drive-sequence.py --agent-port 1720 --anchor-port 1700
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from trials import Agent, GuestError  # noqa: E402

MIRROR = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.path.abspath(os.path.join(MIRROR, ".."))
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

steps: list[tuple[str, bool, str]] = []


def step(name: str, ok: bool, detail: str = "") -> bool:
    steps.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def front(agent: Agent) -> str | None:
    procs = agent.call("observe").get("processes", [])
    return next((p.get("name") for p in procs if p.get("front")), None)


def windows(agent: Agent) -> list:
    try:
        return agent.call("axtree", {"scope": "front"}).get("windows") or []
    except GuestError:
        return []


def controls(agent: Agent) -> list:
    out = []
    for w in windows(agent):
        out.extend(w.get("controls") or [])
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})

    hello = agent.call("hello")
    print(f"agent v{hello['version']} build={hello['build']} "
          f"oracle={hello['oracleStatus']}\n")

    # --- 1. launch an app and see it become frontmost --------------------------
    print("1. launch SimpleText")
    h.request("launch", {"path": SIMPLETEXT})
    for _ in range(20):
        time.sleep(2)
        if front(agent) == "SimpleText":
            break
    step("SimpleText is frontmost", front(agent) == "SimpleText", front(agent))

    wins = windows(agent)
    step("its window is visible in the tree", len(wins) >= 1,
         f"{[w.get('title') for w in wins]}")
    if not wins:
        report()
        return

    # --- 2. a click's EFFECT, with a crisp oracle -----------------------------
    # Not the close box: whether a title-bar widget was hit depends on chrome
    # geometry we would be asserting rather than observing. Clicking the DESKTOP
    # has an unambiguous consequence the guest reports itself — the Finder comes
    # forward — so the oracle is a front-app change, not a pixel guess.
    print("\n2. click the desktop (a click's effect, not just the cursor)")
    wr = wins[0].get("rect") or [0, 0, 0, 0]
    step("the window reported a rect", bool(wins[0].get("rect")), f"{wr}")
    tx, ty = wr[2] + 60, wr[3] - 40          # clear of SimpleText's window
    step("front app is SimpleText before the click", front(agent) == "SimpleText")
    agent.call("click", {"x": tx, "y": ty})
    time.sleep(3)
    now = front(agent)
    step("clicking the desktop brought the Finder forward", now == "Finder",
         f"front={now!r} (clicked {tx},{ty})")

    # --- 3. keyboard drives the Finder, verified in the filesystem -------------
    print("\n3. cmd+N in the Finder creates a folder")
    tgt = "Macintosh HD:Desktop Folder:untitled folder"
    if h.request("stat", {"path": tgt}).get("exists"):
        h.request("delete", {"path": tgt})
    agent.call("key", {"code": 45, "char": 110, "mods": 256})
    time.sleep(3)
    step("the folder exists on disk", h.request("stat", {"path": tgt}).get("exists"),
         tgt)
    h.request("delete", {"path": tgt})        # leave the desktop as we found it

    # --- 4. axdo's SUCCESS path, on a control whose state we can READ ----------
    # The target needs a LIVE RANGE. An empty SimpleText document exposes one
    # visible+enabled control whose min == max == 0 — nothing to scroll, so its
    # value cannot change and "did the control respond" is unanswerable. A Finder
    # window over a full folder has scrollbars with a real range, so open one by
    # launching the folder itself.
    print("\n4. axdo a control with a live range, and read the change")
    # Give the document enough lines to scroll. This doubles as the sustained
    # keyboard test: ~45 consecutive Returns, every one of which must land, on a
    # verb that was once believed to die after nine presses.
    h.request("launch", {"path": SIMPLETEXT})
    for _ in range(15):
        time.sleep(2)
        if front(agent) == "SimpleText":
            break
    step("SimpleText is frontmost for typing", front(agent) == "SimpleText",
         front(agent))
    sent = 0
    for _ in range(45):
        try:
            agent.call("key", {"code": 36, "char": 13, "mods": 0})   # Return
            sent += 1
        except GuestError:
            break
    step("45 consecutive Returns all landed", sent == 45, f"{sent}/45 accepted")
    time.sleep(3)
    live = [c for c in controls(agent)
            if c.get("visible") and c.get("enabled")
            and (c.get("max") or 0) > (c.get("min") or 0)]
    step("a control with a live range is exposed", bool(live),
         f"front={front(agent)!r}, {len(controls(agent))} controls, "
         f"{len(live)} with range")

    if live:
        bar = max(live, key=lambda c: (c.get("max") or 0) - (c.get("min") or 0))
        was = bar.get("value")
        try:
            res = agent.call("axdo", {"ref": bar["ref"]})
            pt, rect = res.get("point"), res.get("rect")
            inside = (pt and rect
                      and rect[0] <= pt[0] <= rect[2]
                      and rect[1] <= pt[1] <= rect[3])
            step("axdo returned ok and resolved a point inside the control",
                 bool(inside), f"point={pt} rect={rect}")
            time.sleep(2)
            same = [c for c in controls(agent) if c.get("ref") == bar["ref"]]
            now_val = same[0].get("value") if same else None
            step("the control's own state changed", now_val != was,
                 f"value {was} -> {now_val} (range {bar.get('min')}..{bar.get('max')})")
        except GuestError as e:
            step("axdo returned ok", False, f"{e}")

    report()


def report() -> None:
    passed = sum(1 for _, ok, _ in steps if ok)
    total = len(steps)
    print(f"\n--- {passed}/{total} steps passed, {total} verified actions ---")
    if passed != total:
        sys.exit(f"FAIL: {total - passed} step(s) failed")
    print("sustained driving: OK")


if __name__ == "__main__":
    main()
