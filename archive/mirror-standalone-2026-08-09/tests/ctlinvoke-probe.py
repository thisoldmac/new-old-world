#!/usr/bin/env python3
"""Probe `ctlinvoke` — the Portal's CONTROL_INVOKE op — against guest state.

The oracle is ALWAYS the control's own value, read back through `axtree`.
`answered:true` only means the application's TrackControl returned our part
code; it is not evidence that anything happened.

Two traps this exists to avoid, both of which have already cost a cycle here:

  * A scroll bar sitting at its maximum cannot page DOWN. A no-op that is
    correct behaviour is indistinguishable from a broken verb unless the
    direction is chosen against the control's live value.
  * The Control Manager part codes are 20/21/22/23 (up button, down button,
    page up, page down) and 10/11 (button, check box) — Inside Macintosh,
    the Control Manager, and ControlDefinitions.h. 12 and 13 are NOT part
    codes; asking for one is asking the app to do nothing.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/ctlinvoke-probe.py --agent-port 1724 --anchor-port 1704
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

# Inside Macintosh, the Control Manager (ControlDefinitions.h).
IN_BUTTON, IN_CHECKBOX = 10, 11
IN_UP_BUTTON, IN_DOWN_BUTTON = 20, 21
IN_PAGE_UP, IN_PAGE_DOWN = 22, 23
IN_THUMB = 129


def front(agent: Agent):
    for p in agent.call("observe").get("processes", []):
        if p.get("front"):
            return p.get("name")
    return None


def controls(agent: Agent):
    out = []
    tree = agent.call("axtree", {"scope": "front"})
    for w in tree.get("windows", []):
        out.extend(w.get("controls", []))
    return out


def live_bar(agent: Agent):
    """The visible, enabled control with the widest range — the scroll bar."""
    live = [c for c in controls(agent)
            if c.get("visible") and c.get("enabled")
            and (c.get("max") or 0) > (c.get("min") or 0)]
    if not live:
        return None
    return max(live, key=lambda c: (c.get("max") or 0) - (c.get("min") or 0))


def read_value(agent: Agent, ref: str):
    for c in controls(agent):
        if c.get("ref") == ref:
            return c.get("value")
    return None


def setup_scrollable(agent: Agent, h: Harness) -> None:
    """A SimpleText document with enough lines that its scroll bar has range."""
    if front(agent) != "SimpleText":
        h.request("launch", {"path": SIMPLETEXT})
        for _ in range(15):
            time.sleep(2)
            if front(agent) == "SimpleText":
                break
    if live_bar(agent) is None:
        for _ in range(45):
            agent.call("key", {"code": 36, "char": 13, "mods": 0})   # Return
        time.sleep(3)


def try_part(agent: Agent, ref: str, part: int, settle: float = 2.0):
    """One ctlinvoke, reported as (before, after, reply)."""
    before = read_value(agent, ref)
    try:
        reply = agent.call("ctlinvoke", {"ref": ref, "part": part})
    except GuestError as e:
        return before, before, {"error": str(e)}
    time.sleep(settle)
    return before, read_value(agent, ref), reply


def windows(agent: Agent):
    return agent.call("axtree", {"scope": "front"}).get("windows", [])


def button_case(agent: Agent, h: Harness) -> int:
    """The RETURN-VALUE half: a push button in a modal alert.

    A button does its work AFTER TrackControl returns, from the part code, so
    this half needs no action procedure at all. The oracle is the alert going
    away — a window the guest itself stops reporting — not the verb's reply.
    """
    setup_scrollable(agent, h)                  # SimpleText, modified document
    before_titles = [w.get("title") for w in windows(agent)]
    agent.call("key", {"code": 13, "char": 119, "mods": 256})    # cmd+W, close
    time.sleep(3)

    alerts = [w for w in windows(agent)
              if w.get("title") not in before_titles or w.get("kind") == 2]
    if not alerts:
        print("no alert appeared on cmd+W — nothing to press")
        print("windows:", [(w.get("title"), w.get("kind")) for w in windows(agent)])
        return 2
    dlg = alerts[-1]
    btns = [c for c in dlg.get("controls", []) if c.get("visible")]
    print(f"alert {dlg.get('title')!r} kind={dlg.get('kind')} "
          f"controls={[c.get('title') for c in btns]}")
    target = next((c for c in btns
                   if (c.get("title") or "").lower().startswith("cancel")), None)
    if target is None:
        print("no Cancel button exposed; controls:", btns)
        return 2

    reply = agent.call("ctlinvoke", {"ref": target["ref"], "part": IN_BUTTON})
    time.sleep(3)
    after = [(w.get("title"), w.get("kind")) for w in windows(agent)]
    gone = not any(w.get("kind") == dlg.get("kind")
                   and w.get("title") == dlg.get("title")
                   for w in windows(agent))
    print(f"reply={reply}")
    print(f"alert dismissed by the button = {gone}   windows now {after}")
    return 0 if gone else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    ap.add_argument("--case", default="scroll", choices=("scroll", "button"))
    ap.add_argument("--parts", default="20,22,21,23",
                    help="comma-separated part codes to try, in order")
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})

    print("portal:", agent.call("portal"))
    print("selftest:", agent.call("portalselftest"))

    if args.case == "button":
        return button_case(agent, h)

    setup_scrollable(agent, h)
    bar = live_bar(agent)
    if bar is None:
        print("NO control with a live range is exposed — nothing to measure")
        return 2
    lo, hi = bar.get("min"), bar.get("max")
    print(f"scroll bar {bar['ref']}  value={bar.get('value')} range {lo}..{hi}")

    for part in [int(p) for p in args.parts.split(",")]:
        # Choosing the direction against the live value is the whole point:
        # at the maximum a page/line DOWN is a legitimate no-op.
        v = read_value(agent, bar["ref"])
        note = ""
        if part in (IN_DOWN_BUTTON, IN_PAGE_DOWN) and v == hi:
            note = "  (at max — a correct no-op, not evidence of anything)"
        if part in (IN_UP_BUTTON, IN_PAGE_UP) and v == lo:
            note = "  (at min — a correct no-op, not evidence of anything)"
        b, a, reply = try_part(agent, bar["ref"], part)
        moved = (a != b)
        print(f"part={part:<4} value {b} -> {a}  moved={moved}{note}")
        print(f"           reply={reply}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
