#!/usr/bin/env python3
"""Every control this application makes records what KIND it is.

The scene must report a `role` for every control. It used to guess one
from the value range - `min != max` meant "scrollbar" - and a push button
carries min 0 max 1, so EVERY BUTTON in this application mirrored as a
scroll bar: drawn as a track, hit-tested as `pageDown`, and a click on it
would have sent a page-scroll part instead of a button press. Found by
hovering the mirror and reading what it said the thing under the pointer
was (2026-08-03).

The Control Manager answers this properly with `GetControlKind`, and
CarbonLib 1.6 does not export it. The `procID` does just as well and this
application passes one every time - so `now_control_new` records it.

A bare `NewControl` therefore makes a control the mirror silently
mis-draws and mis-clicks, with nothing at runtime to say so. Hence a
source gate: the wrapper is the only caller.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WRAPPER = "now-guest-ppc/src/workshop/control_kind.c"
CALL = re.compile(r"(?<![A-Za-z0-9_])NewControl\s*\(")


def main():
    offenders = []
    scanned = 0
    for path in sorted((ROOT / "now-guest-ppc/src").rglob("*.c")):
        rel = str(path.relative_to(ROOT))
        if rel == WRAPPER:
            continue
        scanned += 1
        text = path.read_text(errors="replace")
        for m in CALL.finditer(text):
            line = text[:m.start()].count("\n") + 1
            offenders.append(f"{rel}:{line}")

    if offenders:
        print("bare NewControl outside the wrapper:\n", file=sys.stderr)
        for o in offenders:
            print("  " + o, file=sys.stderr)
        print("\nUse now_control_new (workshop/control_kind.h). It takes the "
              "same arguments and records the procID, which is the only "
              "thing that can tell the mirror a button from a scroll bar.",
              file=sys.stderr)
        return 1

    if scanned == 0:
        print("no guest sources scanned - this asserted nothing",
              file=sys.stderr)
        return 1
    print(f"ok: {scanned} sources, every control records its kind")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
