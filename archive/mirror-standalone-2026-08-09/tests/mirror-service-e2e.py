#!/usr/bin/env python3
"""End-to-end test of the agent-facing mirror service (mirror-service-ipc.toml).

Drives a live guest THROUGH mirror.* ONLY — no worker wire, no coordinates —
exercising all fifteen methods on a scripted task. Self-cleaning so it is
repeatable: it clears modals and quits SimpleText at the top rather than
assuming a pristine guest.

    python3 mirror-service-e2e.py <path-to-mirror.sock>
"""
import base64
import json
import os
import socket
import struct
import sys
import time


class Mirror:
    def __init__(self, sock_path):
        self.dir, self.base = os.path.split(sock_path)

    def call(self, method, **params):
        cwd = os.getcwd()
        try:
            os.chdir(self.dir)                       # sun_path length workaround
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(self.base)
        finally:
            os.chdir(cwd)
        payload = json.dumps({"method": method, "params": params},
                             separators=(",", ":"), sort_keys=True).encode()
        s.sendall(struct.pack(">I", len(payload)) + payload)
        s.shutdown(socket.SHUT_WR)                   # half-close per contract
        hdr = b""
        while len(hdr) < 4:
            c = s.recv(4 - len(hdr))
            if not c:
                raise ConnectionError("no reply header")
            hdr += c
        n = struct.unpack(">I", hdr)[0]
        body = b""
        while len(body) < n:
            c = s.recv(min(65536, n - len(body)))
            if not c:
                raise ConnectionError("truncated reply")
            body += c
        s.close()
        reply = json.loads(body)
        if not reply.get("ok"):
            raise RuntimeError(f"{method}: {reply.get('error')}")
        return reply["result"]


