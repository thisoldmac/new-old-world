#!/usr/bin/env python3
"""Scratch: find a dialog with text items, and see what the text ops say.

Ported from `timbottu/mirror/tests/textops-explore.py`, and from
`h2-explore.py`'s half of the same job.

NOT A MEASUREMENT — A LOOK. The probe that measures is textops-probe.py, and
nothing here counts a trial, computes a rate, or returns a status that means
anything. That distinction is upstream's and it is worth keeping visible: an
explore script that grows assertions becomes a gate nobody watched fail.

## STATUS ON NOW TODAY: REFUSES (observe, textget)

Usage:

    NOW_METAL=1 python3 scripts/probes/textops-explore.py --port 5252
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oracles                                                    # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "textops-explore"
REQUIRED = ("observe", "textget")

GATE_NOTE = """\
An exploration needs the same two things the measurement needs: an observation
to walk, and textget to ask. Both are covered by textops-probe.py's gate note."""


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    print(f"front = {oracles.front_app(link)!r}")
    out = link.command("observe", {"scope": "front"})
    for w in out.get("windows", []):
        print(f"\n  window ref={w.get('ref')} kind={w.get('kind')} "
              f"title={w.get('title')!r} visible={w.get('visible')} "
              f"rect={w.get('rect')}")
        for e in w.get("elements", []):
            print(f"      element {e.get('ref')} kind={e.get('kind')} "
                  f"type={e.get('itemType')} text={e.get('text')!r}")
            try:
                r = link.command("textget", {"element": e["ref"]})
                print(f"          textget -> "
                      f"{json.dumps(link.rows(r, 'textget'))[:160]}")
            except GuestError as exc:
                print(f"          textget -> refused: {exc}")
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
