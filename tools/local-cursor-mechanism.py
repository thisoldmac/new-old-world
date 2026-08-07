#!/usr/bin/env python3
"""Why does the guest's DRAWN cursor not follow what the resident writes?

    tools/local-cursor-mechanism.py --qmp /private/tmp/nowvm-x/qmp.sock \
                                    --port 5510

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody. It establishes a MECHANISM before anybody writes a fix,
because a fix that works because a rig detail changed is not a fix.

THE OBSERVATION IT STARTS FROM. The drag vehicle (P7) writes MTemp,
RawMouse, MouseLocation and then `CrsrNew = CrsrCouple`, the documented
Inside Macintosh recipe for asking the cursor VBL task to redraw. On
QEMU/mac99 the Toolbox follows every write - the guest's own `mouseloc`
reports exactly the points it was given - and the SPRITE does not move:
two screendumps either side of a 477-pixel drag differ by zero pixels.

THE INSTRUMENT THAT WAS MISSING. Every previous look at this asked the
GUEST what it thought. This one reads the machine's low memory from
OUTSIDE, through QMP, so the bytes the cursor task actually consults can
be compared against what the resident believes it wrote. Three questions
the guest cannot answer about itself:

  1. Is `CrsrCouple` non-zero? `CrsrNew = CrsrCouple` writes ZERO into
     CrsrNew when the cursor is decoupled, which is a request for
     nothing. A whole plausible cause, invisible from inside.
  2. Does our write to `CrsrNew` SURVIVE, or is it consumed (cleared by
     the task, which would mean the task ran and declined) or clobbered?
  3. Do the mouse globals stay where the resident put them, or does the
     emulated pointing device overwrite them? That is the hypothesis
     that would make metal the EASY case and the emulator the hard one,
     and it is worth being definite about in either direction.

WHERE LOW MEMORY ACTUALLY IS, AND WHY THIS SCRIPT LOOKS FOR IT.
Physical 0x828 on a Power Mac is NOT MTemp - it holds PowerPC exception
code, checked on this rig. Mac OS's 68K low-memory globals live at a
logical address the nanokernel maps somewhere else in RAM, and the offset
is not something to guess. So the script FINDS the window rather than
assuming one: it drives the pointer to a distinctive point through the
resident's own drag vehicle, dumps physical memory, and looks for the
three adjacent copies of that point that MTemp / RawMouse /
MouseLocation are. Three Points, four bytes apart, equal to a number
only this run chose - that is a fingerprint, not a coincidence, and if it
is not found the script says so and reports nothing rather than reading a
plausible wrong address.

QMP HERE IS AN OBSERVER, with one deliberate exception. `input-send-event`
is used ONCE, as the positive control - "this is what a sprite that moved
looks like in a screendump" - and never to produce a result. Read
docs/no-hijack-criterion.md before adding a second use.
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402


# Inside Macintosh's offsets, stated once - the same rule
# ext/src/now_ext_drag.c follows, and for the same reason: two
# similarly-named constant sets spelled inline cost a day once already.
# These are LOGICAL 68K addresses; the window base is discovered.
LOWMEM = [
    ("MTemp", 0x0828, 4, "the cursor VBL's staging point (v,h)"),
    ("RawMouse", 0x082C, 4, "the cursor's own position (v,h)"),
    ("MouseLocation", 0x0830, 4, "what GetMouse reports (v,h)"),
    ("CrsrBusy", 0x08CD, 1, "non-zero: the task must not draw"),
    ("CrsrNew", 0x08CE, 1, "non-zero: please redraw"),
    ("CrsrCouple", 0x08CF, 1, "non-zero: the cursor follows the mouse"),
    ("CrsrState", 0x08D0, 2, "0: the cursor may be drawn"),
    ("CrsrObscure", 0x08D2, 1, "non-zero: hidden until the mouse moves"),
    ("JCrsrTask", 0x08EE, 4, "the cursor task's jump vector"),
    ("MBState", 0x0172, 1, "0x00 down / 0x80 up"),
]

POINT_KEYS = ("MTemp", "RawMouse", "MouseLocation")
DUMP_BYTES = 64 * 1024 * 1024      # the first 64 MB; low memory is early


class Qmp:
    """One connection, many commands. tools/qmp is one-shot and this
    script issues dozens; reconnecting per read would put seconds of
    socket churn inside a measurement about timing."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(60)
        self.sock.connect(path)
        self.f = self.sock.makefile("rw", encoding="utf-8", newline="\n")
        self.f.readline()                       # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, args=None):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\r\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError("QMP closed")
            reply = json.loads(line)
            if "return" in reply:
                return reply["return"]
            if "error" in reply:
                raise RuntimeError(f"QMP {name}: {reply['error']}")

    def hmp(self, line):
        return self.cmd("human-monitor-command", {"command-line": line})

    def read_bytes(self, addr, count):
        """`xp/Nxb` and parse. The monitor prints `addr: b0 b1 ...` with
        up to 8 bytes a line, so this is a parse and not a slice."""
        out = self.hmp(f"xp/{count}xb 0x{addr:x}")
        vals = []
        for row in out.replace("\r", "\n").split("\n"):
            if ":" not in row:
                continue
            for tok in row.split(":", 1)[1].split():
                if tok.startswith("0x"):
                    vals.append(int(tok, 16))
        if len(vals) < count:
            raise RuntimeError(f"xp at 0x{addr:x} returned {out!r}")
        return bytes(vals[:count])

    def pmemsave(self, path, size=DUMP_BYTES):
        if os.path.exists(path):
            os.unlink(path)
        self.cmd("pmemsave", {"val": 0, "size": size, "filename": path})
        return path

    def screendump(self, path):
        if os.path.exists(path):
            os.unlink(path)
        self.cmd("screendump", {"filename": path})
        # QEMU has written it by the time the reply lands, but a zero-byte
        # file read as "no pixels changed" once, so wait for it to settle.
        for _ in range(100):
            if os.path.exists(path) and os.path.getsize(path) > 0:
                a = os.path.getsize(path)
                time.sleep(0.2)
                if os.path.getsize(path) == a:
                    return path
            time.sleep(0.2)
        raise RuntimeError(f"screendump never landed at {path}")