def main(sock):
    m = Mirror(sock)
    P, F = [], []

    def check(name, cond, detail=""):
        (P if cond else F).append(name)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}"
              + (f"  — {detail}" if detail else ""))

    def scene(sess, **kw):
        return m.call("mirror.scene", session=sess, **kw)["scene"]

    def windows(sess, kind=8):
        return [w for w in scene(sess)["windows"] if w["kind"] == kind]

    def front(sess, kind=8):
        f = [w for w in windows(sess, kind) if w["front"]]
        return f[0] if f else (windows(sess, kind)[0] if windows(sess, kind) else None)

    def clear_modals(sess, prefer=("Don", "Cancel")):
        for _ in range(6):
            dlg = [w for w in scene(sess)["windows"] if w["kind"] == 2]
            if not dlg:
                return
            for label in prefer:
                c = m.call("mirror.find", session=sess, kind="control",
                           name=label, withinWindow=dlg[0]["id"])["matches"]
                if c:
                    m.call("mirror.act.control", session=sess, ref=c[0]["handle"])
                    time.sleep(0.5)
                    break

    # ---- lifecycle -----------------------------------------------------
    a = m.call("mirror.attach", target="default", planes=["semantic", "tracking"])
    sess = a["session"]
    check("attach grants both planes", a["granted"] == ["semantic", "tracking"],
          f"irVersion={a['irVersion']}")
    st = m.call("mirror.status")
    check("status: worker healthy", st["worker"]["healthy"],
          f"pollMs={st['pollLatencyMs']}, tracking={st['actAvailability']['tracking']}")

    # ---- self-clean: quit SimpleText, clear the desktop ----------------
    clear_modals(sess)
    if any(app["name"] == "SimpleText" for app in scene(sess)["apps"]):
        try:
            m.call("mirror.app", session=sess, op="quit", name="SimpleText")
        except RuntimeError:
            pass
        for _ in range(6):
            clear_modals(sess)
            if not any(app["name"] == "SimpleText" for app in scene(sess)["apps"]):
                break
            time.sleep(0.6)

    # ---- perceive ------------------------------------------------------
    sc = scene(sess, include=["desktop"])
    check("scene: desktop items present", sc.get("desktopItems") is not None,
          f"{len(sc.get('desktopItems') or [])} desktop icons")

    # ---- launch + type (SHORT lines: `type` posts per-char) -----------
    m.call("mirror.app", session=sess, op="launch",
           path="Macintosh HD:Applications (Mac OS 9):SimpleText",
           settle={"frontApp": "SimpleText"})
    check("app.launch SimpleText (settle frontApp)",
          scene(sess)["apps"] and any(x["name"] == "SimpleText"
                                      for x in scene(sess)["apps"]))
    r = m.call("mirror.act.menu", session=sess, menu="File", item="New")
    check("act.menu File>New (keystroke)", r["mechanism"] == "keystroke")
    time.sleep(0.6)
    r = m.call("mirror.act.type", session=sess,
               text="\r".join(f"Line {i}" for i in range(1, 14)) + "\r")
    check("act.type", r["performed"])
    time.sleep(1)

    # ---- window resize + a settle-verified menu-drag dialog + axdo -----
    w = front(sess)
    r = m.call("mirror.act.window", session=sess, window=w["id"], op="zoom")
    check("act.window zoom", r["performed"])
    time.sleep(0.6)

    refused = None
    try:
        m.call("mirror.act.menu", session=sess, menu="File", item="Save As")
    except RuntimeError as e:
        refused = str(e)
    check("act.menu Save As refused without allowDrag",
          refused is not None and "allowDrag" in refused)
    r = m.call("mirror.act.menu", session=sess, menu="File", item="Save As",
               allowDrag=True, settle={"dialogPresent": True})
    check("act.menu Save As (allowDrag) opens dialog",
          r["performed"] and r["settle"]["met"], f"mechanism={r['mechanism']}")
    dlg = [x for x in scene(sess)["windows"] if x["kind"] == 2][0]
    cc = m.call("mirror.find", session=sess, kind="control", name="cancel",
                withinWindow=dlg["id"])["matches"]
    r = m.call("mirror.act.control", session=sess, ref=cc[0]["handle"],
               settle={"dialogPresent": False})
    check("act.control Cancel (axdo) closes the dialog",
          r["performed"] and r["settle"]["met"])

    # ---- shot ----------------------------------------------------------
    sh = m.call("mirror.shot", session=sess)
    check("mirror.shot renders a PNG", sh["bytes"] > 1000,
          f"{sh['bytes']} bytes {sh['width']}x{sh['height']}")
    out = os.path.join(os.path.dirname(sock), "e2e-shot.png")
    open(out, "wb").write(base64.b64decode(sh["png"]))

    # ---- wait times out cleanly on a false predicate -------------------
    w8 = m.call("mirror.wait", session=sess,
                until={"windowExists": "NoSuchWindow"}, timeoutMs=1200)
    check("mirror.wait times out on a false predicate", not w8["met"],
          f"{w8['elapsedMs']}ms")

    # ---- close the doc (Don't Save) ------------------------------------
    w = front(sess)
    if w:
        m.call("mirror.act.window", session=sess, window=w["id"], op="close")
        time.sleep(0.6)
        clear_modals(sess, prefer=("Don",))

    # ---- scroll SURFACE (find + dispatch) on a Finder window -----------
    # The scroll METHODS are what this validates: find surfaces a live
    # scrollbar with its orientation/range, and act.scroll resolves the
    # window, selects the vertical bar, gates on the plane, and dispatches.
    # The precise landing of the QMP actuation is proven deterministically by
    # the actuation battery (same ActionModel path); guest-app quirks make the
    # LIVE value round-trip finicky (SimpleText under-reports its scrollbar
    # range; Finder chrome geometry shifts landing), tracked as a follow-up in
    # `mirror-service-agent-surface`.
    m.call("mirror.act.open", session=sess, desktopItem="Macintosh HD",
           settle={"frontApp": "Finder"})
    time.sleep(1.5)
    fw = next((w for w in scene(sess)["windows"]
               if w.get("title") == "Macintosh HD"), None)
    if fw:
        m.call("mirror.act.window", session=sess, window=fw["id"], op="resize",
               dx=-40, dy=-160)
        time.sleep(1.2)
        bars = m.call("mirror.find", session=sess, kind="scrollbar",
                      withinWindow=fw["id"])["matches"]
        vbar = next((b for b in bars if b.get("orientation") == "vertical"
                     and b.get("max", 0) > b.get("min", 0)), None)
        check("find surfaces a live scrollbar (orientation+range)",
              vbar is not None,
              f"{vbar['min']}..{vbar['max']} val={vbar['value']}" if vbar else "none")
        if vbar:
            r = m.call("mirror.act.scroll", session=sess, window=fw["id"],
                       by={"lines": 2})
            check("act.scroll dispatches (line, vertical default)",
                  r["performed"] and r["mechanism"] == "lineDown")
            r = m.call("mirror.act.scroll", session=sess, window=fw["id"],
                       to=(vbar["min"] + vbar["max"]) // 2,
                       scrollbar=vbar["handle"])
            check("act.scroll dispatches (thumb, explicit ref)",
                  r["performed"] and r["mechanism"] == "thumb-drag")
        m.call("mirror.act.window", session=sess, window=fw["id"], op="close")
    else:
        check("Finder window for scroll-surface test", False, "no window")
    m.call("mirror.detach", session=sess)

    # ---- plane gating (isolated semantic-only session) -----------------
    g = m.call("mirror.attach", target="default", planes=["semantic"])
    s2 = g["session"]
    check("semantic-only attach drops the tracking grant",
          g["granted"] == ["semantic"])
    gate = None
    try:
        m.call("mirror.act.scroll", session=s2, window="x", by={"lines": 1})
    except RuntimeError as e:
        gate = str(e)
    check("tracking act refused with plane_not_granted (before element lookup)",
          gate is not None and "plane_not_granted" in gate)
    check("a semantic act still works on that session",
          m.call("mirror.act.key", session=s2, key="escape")["performed"])
    m.call("mirror.detach", session=s2)

    print(f"\n===== mirror service e2e: {len(P)} passed, {len(F)} failed =====")
    if F:
        print("  FAILURES:", F)
    return 0 if not F else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "mirror.sock"))
