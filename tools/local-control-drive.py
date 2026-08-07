#!/usr/bin/env python3
"""Did the CDEF route classify anything, and can a POINT drive what the
part code could not?

    tools/local-control-drive.py --port 16745 --target Appearance

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody. It impersonates a host the way `tools/askguest.py` does,
so everything it prints is the GUEST's own words.

THE TWO QUESTIONS, and they are separate on purpose (slice 18's finding
is that classification and usability came apart):

  1. CLASSIFICATION. Count every control's `semantic.knowledge` per
     window - `known` (the control answered `kControlKindTag`), `derived`
     (the Resource Manager named the CDEF that draws it) and `unknown`
     (nobody could say) - and print the kinds the derived ones reached.
  2. USABILITY. Take a control of a named kind, send `ctlact` with an
     explicit point inside its rect, and screendump the guest before and
     after so a person can see whether anything moved.

THE WARM-UP SCENE IS DISCARDED, always. The planes arm as a RESULT of the
first `scene.request`, so a first-on-connection capture returns every role
`unknown` and is indistinguishable from the real defect. Passes are
repeated and the run says whether they agreed, because a single capture
cannot tell a steady state from a transient.
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
        self.mid = 1000
        self.bulk = {}

    def send(self, obj):
        payload = json.dumps(obj).encode()
        self.sock.sendall(
            struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload)

    def read(self):
        """One control message. Bulk (non-zero transfer) frames are
        accumulated by transfer id rather than parsed as JSON - a scene
        arrives as a transfer, and a reader that tried to json.loads one
        would die on the first byte."""
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
        while True:
            msg = self.read()
            if msg.get("type") == "ping":
                self.send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            if not quiet:
                print("<- " + json.dumps(msg)[:400], flush=True)
            return msg

    def scene(self):
        """One whole scene document, reassembled from its transfer."""
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


def tally(scene, want_title=None):
    """Per window: how many controls reached each knowledge level, and
    which kinds the derived ones named."""
    rows = []
    for w in scene.get("windows", []):
        title = w.get("title", "")
        if want_title and want_title.lower() not in title.lower():
            continue
        counts = {}
        kinds = {}
        for c in w.get("controls", []):
            sem = c.get("semantic") or {}
            k = sem.get("knowledge", "(absent)")
            counts[k] = counts.get(k, 0) + 1
            if k == "derived":
                kind = sem.get("kind", "?")
                kinds[kind] = kinds.get(kind, 0) + 1
        rows.append((w.get("app", "?"), title,
                     len(w.get("controls", [])), counts, kinds))
    return rows


def controls_of(scene, want_title, kinds):
    out = []
    for w in scene.get("windows", []):
        if want_title and want_title.lower() not in w.get("title", "").lower():
            continue
        for c in w.get("controls", []):
            sem = c.get("semantic") or {}
            if sem.get("kind") in kinds and c.get("ref"):
                out.append((c, sem, w))
    return out


def axtree_content_origins(g):
    """Window title -> the GLOBAL top-left of its content port.

    `axtree` reports a window's `bounds` as the content rect in global
    coordinates - the same frame `ctlact` takes its point in - which is the
    one number the scene document does not carry. Titles are the join, and a
    duplicated title is dropped rather than resolved: aiming at the wrong
    window of two with the same name is the failure this whole tool exists to
    avoid, and it would look exactly like a working drive.
    """
    reply = g.command("axtree", quiet=True)
    out, seen = {}, {}
    for proc in ((reply.get("output") or {}).get("axtree") or {}) \
            .get("processes", []):
        for w in proc.get("windows", []):
            title = w.get("title", "")
            bounds = w.get("bounds") or {}
            seen[title] = seen.get(title, 0) + 1
            out[title] = (bounds.get("left", 0), bounds.get("top", 0))
    return {t: o for t, o in out.items() if seen.get(t) == 1}


def screendump(qmp_sock, out):
    ppm = out + ".ppm"
    lab = os.environ.get("NOW_LAB_ROOT", "/Users/michelle/Lab/Code/timbottu")
    subprocess.run([os.path.join(lab, "tools", "qmp"), qmp_sock, "screendump",
                    json.dumps({"filename": ppm})],
                   check=False, capture_output=True)
    subprocess.run(["sips", "-s", "format", "png", ppm, "--out", out],
                   check=False, capture_output=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=16745)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wait", type=float, default=300.0)
    ap.add_argument("--target", default="Appearance")
    ap.add_argument("--open", default=None,
                    help="an AppleScript to run first, e.g. to open a panel")
    ap.add_argument("--passes", type=int, default=3)
    ap.add_argument("--qmp", default=None)
    ap.add_argument("--shots", default="/tmp")
    ap.add_argument("--drive", default="",
                    help="comma-separated kinds to drive, e.g. tab,listBox")
    a = ap.parse_args()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.host, a.port))
    srv.listen(1)
    srv.settimeout(a.wait)
    print(f"listening on {a.host}:{a.port}", flush=True)
    sock, peer = srv.accept()
    sock.settimeout(60.0)
    g = Guest(sock)
    hello = g.read()
    print("guest hello: " + json.dumps(hello), flush=True)
    g.send({"type": "hello", "contract": CONTRACT, "side": "host",
            "version": "0", "name": "control-drive", "chunk": 4096})

    print("\n== build under test ==", flush=True)
    g.command("axsnap")

    if a.open:
        print("\n== open the target ==", flush=True)
        g.command("script", {"source": a.open})
        time.sleep(6)

    print("\n== WARM-UP scene, discarded ==", flush=True)
    warm = g.scene()
    print("  discarded (%d bytes of apps)" %
          (len(json.dumps(warm.get("apps", []))) if warm else -1), flush=True)

    seen = []
    for i in range(a.passes):
        s = g.scene()
        if s is None:
            print(f"  pass {i+1}: no scene", flush=True)
            continue
        rows = tally(s, a.target)
        seen.append(rows)
        for name, title, n, counts, kinds in rows:
            print(f"  pass {i+1}: {name} / {title!r}: {n} controls "
                  f"{counts} derived-kinds={kinds}", flush=True)
    if len(seen) > 1:
        print("  steady: %s" % ("yes" if all(r == seen[0] for r in seen)
                                else "NO - passes disagree"), flush=True)

    if not a.drive:
        return 0

    kinds = [k for k in a.drive.split(",") if k]
    content_origins = axtree_content_origins(g)
    scene = g.scene()
    targets = controls_of(scene, a.target, kinds)
    print(f"\n== drive: {len(targets)} control(s) of kind {kinds} ==",
          flush=True)
    for c, s, w in targets:
        rect = c.get("rect", {})
        win = w.get("rect", {})
        # The scene reports a control rect CONTENT-relative; ctlact's point
        # is GLOBAL, which is the window's content origin plus that.
        #
        # AND THE SCENE'S OWN WINDOW RECT IS NOT THAT ORIGIN. `windows[].rect`
        # is the STRUCTURE box - the content port grown UP by the title bar -
        # while `controls[].rect` is content-relative, so adding the two puts
        # every point one title bar too HIGH. Measured 2026-08-07 on mac99 /
        # OS 9.1: Extensions Manager reported `windows[].rect.t = 51` in the
        # scene and `bounds.top = 71` in `axtree`, and the Finder's own "Name"
        # column header (content t=21..42) lands at global 124..145 with the
        # axtree origin and at 104..125 - the info bar above it - with this
        # one. Twenty points, and nothing in either document says so.
        #
        # So the origin comes from `axtree`, whose window bounds ARE the
        # global content rect, rather than from a constant 20 written here.
        # A tall control absorbed the error and the drives that found this
        # instrument useful were the tall ones; a list ROW is 16 px, which is
        # smaller than the error.
        ox = win.get("l", 0)
        oy = win.get("t", 0)
        origin = content_origins.get(w.get("title", ""))
        if origin is not None:
            ox, oy = origin
        else:
            print("  [warn] axtree named no content origin for "
                  f"{w.get('title')!r}; using the structure rect, which is "
                  "a title bar too high", flush=True)
        gh = ox + (rect.get("l", 0) + rect.get("r", 0)) // 2
        gv = oy + (rect.get("t", 0) + rect.get("b", 0)) // 2
        print(f"\n-- {s.get('kind')} {c.get('title')!r} rect={rect} "
              f"window origin=({ox},{oy}) point=({gh},{gv})", flush=True)
        if a.qmp:
            screendump(a.qmp, os.path.join(
                a.shots, f"before-{s.get('kind')}-{gh}x{gv}.png"))
        # part 0: answer TrackControl with nothing, so the application's
        # own tracking decides from where the click landed.
        g.command("ctlact", {"element": c["ref"], "part": 0,
                             "h": gh, "v": gv})
        time.sleep(3)
        if a.qmp:
            screendump(a.qmp, os.path.join(
                a.shots, f"after-{s.get('kind')}-{gh}x{gv}.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
