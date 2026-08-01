#!/usr/bin/env python3
"""Probe `winact` — the Portal's WINDOW_ACT op — against guest state.

The oracle is ALWAYS the window's own rect, re-read out of the guest through
`axtree` after the act. `answered:true` says the patch answered; it is not
evidence that anything moved, and this project has four retracted findings
made of treating it as evidence.

Three traps this exists to avoid:

  * **A reused window accumulates.** Trial 12 must be measured against the
    same machine state as trial 1, so every trial RESETS the window to a known
    rect first and asks for a target derived from that reset, not from
    wherever the previous trial left it. The "~9 actuations per boot" ceiling
    was an accumulating oracle, not a defect.
  * **A no-op that is correct is indistinguishable from a broken verb.**
    Asking a window to move where it already is proves nothing, so the target
    always differs from the reset position by a stated amount.
  * **`close` can destroy a document.** The close case runs on an EMPTY,
    unmodified SimpleText window, so the application's own close path has no
    save-changes dialog to raise. See the `winact` doc comment: this verb does
    not promise the window closes, it promises the application was asked.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/winact-probe.py --agent-port 1724 --anchor-port 1704
    python3 tests/winact-probe.py ... --case close
"""

from __future__ import annotations

import argparse
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

# A reset position and size that fit an 800x600 screen with the menu bar
# (20px, Inside Macintosh: Macintosh Toolbox Essentials) clear of the top.
HOME = (60, 60)
HOME_SIZE = (420, 300)


def front_name(agent: Agent):
    for p in agent.call("observe").get("processes", []):
        if p.get("front"):
            return p.get("name")
    return None


def windows(agent: Agent):
    return agent.call("axtree", {"scope": "front"}).get("windows", [])


def find(agent: Agent, title: str, occurrence: int = 0):
    n = 0
    for w in windows(agent):
        if w.get("title") == title:
            if n == occurrence:
                return w
            n += 1
    return None


def rect_of(agent: Agent, title: str, occurrence: int = 0):
    """[left, top, right, bottom] — the CONTENT region, in global coords."""
    w = find(agent, title, occurrence)
    return w.get("rect") if w else None


def ensure_simpletext(agent: Agent, h: Harness) -> str:
    """Bring up SimpleText and return the title of its document window."""
    if front_name(agent) != "SimpleText":
        h.request("launch", {"path": SIMPLETEXT})
        for _ in range(20):
            time.sleep(2)
            if front_name(agent) == "SimpleText":
                break
    for _ in range(15):
        wins = [w for w in windows(agent) if w.get("visible")]
        if wins:
            return wins[0]["title"]
        time.sleep(1)
    raise SystemExit("SimpleText never showed a visible window")


def call(agent: Agent, args: dict):
    try:
        return agent.call("winact", args), None
    except GuestError as e:
        return None, str(e)


def reset(agent: Agent, title: str, settle: float = 1.0) -> list | None:
    """Put the window back at a known rect. Trials must be independent."""
    call(agent, {"title": title, "op": "move", "x": HOME[0], "y": HOME[1]})
    time.sleep(settle)
    call(agent, {"title": title, "op": "resize",
                 "w": HOME_SIZE[0], "h": HOME_SIZE[1]})
    time.sleep(settle)
    return rect_of(agent, title)


# --------------------------------------------------------------------------


def case_move(agent: Agent, title: str, n: int, settle: float) -> int:
    """Ask for a position, then read the window's own rect back."""
    hits = answered = 0
    for i in range(n):
        base = reset(agent, title, settle)
        if base is None:
            print(f"  trial {i}: window vanished during reset"); continue
        # A target that is never where the window already is.
        want = (HOME[0] + 40 + (i % 5) * 10, HOME[1] + 30 + (i % 3) * 10)
        reply, err = call(agent, {"title": title, "op": "move",
                                  "x": want[0], "y": want[1]})
        time.sleep(settle)
        got = rect_of(agent, title)
        ok = got is not None and (got[0], got[1]) == want
        answered += 1 if (reply and reply.get("answered")) else 0
        hits += 1 if ok else 0
        print(f"  move {i:2d}: want={want} base={base[:2] if base else None} "
              f"got={got[:2] if got else None} ok={ok}"
              + (f" err={err}" if err else ""))
    print(f"move: {answered}/{n} answered, {hits}/{n} ACTUATED "
          f"(oracle = the window's own rect)")
    return 0 if hits == n else 1


