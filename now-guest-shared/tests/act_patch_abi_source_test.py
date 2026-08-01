#!/usr/bin/env python3
"""The act plane's trap-patch ABI, read out of the assembly source.

WHY A SOURCE TEST, which is normally the weakest kind. The six
trampolines in ext/src/now_ext_act_patch.S cannot be executed here -
they are 68K, they run inside another application's stack frame, and the
only machine that could run them is the one we are not allowed to claim
anything about. But the defect they are exposed to is the worst shape a
defect can have, so leaving it to a comment is not good enough:

  A Pascal Boolean function result occupies a TWO-BYTE stack slot, and
  the value lives in the HIGH byte - the compiler reads it back with
  `move.b (%sp),%d0`. A patch that answers with `move.w #1,(%sp)` writes
  0x0001, whose high byte is ZERO, so the caller reads FALSE.

That patch compiles clean, runs clean, bumps its own counters, sets
`fired`, and reports success. Every instrument on our side says it
worked and the application takes the other branch. A wrong ABI does not
crash - it lies. It sits directly under TrackGoAway and TrackBox, which
is exactly where the window act has to answer.

A `short` result is the opposite case in the same-sized slot: the
compiler reads it with `move.w (%sp),%d0`, a full word, so FindWindow
and TrackControl must write the whole register. Two 2-byte slots, two
different writes, and getting either one wrong is silent.

So this pins which trampoline writes which. It is a text check and it
knows it: what it can catch is a faithful-looking transliteration
quietly dropping the distinction, or a later edit "tidying" 0x0100 into
1. What it cannot do is prove the frame offsets. Only a machine can, and
none has been asked.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "ext", "src", "now_ext_act_patch.S")

# label -> how that trap's result must be written back.
#   "boolean" a 2-byte slot whose value is the HIGH byte
#   "short"   a 2-byte slot read as a full word
#   "long"    a 4-byte slot
EXPECTED = {
    "now_act_menuselect_patch": "long",     # pascal long MenuSelect
    "now_act_trackcontrol_patch": "short",  # pascal short TrackControl
    "now_act_findwindow_patch": "short",    # pascal short FindWindow
    "now_act_growwindow_patch": "long",     # pascal long GrowWindow
    "now_act_trackbox_patch": "boolean",    # pascal Boolean TrackBox
    "now_act_trackgoaway_patch": "boolean",  # pascal Boolean TrackGoAway
}

WRITES = {
    "boolean": re.compile(r"move\.w\s+#0x0100,\(%sp\)"),
    "short": re.compile(r"move\.w\s+%d0,\(%sp\)"),
    "long": re.compile(r"move\.l\s+%d0,\(%sp\)"),
}

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def bodies(text):
    """Each trampoline's own code, from its label to the next one."""
    starts = []
    for name in EXPECTED:
        match = re.search(r"^%s:$" % re.escape(name), text, re.M)
        if match is None:
            failures.append("%s is not in the source at all" % name)
            continue
        starts.append((match.start(), name))
    starts.sort()
    out = {}
    for i, (at, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        out[name] = text[at:end]
    return out


def main():
    with open(SOURCE, "r") as handle:
        text = handle.read()

    for name, body in bodies(text).items():
        kind = EXPECTED[name]
        check(WRITES[kind].search(body) is not None,
              "%s must answer with the %s result write" % (name, kind))
        # And must NOT carry either of the other two: a trampoline with
        # two result writes has one that is wrong.
        for other, pattern in WRITES.items():
            if other == kind:
                continue
            check(pattern.search(body) is None,
                  "%s carries a %s result write as well as its %s one"
                  % (name, other, kind))
        # Every one of them must chain when it declines, with the stack
        # untouched - a patch that returns its own decline value instead
        # of chaining changes what the trap answers for everybody.
        check("jmp (%a0)" in body,
              "%s must chain to the trap installed before it" % name)
        # The bare `move.w #1` is the exact mistake this file exists to
        # keep out, in any trampoline.
        check(re.search(r"move\.w\s+#1,\(%sp\)", body) is None,
              "%s writes a Boolean as 0x0001 - high byte zero, so the "
              "caller reads FALSE from a patch that reported firing"
              % name)

    if failures:
        for line in failures:
            sys.stderr.write("FAIL: %s\n" % line)
        sys.stderr.write("%d failure(s)\n" % len(failures))
        return 1
    print("act_patch_abi_source: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