# ---------------------------------------------------------------- window

def find_lowmem_base(dump_path, h, v):
    """Where the 68K low-memory globals are in PHYSICAL memory.

    The fingerprint is three copies of one Point, four bytes apart:
    MTemp at 0x828, RawMouse at 0x82C, MouseLocation at 0x830. A Point is
    (v, h) big-endian, in that order, which is the Toolbox's order and
    the reversal every reader of this file gets wrong once.

    Returns a list of candidate bases; more than one is reported rather
    than picked, because "I found several and chose" is the shape of a
    wrong answer nobody can audit."""
    needle = struct.pack(">hh", v, h)
    triple = needle * 3
    with open(dump_path, "rb") as fh:
        blob = fh.read()
    bases, at = [], 0
    while True:
        at = blob.find(triple, at)
        if at < 0:
            break
        bases.append(at - 0x828)
        at += 2
    return bases, blob


def read_globals(q, base):
    """Every global in one pass, as name -> (raw, pretty)."""
    seen = {}
    for name, off, size, _why in LOWMEM:
        raw = q.read_bytes(base + off, size)
        if name in POINT_KEYS:
            v, h = struct.unpack(">hh", raw)
            pretty = f"{h},{v}"                  # h,v the way a person says it
        elif size == 4:
            pretty = "0x%08x" % struct.unpack(">I", raw)[0]
        elif size == 2:
            pretty = "0x%04x" % struct.unpack(">H", raw)[0]
        else:
            pretty = "0x%02x" % raw[0]
        seen[name] = (raw, pretty)
    return seen


def show_globals(tag, g):
    order = ("MouseLocation", "RawMouse", "MTemp", "CrsrNew", "CrsrCouple",
             "CrsrBusy", "CrsrState", "CrsrObscure", "MBState")
    print(f"    {tag:<22} " + "  ".join(f"{k}={g[k][1]}" for k in order))


# ---------------------------------------------------------------- pixels

def read_ppm(path):
    with open(path, "rb") as fh:
        data = fh.read()
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
    w, h, _mx = fields
    return w, h, data[i:i + w * h * 3]


