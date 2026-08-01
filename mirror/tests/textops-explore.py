#!/usr/bin/env python3
"""Scratch: find a dialog with text items, and see what textget says about it.

Not a measurement — a look. The probe that measures is textops-probe.py.
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


def front(agent):
    for p in agent.call("observe").get("processes", []):
        if p.get("front"):
            return p.get("name")
    return None


def windows(agent):
    return agent.call("axtree", {"scope": "front"}).get("windows", [])


def dump(agent, note):
    print(f"\n--- {note}: front={front(agent)!r}")
    for w in windows(agent):
        te = w.get("textEdit")
        print(f"  z={w['z']} kind={w['kind']} title={w['title']!r} "
              f"visible={w['visible']} textEdit={json.dumps(te)[:120]}")
        if w["kind"] != 2:
            continue
        for item in range(1, 21):
            try:
                r = agent.call("textget", {"windowZ": w["z"],
                                           "window": w["title"],
                                           "kind": "ditem", "item": item})
            except GuestError as e:
                if "no such dialog item" in str(e):
                    break
                continue
            print(f"      item {item}: type={r['itemType']} "
                  f"text={r['text']!r} len={r['length']}")
        try:
            r = agent.call("textget", {"windowZ": w["z"], "window": w["title"],
                                       "kind": "dialogte"})
            print(f"      dialogte: te={r['teHandle']} text={r['text']!r} "
                  f"len={r['length']}")
        except GuestError as e:
            print(f"      dialogte: {e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})
    print(agent.call("hello"))
    print(agent.call("portal"))

    dump(agent, "desktop")

    if front(agent) != "SimpleText":
        h.request("launch", {"path": SIMPLETEXT})
        for _ in range(15):
            time.sleep(2)
            if front(agent) == "SimpleText":
                break
    dump(agent, "SimpleText launched")

    # Find (cmd-F). keycode 3 = 'f' (CONTROL-SURFACE.md: the key verb wants
    # integers, and menu shortcuts match on KEYCODE not character).
    agent.call("key", {"code": 3, "char": 102, "mods": 256})
    time.sleep(3)
    dump(agent, "after cmd-F")

    # Whatever opened, close it with Escape and try cmd-S (Save As on an
    # untitled document).
    agent.call("key", {"code": 53, "char": 27, "mods": 0})
    time.sleep(2)
    agent.call("key", {"code": 1, "char": 115, "mods": 256})
    time.sleep(4)
    dump(agent, "after cmd-S")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
