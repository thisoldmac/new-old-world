#!/usr/bin/env python3
"""Does the SPRITE follow, and what moves when it does?

    tools/local-cursor-sprite.py --qmp .../qmp.sock --port 5510 \
        --lowmem 0x4000 --cursordata 0xd4bd0

The second half of tools/local-cursor-mechanism.py, split out because the
first half answers a question once (where low memory is, and whether
anything overwrites us) and this half is the one you run repeatedly while
changing the resident.

WHAT IT WATCHES, AND WHY IT IS THREE THINGS AND NOT ONE. A cursor that
does not move has at least three separable places to stop, and a
screendump alone cannot tell them apart:

  * the 68K low-memory globals (MTemp / RawMouse / MouseLocation),
  * the Cursor Device Manager's own `CursorData.where`, which is what
    the modern cursor path actually consults,
  * the pixels.

So every step reads all three. `--cursordata` is the physical address of
the live `CursorData` record; find it with `--find-cursordata`, which
scans a memory dump for the record's fingerprint (whereX/whereY are Fixed
with zero fraction, `where` is their integer parts, and `screenRes` is
72.0 fixed) rather than trusting a number somebody wrote down.

The bounding box of the changed pixels is reported and not just the
count. "22 pixels changed" is compatible with a sprite that moved, a
clock that ticked, and a caret that blinked; where they changed is what
distinguishes them.
"""

import argparse
import os
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import nowwire  # noqa: E402

_mech = os.path.join(ROOT, "tools", "local-cursor-mechanism.py")
# Imported by path rather than as a module: the file's name has hyphens,
# which is the project's convention for a `local-*` diagnostic and is not
# an importable identifier. Duplicating three small helpers would be the
# other option and would let them drift.
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location("cursor_mech", _mech)
cursor_mech = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cursor_mech)

Qmp = cursor_mech.Qmp
read_globals = cursor_mech.read_globals
show_globals = cursor_mech.show_globals
diff_pixels = cursor_mech.diff_pixels


def read_cursordata(q, addr):
    raw = q.read_bytes(addr + 8, 14)
    wx, wy = struct.unpack(">ii", raw[0:8])
    v, h = struct.unpack(">hh", raw[8:12])
    return {"whereX": wx / 65536.0, "whereY": wy / 65536.0,
            "where": (h, v), "isAbs": raw[12], "buttons": raw[13]}


def find_cursordata(blob):
    """Every plausible live CursorData in a physical dump.

    The fingerprint that makes this a find rather than a guess is
    `screenRes == 72.0` as a Fixed (0x00480000) sitting exactly where the
    struct says, with whereX/whereY's integer parts equal to `where`."""
    out = []
    for off in range(0, len(blob) - 32, 4):
        if blob[off + 22:off + 26] != b"\x00\x48\x00\x00":
            continue
        wx, wy = struct.unpack(">ii", blob[off + 8:off + 16])
        v, h = struct.unpack(">hh", blob[off + 16:off + 20])
        if (wx >> 16) != h or (wy >> 16) != v:
            continue
        out.append((off, h, v))
    return out