def diff_pixels(a, b):
    """How many pixels differ, and WHERE their bounding box is.

    The count alone was the drag lane's calibration - 22 pixels for a
    pointing device that really moved - and it is not enough here: a
    sprite that moved to the wrong place and a sprite that did not move
    are both "some pixels changed". The box is what says which."""
    wa, ha, pa = read_ppm(a)
    wb, hb, pb = read_ppm(b)
    if (wa, ha) != (wb, hb):
        return None, None, "framebuffer changed size between shots"
    n = 0
    box = None
    for idx in range(0, len(pa), 3):
        if pa[idx:idx + 3] != pb[idx:idx + 3]:
            p = idx // 3
            x, y = p % wa, p // wa
            n += 1
            box = ([x, y, x, y] if box is None else
                   [min(box[0], x), min(box[1], y),
                    max(box[2], x), max(box[3], y)])
    return n, box, None


# ------------------------------------------------------------------ run

def any_control(doc):
    for win in doc.get("windows") or []:
        for ctl in win.get("controls") or []:
            r = ctl.get("rect")
            if ctl.get("ref") and isinstance(r, dict) \
                    and r.get("r", 0) > r.get("l", 0):
                return ctl, win
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=int, default=240)
    ap.add_argument("--shots", default=None)
    args = ap.parse_args()

    shots = args.shots or os.path.join(
        os.environ.get("TMPDIR", "/tmp"), "now-cursor-shots")
    os.makedirs(shots, exist_ok=True)
    q = Qmp(args.qmp)
    print(f"QMP: {q.cmd('query-name').get('name')}   artifacts: {shots}")

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    print(f"guest build: {link.hello.get('build')}")
    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    caps = ext.get("capabilities") or 0
    print(f"resident {ext.get('lifecycle')}  caps={caps} ({bin(caps)})  "
          f"tableLength={ext.get('tableLength')}")
    if not caps & 0x80:
        print("FAIL: no drag vehicle (bit 7 clear). Nothing below could "
              "move a pointer from inside the guest.")
        return 1

    def mouseloc():
        rows = link.command("mouseloc", timeout=60).get("mouseloc") or []
        d = {r[0]: r[1] for r in rows if isinstance(r, list) and len(r) == 2}
        return int(d.get("x", -1)), int(d.get("y", -1))

    print("\n== 1. a target to press on ==")
    doc = None
    for _ in range(12):
        doc = link.scene(full=True, timeout=120)[0]
        if "ok" in [p.get("bind") for p in (doc.get("processes") or [])]:
            break
        time.sleep(2)
    ctl, win = any_control(doc)
    if ctl is None:
        print("FAIL: no control with a real rectangle; nothing to press on.")
        return 1
    r = ctl["rect"]
    print(f"  {ctl.get('title') or ctl['ref']} in "
          f"{(win or {}).get('title')} at {r}")

    # A DISTINCTIVE point, on purpose. The window search below is a byte
    # pattern, and a round number like 100,100 appears all over a running
    # Macintosh. 617,443 does not.
    HOLD_H, HOLD_V = 617, 443
    print(f"\n== 2. hold the pointer at {HOLD_H},{HOLD_V} through the "
          f"resident ==")
    press = link.command("dragpress", {"element": ctl["ref"],
                                       "h": (r["l"] + r["r"]) // 2,
                                       "v": (r["t"] + r["b"]) // 2,
                                       "idle": 300, "cap": 1800}, timeout=120)
    rows = {x[0]: x[1] for x in (press.get("dragpress") or [])
            if isinstance(x, list) and len(x) == 2}
    session = int(rows["Session"])
    link.command("dragmove", {"session": session, "h": HOLD_H, "v": HOLD_V},
                 timeout=60)
    time.sleep(0.5)
    said = mouseloc()
    print(f"  the guest's own mouseloc says {said[0]},{said[1]}")
    if said != (HOLD_H, HOLD_V):
        print("  the Toolbox did NOT follow the vehicle; that is a "
              "different defect from the one this script is about.")

    print("\n== 3. WHERE IS LOW MEMORY? (found, not assumed) ==")
    dump = os.path.join(shots, "pmem.bin")
    q.pmemsave(dump)
    bases, blob = find_lowmem_base(dump, HOLD_H, HOLD_V)
    print(f"  dumped {os.path.getsize(dump)} bytes; MTemp/RawMouse/Mouse "
          f"fingerprint for {HOLD_H},{HOLD_V} found at "
          f"{[hex(b) for b in bases]}")
    if len(bases) != 1:
        print("  REFUSING to read a window this run cannot pin down. "
              "Nothing below would be attributable.")
        link.command("dragrelease", {"session": session}, timeout=60)
        return 1
    base = bases[0]
    print(f"  low-memory base = 0x{base:x}  (so MTemp is physical "
          f"0x{base + 0x828:x})")
    print("  This is the instrument every number below rests on, and it "
          "is PROVEN by the point rather than assumed from a manual.")

    print("\n== 4. the cursor globals, while the resident holds the "
          "pointer ==")
    g_held = read_globals(q, base)
    show_globals("held at 617,443", g_held)
    couple = g_held["CrsrCouple"][0][0]
    if couple == 0:
        print("  >>> CrsrCouple is ZERO. `CrsrNew = CrsrCouple` therefore")
        print("      writes zero, which asks the cursor task for NOTHING.")
        print("      That alone would explain an invisible drag.")
    else:
        print(f"  CrsrCouple is 0x{couple:02x}: the copy DOES set CrsrNew, "
              f"so the redraw was asked for.")
    print(f"  CrsrNew right now is {g_held['CrsrNew'][1]} - zero here means "
          f"the cursor task RAN and consumed the request.")

    print("\n== 5. does anything overwrite the resident's writes? ==")
    print("  Nothing touches the host pointer during this window. If the")
    print("  emulated device were clobbering us, these would drift.")
    for i in range(3):
        time.sleep(1.5)
        g = read_globals(q, base)
        show_globals(f"+{1.5 * (i + 1):.1f}s, untouched", g)
    stable = read_globals(q, base)
    drifted = [k for k in POINT_KEYS
               if stable[k][1] != g_held[k][1]]
    if drifted:
        print(f"  >>> {', '.join(drifted)} MOVED with nobody driving. "
              f"Something else writes these.")
    else:
        print("  Not one of the three moved. NOTHING is overwriting the "
              "resident's writes on this rig.")

    print("\n== 6. does the SPRITE follow? (a screendump pair) ==")
    before = q.screendump(os.path.join(shots, "a-held-617-443.ppm"))
    link.command("dragmove", {"session": session, "h": 180, "v": 160},
                 timeout=60)
    time.sleep(1.0)
    after = q.screendump(os.path.join(shots, "b-held-180-160.ppm"))
    n, box, err = diff_pixels(before, after)
    print(f"  617,443 -> 180,160 changed {n} pixels" +
          (f", bounding box {box}" if box else ""))
    g_moved = read_globals(q, base)
    show_globals("after the move", g_moved)
    print(f"  the guest's mouseloc now says {mouseloc()}")

    print("\n== 7. THE POSITIVE CONTROL: move the emulated device ==")
    print("  The only QMP INPUT in this script, and it exists so that")
    print("  'zero pixels changed' above can be told from 'the screendump")
    print("  does not capture the sprite at all'.")
    link.command("dragrelease", {"session": session}, timeout=60)
    time.sleep(0.5)
    c_before = q.screendump(os.path.join(shots, "c-before-device.ppm"))
    q.cmd("input-send-event", {"events": [
        {"type": "rel", "data": {"axis": "x", "value": 120}},
        {"type": "rel", "data": {"axis": "y", "value": 90}}]})
    time.sleep(1.0)
    c_after = q.screendump(os.path.join(shots, "d-after-device.ppm"))
    n2, box2, _ = diff_pixels(c_before, c_after)
    print(f"  a real device move changed {n2} pixels" +
          (f", bounding box {box2}" if box2 else ""))
    g_dev = read_globals(q, base)
    show_globals("after the device move", g_dev)

    print("\n== what this run establishes ==")
    print(f"  low-memory window   0x{base:x} (proven by the point)")
    print(f"  CrsrCouple          {g_held['CrsrCouple'][1]}")
    print(f"  resident's writes   {'drifted' if drifted else 'stable'}")
    print(f"  sprite on a resident move   {n} pixels changed")
    print(f"  sprite on a device move     {n2} pixels changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
