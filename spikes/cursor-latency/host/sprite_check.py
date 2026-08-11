#!/usr/bin/env python3
"""Does the drawn arrow actually move? Read from OUTSIDE the guest.

    host/sprite_check.py --qmp /path/to/qmp.sock --port 17400

WHY THIS IS SEPARATE FROM EVERY OTHER NUMBER. The rig's own counters
can say the position was written, when it was written, and when a redraw
was performed - and none of that is evidence that a person watching the
screen would see the pointer move. On Mac OS 9 the three are genuinely
separable:

    low memory        what tracking loops and GetMouse read
    cursor device     what the Cursor Device Manager thinks
    the blit          what is actually on the screen

A cursor plane that writes the first two and never moves the third
reports every counter climbing and changes zero pixels - which is
indistinguishable, from inside the guest, from working perfectly.

So this reads the framebuffer through QMP, with nothing running inside
the guest to help, and reports the BOUNDING BOX of what changed rather
than just a count. "22 pixels changed" is equally consistent with a
sprite that moved, a clock that ticked and a caret that blinked; WHERE
they changed is what tells those apart.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rigdrive import Rig, OP  # noqa: E402


def screendump(qmp_tool, sock, path):
    subprocess.run([qmp_tool, sock, "screendump",
                    json.dumps({"filename": path})],
                   capture_output=True, timeout=60)


def read_ppm(path):
    """Minimal binary PPM reader - no image library required."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path} is not a binary PPM")
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    w, h, _maxv = fields
    return w, h, data[i:i + w * h * 3]


def changed_box(a, b):
    """Bounding box of differing pixels, and how many there were."""
    wa, ha, pa = a
    wb, hb, pb = b
    if (wa, ha) != (wb, hb):
        raise SystemExit("the two dumps are different sizes")
    left, top, right, bottom, n = wa, ha, -1, -1, 0
    for y in range(ha):
        row = y * wa * 3
        ra, rb = pa[row:row + wa * 3], pb[row:row + wa * 3]
        if ra == rb:
            continue
        for x in range(wa):
            o = x * 3
            if ra[o:o + 3] != rb[o:o + 3]:
                n += 1
                left, right = min(left, x), max(right, x)
                top, bottom = min(top, y), max(bottom, y)
    if n == 0:
        return None, 0
    return (left, top, right, bottom), n


def contains(box, pt, slack=24):
    l, t, r, b = box
    x, y = pt
    return (l - slack) <= x <= (r + slack) and (t - slack) <= y <= (b + slack)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True, help="path to the QMP socket")
    ap.add_argument("--qmp-tool", default=None)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=17400)
    ap.add_argument("--a", type=int, nargs=2, default=[120, 120])
    ap.add_argument("--b", type=int, nargs=2, default=[600, 420])
    ap.add_argument("--settle", type=float, default=1.5)
    ap.add_argument("--load", default="idle",
                    help="hold the machine in this load profile for the "
                         "whole check - the condition under which the "
                         "picture is expected to fail")
    a = ap.parse_args()

    tool = a.qmp_tool
    if not tool:
        lab = HERE
        while lab != "/" and not os.path.isfile(os.path.join(lab, "tools/qmp")):
            lab = os.path.dirname(lab)
        tool = os.path.join(lab, "tools/qmp")

    rig = Rig(a.host, a.port)
    tmp = tempfile.mkdtemp(prefix="cursor-rig-sprite-")

    # A run must be armed or the writer ignores the mailbox.
    rig.send(OP["begin"], arg=0, stamp=0)
    time.sleep(0.3)

    if a.load != "idle":
        from rigdrive import LOADS
        # Long enough to cover both placements and both dumps: the whole
        # point is that the machine is busy for the ENTIRE check.
        rig.send(OP["load"], arg=LOADS[a.load],
                 h=int((a.settle * 2 + 8) * 60))
        time.sleep(0.5)
        print(f"load: {a.load} held for the duration of this check")

    def place(pt, seq):
        rig.send(OP["move"], seq=seq, h=pt[0], v=pt[1])
        time.sleep(a.settle)

    place(tuple(a.a), 1)
    p0 = os.path.join(tmp, "a.ppm")
    screendump(tool, a.qmp, p0)
    time.sleep(0.3)

    place(tuple(a.b), 2)
    p1 = os.path.join(tmp, "b.ppm")
    screendump(tool, a.qmp, p1)
    rig.send(OP["end"])

    # PROVE the load was actually running across both placements before
    # reporting anything about them. The starver only notices a request
    # when its event loop next runs, so a load can start late - and a
    # check whose placements fell outside the load window would be an
    # idle measurement wearing a load's name. The samples carry the guest
    # ticks of both placements, and the table carries the load's window,
    # so this is decided from the machine's own record.
    verdict = "load not checked"
    if a.load != "idle":
        from rigdrive import pull_dump
        time.sleep(1.0)
        samples, counters = pull_dump(rig, 4)
        by_seq = {s["seq"]: s for s in samples}
        s1, s2 = by_seq.get(1), by_seq.get(2)
        start = counters.get("load_started", 0)
        end = start + counters.get("load_ticks", 0)
        if not s1 or not s2 or not s1["apply"] or not s2["apply"]:
            verdict = ("CANNOT SAY: the guest has no applied sample for "
                       "one of the placements")
        elif start == 0:
            verdict = "THE LOAD NEVER RAN: the starver never started it"
        elif s1["apply"] < start or s2["apply"] > end:
            verdict = (f"THE PLACEMENTS FELL OUTSIDE THE LOAD: placements at "
                       f"{s1['apply']}..{s2['apply']} ticks, load window "
                       f"{start}..{end}. This is an IDLE measurement.")
        else:
            verdict = (f"load window {start}..{end} covers both placements "
                       f"({s1['apply']}, {s2['apply']}) - measured under load")
        print(f"  {verdict}")

    box, n = changed_box(read_ppm(p0), read_ppm(p1))
    print(f"dumps: {p0}\n       {p1}")
    if box is None:
        print(f"CHANGED NOTHING. The position was written and the picture "
              f"did not follow - which is the failure that looks exactly "
              f"like success from inside the guest.")
        return 1
    print(f"changed {n} pixels, bounding box {box}")
    ok_a = contains(box, tuple(a.a))
    ok_b = contains(box, tuple(a.b))
    print(f"  box covers A {tuple(a.a)}: {ok_a}   (the arrow was erased there)")
    print(f"  box covers B {tuple(a.b)}: {ok_b}   (and drawn there)")
    if ok_a and ok_b:
        print("the drawn arrow moved from A to B.")
        return 0 if "outside" not in verdict.lower() and \
            "never ran" not in verdict.lower() else 1
    print("the pixels that changed are NOT where the pointer was asked to "
          "go. Something moved; it was not the cursor going A->B.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
