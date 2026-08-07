#!/usr/bin/env python3
"""Press a tab, and answer the question TWICE - the machine's own re-read
value, AND the rectangle a person would look at, in the guest's pixels.

    tools/local-tab-settlement.py --port 14849 \
        --qmp /private/tmp/nowvm-x/qmp.sock --target Appearance --tab 4

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody. Everything it prints is the GUEST's own words or the
guest's own framebuffer.

WHY BOTH ANSWERS. Sweep C's version 3 requires a state change to be
confirmed twice, because a machine that agrees with itself can still be
wrong about what is on screen: the scene re-reads the same ControlRecord
the act aimed at, so a control whose value moved while nothing redrew
would read as a success, and a redraw with no value change would read as
a failure. Only the pair separates them.

THE PIXEL HALF IS RECTANGLE-SCOPED AND EXACT. Sweep C scored a false
negative against Date & Time's running clock; a whole-screen diff on this
desk would do the same thing (the menu bar carries a clock). So the
comparison is confined to two rectangles owned by the control under test -
the tab STRIP and the pane BELOW it - and reports the count of differing
pixels rather than a boolean, so "nothing moved" and "everything moved"
are different numbers rather than the same word.

THE WARM-UP SCENE IS DISCARDED, always: the planes arm as a RESULT of the
first scene.request, so a first-on-connection capture is indistinguishable
from a dead plane.
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


class Guest:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.mid = 2000
        self.bulk = {}

    def send(self, obj):
        payload = json.dumps(obj).encode()
        self.sock.sendall(
            struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload)

    def read(self):
        while True:
            while len(self.buf) >= 8:
                chan, flags, transfer, length = struct.unpack(
                    ">BBHI", self.buf[:8])
                if len(self.buf) < 8 + length:
                    break
                body = self.buf[8:8 + length]
                self.buf = self.buf[8 + length:]
                if chan == CONTROL and transfer == 0:
                    return json.loads(body.decode("utf-8", "replace"))
                self.bulk.setdefault(transfer, bytearray()).extend(body)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the connection")
            self.buf += chunk

    def command(self, name, args=None, quiet=False):
        self.mid += 1
        mid = self.mid
        req = {"type": "command.request", "id": mid, "name": name}
        if args:
            req["args"] = args
        self.send(req)
        started = time.time()
        while True:
            msg = self.read()
            if msg.get("type") == "ping":
                self.send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            msg["_ms"] = int((time.time() - started) * 1000)
            if not quiet:
                print("<- %s" % json.dumps(msg, indent=2), flush=True)
            return msg

    def scene(self):
        self.mid += 1
        mid = self.mid
        self.send({"type": "scene.request", "id": mid})
        transfer = None
        while True:
            msg = self.read()
            if msg.get("type") == "ping":
                self.send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("type") == "scene.begin" and msg.get("id") == mid:
                transfer = msg.get("transfer")
                self.bulk.pop(transfer, None)
                continue
            if msg.get("type") == "scene.end" and msg.get("id") == mid:
                body = bytes(self.bulk.pop(transfer, b""))
                if not msg.get("ok"):
                    return None
                return json.loads(body.decode("utf-8", "replace"))
            if msg.get("type") == "error" and msg.get("id") == mid:
                return None


def read_ppm(path):
    """P6 only, which is what QEMU's screendump writes."""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise RuntimeError("not a P6 ppm: %r" % data[:8])
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while i < len(data) and data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    w, h, _maxval = fields
    return w, h, data[i:i + w * h * 3]


