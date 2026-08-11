#!/usr/bin/env python3
"""Every control this application makes, and unmakes, goes through one file.

TWO THINGS rest on that, and the second one is newer and sharper.

**What a control IS.** The scene must report a `role` for every control.
It used to guess one from the value range - `min != max` meant "scrollbar"
- and a push button carries min 0 max 1, so EVERY BUTTON in this
application mirrored as a scroll bar: drawn as a track, hit-tested as
`pageDown`, and a click on it would have sent a page-scroll part instead
of a button press. Found by hovering the mirror (2026-08-03). The Control
Manager answers this properly with `GetControlKind`, and CarbonLib 1.6
does not export it; the `procID` does just as well and this application
passes one every time, so `now_control_new` records it.

**THAT a control exists.** As of 2026-08-06 the same table is the scene's
LIST of a window's controls. It replaced a 3,724-point `FindControl` grid
sweep that cost ~240us a point on an active window - 1,891,174us on the
scene where a person clicked into NOW - and that answered NOTHING on an
inactive one, so a backgrounded NOW reported its own window as empty.

That second use is what makes this gate strict rather than tidy. The
scene DEREFERENCES a ControlRef it got from the table, so a disposal the
table did not see is a read of freed memory, and a creation it did not
see is a control the mirror never mentions. Hence all five calls:

  NewControl               -> now_control_new
  CreateDataBrowserControl -> ... + now_control_adopt
  DisposeControl           -> now_control_dispose
  DisposeWindow            -> now_control_dispose_window
  DisposeDialog            -> now_control_dispose_dialog

The two window calls are here because `DisposeWindow` destroys the
window's controls and tells nobody - the comments in this tree say so in
four places, which is exactly the kind of knowledge that survives in prose
until it doesn't.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WRAPPER = "now-guest-ppc/src/workshop/control_kind.c"

# The bare Toolbox call -> what to use instead. CreateDataBrowserControl is
# checked differently: it has no wrapper, it has a companion.
BANNED = {
    "NewControl": "now_control_new",
    "DisposeControl": "now_control_dispose",
    "DisposeWindow": "now_control_dispose_window",
    "DisposeDialog": "now_control_dispose_dialog",
}

ADOPT = "now_control_adopt"


def call(name):
    return re.compile(r"(?<![A-Za-z0-9_])" + name + r"\s*\(")


def main():
    offenders = []
    unadopted = []
    scanned = 0
    saw = {name: 0 for name in BANNED}
    for path in sorted((ROOT / "now-guest-ppc/src").rglob("*.c")):
        rel = str(path.relative_to(ROOT))
        text = path.read_text(errors="replace")
        if rel != WRAPPER:
            scanned += 1
            for name, use in BANNED.items():
                for m in call(name).finditer(text):
                    line = text[:m.start()].count("\n") + 1
                    offenders.append(f"{rel}:{line}: {name} -> {use}")

        # A DataBrowser is made by a constructor that takes no procID, so
        # it cannot go through the wrapper - it has to be handed over
        # afterwards, in the same function, or it is invisible to the
        # scene. Function granularity is deliberate: file granularity
        # would pass a file that adopts one browser and forgets another.
        for m in call("CreateDataBrowserControl").finditer(text):
            line = text[:m.start()].count("\n") + 1
            after = text[m.start():m.start() + 2000]
            if ADOPT not in after:
                unadopted.append(f"{rel}:{line}")

    for name in BANNED:
        saw[name] = sum(
            1 for _ in call(name).finditer(
                (ROOT / WRAPPER).read_text(errors="replace")))

    if offenders or unadopted:
        if offenders:
            print("bare Toolbox control calls outside the wrapper:\n",
                  file=sys.stderr)
            for o in offenders:
                print("  " + o, file=sys.stderr)
        if unadopted:
            print("\nCreateDataBrowserControl with no now_control_adopt "
                  "beside it:\n", file=sys.stderr)
            for o in unadopted:
                print("  " + o, file=sys.stderr)
        print("\nworkshop/control_kind.h owns the whole lifecycle. The "
              "scene reads that table INSTEAD of sweeping a FindControl "
              "grid, and it dereferences what the table hands it - so a "
              "creation it never saw is a control the mirror never "
              "mentions, and a disposal it never saw is a read of freed "
              "memory.", file=sys.stderr)
        return 1

    # The wrapper is not exempt from being CHECKED, only from the ban: if
    # it stopped calling the real Toolbox routines this gate would pass
    # while nothing worked.
    missing = [name for name, n in saw.items() if n == 0]
    if missing:
        print(f"{WRAPPER} no longer calls: {', '.join(missing)} - the "
              "wrapper has stopped wrapping", file=sys.stderr)
        return 1

    if scanned == 0:
        print("no guest sources scanned - this asserted nothing",
              file=sys.stderr)
        return 1
    print(f"ok: {scanned} sources, every control's making and unmaking "
          "goes through one file")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
