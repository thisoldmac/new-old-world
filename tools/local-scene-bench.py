#!/usr/bin/env python3
"""Time one guest's scene walk, N times, in one front-process condition.

Scratch instrument for the self-menu-bar cost. It listens as a host, takes
ONE dialling guest, asserts the build fingerprint it was told to expect
(AGENTS.md: every QEMU guest on this Mac sees 10.0.2.2, so any session's VM
can answer), optionally brings a process to the front, and then reads N
scenes reporting meta.latencyMs and the temporary meta.dbgUs breakdown.
"""

import argparse
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402

# The probe harness still declares contract revision 1; the guest under test
# says 2 and its hello is refused. Take the guest's number here rather than
# editing a shared harness from a scratch instrument.
nowwire.WIRE_CONTRACT_REVISION = 2

SLOTS = ["menubar", "acquireRoot", "rootItemsFor", "addOneMenu",
         "selfWindows", "ctlProbe", "menus", "items"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=float, default=180.0)
    ap.add_argument("--build", default=None,
                    help="required prefix of the guest's build stamp")
    ap.add_argument("--front", default=None,
                    help="bring this process to the front first")
    ap.add_argument("--samples", type=int, default=5)
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = link.hello.get("build", "")
    print(f"guest build: {build}  name={link.hello.get('name')}")
    if args.build and not build.startswith(args.build):
        sys.exit(f"WRONG GUEST: build {build!r} is not the build under test "
                 f"({args.build!r})")

    if args.front:
        print(link.command("front", {"target": args.front}))

    lat = []
    for i in range(args.samples):
        doc, env = link.scene()
        meta = doc.get("meta", {})
        dbg = meta.get("dbgUs", [])   # absent once the instrumentation is gone
        lat.append(meta.get("latencyMs"))
        procs = doc.get("processes", [])
        front = next((p.get("name") for p in procs if p.get("front")), "?")
        bar = doc.get("menubar") or {}
        menus = bar.get("menus", [])
        print(f"[{i}] front={front!r} latencyMs={meta.get('latencyMs')} "
              f"walkMs={env.get('walkMs')} menus={len(menus)} "
              f"items={sum(len(m.get('items', [])) for m in menus)}")
        if dbg:
            print("     " + "  ".join(f"{n}={v}" for n, v in zip(SLOTS, dbg)))
    print(f"latencyMs: {sorted(lat)}  median={statistics.median(lat)}")
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