def diff_rect(a, b, rect):
    """(differing pixels, total) inside one rectangle. Rects are the
    scene's own l/t/r/b in GLOBAL screen coordinates."""
    (aw, ah, ad), (bw, bh, bd) = a, b
    if (aw, ah) != (bw, bh):
        raise RuntimeError("framebuffers differ in size")
    l = max(0, rect[0]); t = max(0, rect[1])
    r = min(aw, rect[2]); bo = min(ah, rect[3])
    n = same = 0
    for y in range(t, bo):
        row = (y * aw + l) * 3
        end = (y * aw + r) * 3
        n += r - l
        if ad[row:end] == bd[row:end]:
            same += r - l
            continue
        for x in range(0, (end - row) // 3):
            o = row + x * 3
            if ad[o:o + 3] == bd[o:o + 3]:
                same += 1
    return n - same, n


def screendump(qmp_sock, out_ppm):
    lab = os.environ.get("NOW_LAB_ROOT", "/Users/michelle/Lab/Code/timbottu")
    subprocess.run([os.path.join(lab, "tools", "qmp"), qmp_sock, "screendump",
                    json.dumps({"filename": out_ppm})],
                   check=True, capture_output=True)
    return read_ppm(out_ppm)


def content_origin(elements_reply, want_title):
    """The CONTENT origin, from the resolver's own tree - never from the
    scene's `windows[].rect`.

    THE TWENTY POINTS. `scene.windows[].rect` is the STRUCTURE box and
    `elements`' `bounds` is the CONTENT box; on this desk they differ by
    a title bar, and a control rect is content-relative. An instrument
    that adds a content-relative rect to a structure origin aims one
    title bar high - which for a tall control still lands inside and for
    a short one does not. Found by claude/019-list-selection and
    reproduced here before this file was allowed to compute a point:
    Appearance reports scene `t=70` and axtree `top=90`.

    Returns None rather than guessing: a point aimed from an origin
    nobody confirmed is how a sound act gets scored a zero-pixel
    failure. """
    out = (elements_reply.get("output") or {}).get("elements") or {}
    for proc in out.get("processes", []) or []:
        for w in proc.get("windows", []) or []:
            if want_title.lower() in (w.get("title") or "").lower():
                b = w.get("bounds") or {}
                if "left" in b and "top" in b:
                    return b["left"], b["top"]
    return None


def find_tab(scene, want_title):
    for w in scene.get("windows", []):
        if want_title.lower() not in w.get("title", "").lower():
            continue
        for c in w.get("controls", []):
            sem = c.get("semantic") or {}
            if c.get("role") == "tab" or sem.get("kind") == "tab":
                return w, c
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wait", type=float, default=300.0)
    ap.add_argument("--target", default="Appearance")
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--shots", default="/tmp")
    ap.add_argument("--tab", type=int, default=4, help="1-based tab to press")
    ap.add_argument("--tabs", type=int, default=0,
                    help="how many tabs the strip has; 0 = the control's max")
    ap.add_argument("--strip-height", type=int, default=20)
    ap.add_argument("--part", type=int, default=0)
    ap.add_argument("--open", default=None)
    ap.add_argument("--front", action="store_true",
                    help="bring the target forward first, and PROVE the "
                         "press point is not covered before pressing")
    ap.add_argument("--tag", default="tab")
    a = ap.parse_args()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.host, a.port))
    srv.listen(1)
    srv.settimeout(a.wait)
    print("listening on %s:%d" % (a.host, a.port), flush=True)
    sock, _peer = srv.accept()
    sock.settimeout(120.0)
    g = Guest(sock)
    print("guest hello: " + json.dumps(g.read()), flush=True)
    g.send({"type": "hello", "contract": CONTRACT, "side": "host",
            "version": "0", "name": "tab-settlement", "chunk": 4096})

    print("\n== build under test ==", flush=True)
    g.command("axsnap")

    if a.open:
        print("\n== open the target ==", flush=True)
        g.command("script", {"source": a.open})
        time.sleep(8)

    print("\n== WARM-UP scene, discarded ==", flush=True)
    g.scene()

    if a.front:
        print("\n== front the target ==", flush=True)
        g.command("front", {"line": a.target, "name": a.target})
        time.sleep(3)

    scene = g.scene()
    win, ctl = find_tab(scene, a.target)
    if ctl is None:
        print("NO TAB CONTROL in %r - nothing to press" % a.target, flush=True)
        return 2
    origin = content_origin(g.command("elements", quiet=True), a.target)
    if origin is None:
        print("NO CONTENT ORIGIN for %r in `elements` - refusing to aim from "
              "the scene's structure box; see content_origin()" % a.target,
              flush=True)
        return 2
    wr, cr = win["rect"], ctl["rect"]
    ox, oy = origin
    print("  origin          : content %s from `elements`; the scene's "
          "structure box is (%d,%d)" % (origin, wr["l"], wr["t"]), flush=True)
    gl, gt = ox + cr["l"], oy + cr["t"]
    gr, gb = ox + cr["r"], oy + cr["b"]
    tabs = a.tabs or (ctl.get("max") or 6)
    before_value = ctl.get("value")
    width = (gr - gl) / float(tabs)
    ph = int(gl + width * (a.tab - 0.5))
    pv = gt + a.strip_height // 2
    strip = (gl, gt, gr, gt + a.strip_height)
    pane = (gl, gt + a.strip_height, gr, gb)
    print("\n== %s tab control ==\n  window %s\n  control %s -> global "
          "(%d,%d)-(%d,%d)\n  value=%s min=%s max=%s tabs=%d\n"
          "  press tab %d at (%d,%d)\n  strip %s  pane %s"
          % (a.target, wr, cr, gl, gt, gr, gb, before_value, ctl.get("min"),
             ctl.get("max"), tabs, a.tab, ph, pv, strip, pane), flush=True)

    # THE PRECONDITION, CHECKED RATHER THAN ASSUMED.
    #
    # A posted click carries only a POINT. The target application resolves
    # it with its own FindWindow against the machine's global window list -
    # so a point covered by SOMEBODY ELSE'S window resolves to that window
    # and the target does nothing with it. Measured here 2026-08-07: NOW's
    # own Workshop window covers Appearance's whole panel at 800x600, and a
    # press aimed through it moved zero pixels and reported `click posted`.
    # That is the same shape as the defect under investigation and it is
    # not the product, so it has to be excluded before anything is claimed.
    covering = [w for w in scene.get("windows", [])
                if w is not win and (w.get("visible", True))
                and (w.get("z", 99) < win.get("z", 0))
                and w["rect"]["l"] <= ph < w["rect"]["r"]
                and w["rect"]["t"] <= pv < w["rect"]["b"]]
    if covering:
        print("\n  PRESS POINT IS COVERED by %d window(s) in front of the "
              "target - a posted click there belongs to them, not to %s. "
              "Re-pose with --front, or move them." %
              (len(covering), a.target), flush=True)
        for w in covering:
            print("      z=%s %r %s %s" % (w.get("z"), w.get("app"),
                                           w.get("title"), w["rect"]),
                  flush=True)
        return 2
    print("  point is uncovered: %d window(s) in front of the target, none "
          "over (%d,%d)"
          % (sum(1 for w in scene.get("windows", [])
                 if w.get("z", 99) < win.get("z", 0)), ph, pv), flush=True)

    before = screendump(a.qmp, os.path.join(a.shots, "%s-before.ppm" % a.tag))

    print("\n== ctlact part %d ==" % a.part, flush=True)
    t0 = time.time()
    reply = g.command("ctlact", {"element": ctl["ref"], "part": a.part,
                                 "h": ph, "v": pv})
    dispatch_ms = int((time.time() - t0) * 1000)

    time.sleep(3)
    after = screendump(a.qmp, os.path.join(a.shots, "%s-after.ppm" % a.tag))
    after_scene = g.scene()
    _w2, ctl2 = find_tab(after_scene, a.target)
    after_value = ctl2.get("value") if ctl2 else None

    strip_diff, strip_n = diff_rect(before, after, strip)
    pane_diff, pane_n = diff_rect(before, after, pane)

    print("\n===== DOUBLE CONFIRMATION =====", flush=True)
    out = reply.get("output") or {}
    rows = out.get("ctlact") or []
    if not rows:
        print("  act said        : %s"
              % json.dumps(reply.get("error") or reply)[:400], flush=True)
    for row in rows:
        if isinstance(row, list) and len(row) == 2:
            print("      %-18s %s" % (row[0], row[1]), flush=True)
    print("  dispatch        : %d ms" % dispatch_ms, flush=True)
    print("  value           : %s -> %s   (%s)"
          % (before_value, after_value,
             "CHANGED" if before_value != after_value else "IDENTICAL"),
          flush=True)
    print("  strip pixels    : %d of %d differ   (%s)"
          % (strip_diff, strip_n,
             "CHANGED" if strip_diff else "IDENTICAL"), flush=True)
    print("  pane pixels     : %d of %d differ   (%s)"
          % (pane_diff, pane_n,
             "CHANGED" if pane_diff else "IDENTICAL"), flush=True)
    moved = (before_value != after_value) and strip_diff and pane_diff
    print("  VERDICT         : %s"
          % ("the tab switched, confirmed twice" if moved
             else "NOT confirmed twice - see the two rows above"), flush=True)
    return 0 if moved else 1


if __name__ == "__main__":
    sys.exit(main())