def sprite_report(q, tag, base, cd_addr):
    g = read_globals(q, base)
    show_globals(tag, g)
    if cd_addr:
        print(f"    {'':22} CursorData {read_cursordata(q, cd_addr)}")
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--lowmem", required=True)
    ap.add_argument("--cursordata", default=None)
    ap.add_argument("--find-cursordata", action="store_true")
    ap.add_argument("--shots", default="/private/tmp/nowcursor-shots")
    ap.add_argument("--wait", type=int, default=240)
    args = ap.parse_args()

    base = int(args.lowmem, 0)
    cd = int(args.cursordata, 0) if args.cursordata else None
    os.makedirs(args.shots, exist_ok=True)
    q = Qmp(args.qmp)

    if args.find_cursordata:
        dump = os.path.join(args.shots, "pmem-find.bin")
        q.pmemsave(dump)
        with open(dump, "rb") as fh:
            blob = fh.read()
        for off, h, v in find_cursordata(blob):
            print(f"  CursorData at phys 0x{off:x}  where={h},{v}")
        return 0

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    print(f"guest build: {link.hello.get('build')}")

    def mouseloc():
        rows = link.command("mouseloc", timeout=60).get("mouseloc") or []
        d = {r[0]: r[1] for r in rows if isinstance(r, list) and len(r) == 2}
        return int(d.get("x", -1)), int(d.get("y", -1))

    def cursor_rows():
        """P8's own account of itself, when the resident has one.

        Printed beside the pixels because `route` is the row that decides
        what a zero-pixel result MEANS: a plane that took the low-memory
        route and one that has no device at all both fail to move the
        sprite, and only one of them is a defect."""
        rows = link.command("mouseloc", timeout=60).get("mouseloc") or []
        return {r[0]: r[1] for r in rows
                if isinstance(r, list) and len(r) == 2
                and r[0].startswith("cursor")}

    def any_control():
        for _ in range(12):
            doc = link.scene(full=True, timeout=120)[0]
            for win in doc.get("windows") or []:
                for ctl in win.get("controls") or []:
                    r = ctl.get("rect")
                    if ctl.get("ref") and isinstance(r, dict) \
                            and r.get("r", 0) > r.get("l", 0):
                        return ctl, r
            time.sleep(2)
        return None, None

    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    caps = ext.get("capabilities") or 0
    print(f"resident {ext.get('lifecycle')}  caps={caps} ({bin(caps)})")
    # AGENTS.md's requireTheBuildUnderTest(): every QEMU guest on this Mac
    # sees the host as 10.0.2.2, so any session's VM can answer this
    # listener. Bit 8 is kNowPeekTableCapCursor and no build before today
    # can set it.
    if not caps & 0x100:
        print("  NOTE: bit 8 (cursor plane) is CLEAR - either this is not "
              "the build under test, or the Cursor Device Manager gave "
              "this machine no device. Everything below still runs and "
              "the sprite is expected NOT to follow.")
    else:
        print("  bit 8 set: the Cursor Device Manager answered with a "
              "device.")
    print(f"  P8 says: {cursor_rows()}")

    ctl, r = any_control()
    if ctl is None:
        print("FAIL: nothing with a real rectangle to press on.")
        return 1

    def press():
        # cap=1800 ticks (30 s) and idle=300 (5 s, the clamp ceiling).
        # The first version of this run used idle=300 and then paused for
        # six seconds reading memory, so the DEAD-MAN fired mid-run and
        # the next move answered `conflict` - the vehicle working exactly
        # as designed and reading like a defect. Every pause below is
        # therefore shorter than the idle, or re-presses.
        reply = link.command("dragpress",
                             {"element": ctl["ref"],
                              "h": (r["l"] + r["r"]) // 2,
                              "v": (r["t"] + r["b"]) // 2,
                              "idle": 300, "cap": 1800}, timeout=120)
        rows = {x[0]: x[1] for x in (reply.get("dragpress") or [])
                if isinstance(x, list) and len(x) == 2}
        return int(rows["Session"])

    print("\n== A. the RESIDENT moves the pointer ==")
    session = press()
    link.command("dragmove", {"session": session, "h": 617, "v": 443},
                 timeout=60)
    time.sleep(0.4)
    sprite_report(q, "held at 617,443", base, cd)
    print(f"    {'':22} guest mouseloc {mouseloc()}")
    a = q.screendump(os.path.join(args.shots, "A1-617-443.ppm"))

    link.command("dragmove", {"session": session, "h": 180, "v": 160},
                 timeout=60)
    time.sleep(0.6)
    b = q.screendump(os.path.join(args.shots, "A2-180-160.ppm"))
    sprite_report(q, "moved to 180,160", base, cd)
    print(f"    {'':22} guest mouseloc {mouseloc()}")
    n, box, err = diff_pixels(a, b)
    print(f"  RESIDENT move 617,443 -> 180,160: {n} pixels changed, "
          f"box {box}{'  ' + err if err else ''}")
    print(f"    P8 says: {cursor_rows()}")
    link.command("dragrelease", {"session": session}, timeout=60)

    print("\n== B. the EMULATED DEVICE moves the pointer (positive "
          "control) ==")
    print("  The only QMP input here, and it exists so that 'zero pixels'")
    print("  above can be told from 'the screendump never had a sprite'.")
    time.sleep(0.5)
    c = q.screendump(os.path.join(args.shots, "B1-before-device.ppm"))
    before = sprite_report(q, "before the device move", base, cd)
    q.cmd("input-send-event", {"events": [
        {"type": "rel", "data": {"axis": "x", "value": 200}},
        {"type": "rel", "data": {"axis": "y", "value": 150}}]})
    time.sleep(0.8)
    d = q.screendump(os.path.join(args.shots, "B2-after-device.ppm"))
    sprite_report(q, "after the device move", base, cd)
    print(f"    {'':22} guest mouseloc {mouseloc()}")
    n2, box2, _ = diff_pixels(c, d)
    print(f"  DEVICE move (+200,+150): {n2} pixels changed, box {box2}")
    print(f"    P8 says: {cursor_rows()}")
    del before

    print("\n== the two numbers, side by side ==")
    print(f"  resident move  {n} px  box {box}")
    print(f"  device move    {n2} px  box {box2}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