def case_resize(agent: Agent, title: str, n: int, settle: float) -> int:
    """Ask for a size, then read the window's own rect back.

    Width and height always differ, which is what catches a swapped
    GrowWindow packing: high word is the HEIGHT, low word the WIDTH (Inside
    Macintosh: Macintosh Toolbox Essentials, the Window Manager). Swapped, a
    420x260 request comes back 260x420 and this fails loudly rather than
    reporting a plausible number.
    """
    hits = answered = 0
    for i in range(n):
        reset(agent, title, settle)
        want = (300 + (i % 5) * 20, 180 + (i % 3) * 15)   # w != h, always
        reply, err = call(agent, {"title": title, "op": "resize",
                                  "w": want[0], "h": want[1]})
        time.sleep(settle)
        got = rect_of(agent, title)
        size = (got[2] - got[0], got[3] - got[1]) if got else None
        ok = size == want
        answered += 1 if (reply and reply.get("answered")) else 0
        hits += 1 if ok else 0
        print(f"  resize {i:2d}: want={want} got={size} ok={ok}"
              + (f" err={err}" if err else ""))
    print(f"resize: {answered}/{n} answered, {hits}/{n} ACTUATED")
    return 0 if hits == n else 1


def case_zoom(agent: Agent, title: str, n: int, settle: float) -> int:
    """Zoom out then in. The oracle is that the rect CHANGES and comes back.

    Zoom has no caller-named target — the standard state is the application's
    and the Window Manager's — so the claim measured here is weaker on purpose
    and stated as what it is: out changes the rect, in restores the rect the
    window had before out.
    """
    hits = answered = 0
    for i in range(n):
        before = reset(agent, title, settle)
        r1, e1 = call(agent, {"title": title, "op": "zoom", "zoom": "out"})
        time.sleep(settle)
        zoomed = rect_of(agent, title)
        r2, e2 = call(agent, {"title": title, "op": "zoom", "zoom": "in"})
        time.sleep(settle)
        back = rect_of(agent, title)
        ok = (before is not None and zoomed is not None and back is not None
              and zoomed != before and back == before)
        answered += 1 if (r1 and r1.get("answered")
                          and r2 and r2.get("answered")) else 0
        hits += 1 if ok else 0
        print(f"  zoom {i:2d}: before={before} out={zoomed} in={back} ok={ok}"
              + (f" err={e1 or e2}" if (e1 or e2) else ""))
    print(f"zoom: {answered}/{n} answered, {hits}/{n} ACTUATED "
          f"(out changes the rect, in restores it)")
    return 0 if hits == n else 1


def case_close(agent: Agent, h: Harness, n: int, settle: float) -> int:
    """Close an EMPTY window, so no save-changes dialog can appear.

    The oracle is the window's disappearance from `axtree` — the guest's own
    window list, not the verb's report. Each trial makes a FRESH untitled
    window with cmd+N so the trials are independent: closing the same window
    twice measures nothing the second time.
    """
    ensure_simpletext(agent, h)
    gone = answered = 0
    for i in range(n):
        agent.call("key", {"code": 45, "char": 110, "mods": 256})   # cmd+N
        time.sleep(settle + 1.0)
        wins = [w for w in windows(agent) if w.get("visible")]
        if not wins:
            print(f"  close {i:2d}: cmd+N produced no window; skipped")
            continue
        title = wins[0]["title"]
        reply, err = call(agent, {"title": title, "op": "close"})
        time.sleep(settle + 1.0)
        still = find(agent, title) is not None
        answered += 1 if (reply and reply.get("answered")) else 0
        gone += 0 if still else 1
        print(f"  close {i:2d}: {title!r} gone={not still} "
              f"windowGone={reply.get('windowGone') if reply else None}"
              + (f" err={err}" if err else ""))
    print(f"close: {answered}/{n} answered, {gone}/{n} WINDOW GONE "
          f"(oracle = absence from the guest's own window list)")
    return 0 if gone == n else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    ap.add_argument("--case", default="move",
                    choices=("move", "resize", "zoom", "close", "all"))
    ap.add_argument("-n", type=int, default=5)
    ap.add_argument("--settle", type=float, default=1.2)
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})

    print("portal:", agent.call("portal"))
    title = ensure_simpletext(agent, h)
    print(f"target window: {title!r}  rect={rect_of(agent, title)}")

    cases = (("move", "resize", "zoom", "close")
             if args.case == "all" else (args.case,))
    rc = 0
    for c in cases:
        print(f"\n== {c} ==")
        if c == "move":
            rc |= case_move(agent, title, args.n, args.settle)
        elif c == "resize":
            rc |= case_resize(agent, title, args.n, args.settle)
        elif c == "zoom":
            rc |= case_zoom(agent, title, args.n, args.settle)
        else:
            rc |= case_close(agent, h, args.n, args.settle)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
