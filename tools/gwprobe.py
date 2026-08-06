#!/usr/bin/env python3
"""The GWorld probe's driver (docs/gworld-probe-brief.md). Throwaway.

Listens as a NOW host on --port, takes the next guest dial-in, and runs
one probe phase: front the target app, fetch a scene (the one wire
surface that reports raw window addresses), arm `qdtrace start` in probe
mode on the target's front window, wait through redraws and the chase,
then drain everything and save raw replies plus a per-port summary.

    gwprobe.py --port 5321 --label finder-icon --app Finder
    gwprobe.py --port 5321 --label simpletext --app SimpleText \
               --launch "SimpleText"
"""

import argparse, json, os, socket, struct, sys, time

# The frame numbers and the contract revision come from contract/, never
# from a literal here: a harness that declares its own revision is how
# tools/askguest.py sat on revision 1 for a whole revision without
# anyone noticing (WireLimitsAgreementTests gates it).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION)

class Guest:
    def __init__(self, port, wait=90, timeout=45):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(1)
        srv.settimeout(wait)
        print("listening on %d ..." % port, flush=True)
        self.sock, peer = srv.accept()
        srv.close()
        self.sock.settimeout(timeout)
        self.buf = b""
        self.mid = 500
        self.log = []
        hello = self.read_frame()[3]
        self.hello = json.loads(hello.decode("utf-8", "replace"))
        print("guest: %s" % self.hello.get("build"), flush=True)
        self.send_json({"type": "hello", "contract": WIRE_CONTRACT_REVISION,
                        "side": "host",
                        "version": "0", "name": "gwprobe", "chunk": 4096})

    def read_frame(self):
        while True:
            while len(self.buf) >= 8:
                ch, fl, xf, ln = struct.unpack(">BBHI", self.buf[:8])
                if len(self.buf) < 8 + ln:
                    break
                payload = self.buf[8:8 + ln]
                self.buf = self.buf[8 + ln:]
                return ch, fl, xf, payload
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the connection")
            self.buf += chunk

    def send_json(self, obj):
        payload = json.dumps(obj).encode()
        self.sock.sendall(struct.pack(">BBHI", CONTROL, END, 0,
                                      len(payload)) + payload)

    def control(self):
        """Next control-channel JSON, answering pings along the way."""
        while True:
            ch, fl, xf, payload = self.read_frame()
            if ch != CONTROL:
                continue
            msg = json.loads(payload.decode("utf-8", "replace"))
            if msg.get("type") == "ping":
                self.send_json({"type": "pong", "id": msg.get("id", 0)})
                continue
            return msg

    def command(self, name, args=None):
        self.mid += 1
        req = {"type": "command.request", "id": self.mid, "name": name}
        if args:
            req["args"] = args
        self.send_json(req)
        while True:
            msg = self.control()
            if msg.get("id") == self.mid:
                self.log.append({"request": req, "reply": msg})
                return msg

    def scene(self):
        """scene.request -> begin + bulk frames + end -> parsed JSON."""
        self.mid += 1
        self.send_json({"type": "scene.request", "id": self.mid})
        doc = b""
        began = False
        while True:
            ch, fl, xf, payload = self.read_frame()
            if ch == CONTROL:
                msg = json.loads(payload.decode("utf-8", "replace"))
                if msg.get("type") == "ping":
                    self.send_json({"type": "pong", "id": msg.get("id", 0)})
                    continue
                t = msg.get("type", "")
                if t == "scene.begin":
                    began = True
                    continue
                if t == "scene.end":
                    if not msg.get("ok", True):
                        raise RuntimeError("scene refused: %s" % msg)
                    return json.loads(doc.decode("utf-8", "replace"))
                continue
            if began:
                doc += payload

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--app", required=True,
                    help="scene app name to arm (match on window rows)")
    ap.add_argument("--launch", help="launch this target first")
    ap.add_argument("--front", help="front this target first (defaults to --app)")
    ap.add_argument("--no-front", action="store_true")
    ap.add_argument("--open-new", action="store_true",
                    help="drive File > New if the app has no window")
    ap.add_argument("--pre", action="append", default=[],
                    help="verb[:k=v,...] to issue BEFORE arming (build the "
                         "composite the chase is meant to sight)")
    ap.add_argument("--repaint", default="resize",
                    choices=("resize", "hide-reveal", "none"),
                    help="how to force a SECOND composite once the GWorld "
                         "is hooked, without re-arming (which unhooks it)")
    ap.add_argument("--after", action="append", default=[],
                    help="verb[:k=v,...] to issue after arming")
    ap.add_argument("--reveal", help="reveal this path in the Finder first")
    ap.add_argument("--type", dest="type_text",
                    help="after arming, post these keys to the front app")
    ap.add_argument("--mode", default="probe")
    ap.add_argument("--ttl", type=int, default=7200)
    ap.add_argument("--settle", type=float, default=10.0)
    ap.add_argument("--drain-seconds", type=float, default=0.0,
                    help="keep draining LIVE for this long after the ring "
                         "empties. A source that draws faster than the ring "
                         "holds (the loop control blits every pass) laps the "
                         "arm-time cursor, and a single drain then resyncs "
                         "to live and answers empty - measured 2026-08-06, "
                         "0 records against 915 recorded ops.")
    ap.add_argument("--outdir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "gwprobe-out"))
    a = ap.parse_args()

    outdir = os.path.join(a.outdir, a.label)
    os.makedirs(outdir, exist_ok=True)
    g = Guest(a.port)

    if a.reveal:
        print(json.dumps(g.command("reveal", {"target": a.reveal})),
              flush=True)
        time.sleep(4)
    if a.launch:
        print(json.dumps(g.command("launch", {"target": a.launch})),
              flush=True)
        time.sleep(6)
    if not a.no_front:
        print(json.dumps(g.command("front",
                                   {"target": a.front or a.app})),
              flush=True)
        time.sleep(3)

    def issue_pre(spec):
        nm, _, rest = spec.partition(":")
        ar = {}
        for pair in filter(None, rest.split(",")):
            k, _, v = pair.partition("=")
            try:
                ar[k] = int(v)
            except ValueError:
                ar[k] = v
        print("  pre %s -> %s" % (nm, json.dumps(g.command(nm, ar))[:200]),
              flush=True)

    for spec in a.pre:
        issue_pre(spec)
        time.sleep(4)

    def find_target(scene):
        best = None
        for w in scene.get("windows", []):
            if w.get("app", "").lower() == a.app.lower() and w.get("addr"):
                if w.get("front") or best is None:
                    best = w
        return best

    # The first scene of a fresh connection can miss foreign processes:
    # the scene claims the planes and the resident echoes on its NEXT
    # pass. Poll until the target window carries an addr.
    scene = None
    target = None
    for attempt in range(6):
        scene = g.scene()
        target = find_target(scene)
        if target is not None:
            break
        if a.open_new and attempt == 1:
            # The app is frontmost with no window: drive File > New
            # through its own MenuSelect (the act plane).
            mb = scene.get("menubar", {})
            psn = None
            for pr in scene.get("processes", []):
                if pr.get("front"):
                    psn = pr.get("psn")
            fmenu = None
            for m in mb.get("menus", []):
                if m.get("title") == "File":
                    fmenu = m
            if fmenu and psn:
                item = None
                for it in fmenu.get("items", []):
                    if it.get("title", "").startswith("New"):
                        item = it.get("index")
                        break
                if item:
                    hi, lo = psn.split(".")
                    r = g.command("menuact",
                                  {"serialHi": int(hi), "serialLo": int(lo),
                                   "menu": fmenu.get("id"), "item": item})
                    print("menuact File>New: %s" % json.dumps(r), flush=True)
                    time.sleep(4)
        time.sleep(4)
    with open(os.path.join(outdir, "scene.json"), "w") as f:
        json.dump(scene, f, indent=2)
    if target is None:
        print("no window with an addr for app %r; windows: %s" % (
            a.app, [(w.get("app"), w.get("title"), w.get("addr"),
                     w.get("front")) for w in scene.get("windows", [])]),
            file=sys.stderr)
        return 1
    addr = int(target["addr"])
    psn = target.get("psn", "")
    print("target: %r window %r addr 0x%08x psn %s" % (
        a.app, target.get("title"), addr, psn), flush=True)

    hi, lo = (psn.split(".") + ["0"])[:2] if psn else ("0", "0")
    args = {"op": "start", "window": "0x%08x" % addr, "mode": a.mode,
            "ttlTicks": a.ttl, "serialHi": int(hi), "serialLo": int(lo)}
    floor_status = g.command("qdtrace", {"op": "status"})
    ring_floor = (floor_status.get("output", {}).get("qdtrace", {})
                  .get("ring", {}).get("writeCursor", 0))
    started = g.command("qdtrace", args)
    print(json.dumps(started), flush=True)
    if not started.get("ok"):
        return 1
    def issue(spec):
        nm, _, rest = spec.partition(":")
        ar = {}
        for pair in filter(None, rest.split(",")):
            k, _, v = pair.partition("=")
            try:
                ar[k] = int(v)
            except ValueError:
                ar[k] = v
        r = g.command(nm, ar)
        print("  %s -> %s" % (nm, json.dumps(r)[:220]), flush=True)
        return r

    for spec in a.after:
        nm, _, rest = spec.partition(":")
        ar = {}
        for pair in filter(None, rest.split(",")):
            k, _, v = pair.partition("=")
            try:
                ar[k] = int(v)
            except ValueError:
                ar[k] = v
        print("after %s: %s" % (nm, json.dumps(g.command(nm, ar))[:300]),
              flush=True)
        time.sleep(4)
    if a.type_text:
        for ch in a.type_text:
            g.command("key", {"char": ord(ch)})
            time.sleep(0.3)
    time.sleep(a.settle)

    # If the chase hooked a GWorld, only the NEXT composite build is
    # recorded there - so ask for one more repaint (a re-arm of the same
    # window invalidates it again) and let it land.
    mid_status = g.command("qdtrace", {"op": "status"})
    probe_mid = (mid_status.get("output", {}).get("qdtrace", {})
                 .get("probe", {}))
    print("  probe after settle: %s" % json.dumps(probe_mid), flush=True)
    if a.repaint != "none" and target.get("ref"):
        # A reflowing resize forces the app to REBUILD its composite -
        # the drawing we are here to see - with every hook left standing
        # (a re-arm would bump the generation and unhook the GWorld).
        r = target.get("rect", {})
        w = max(200, (r.get("r", 400) - r.get("l", 0)) - 60)
        hgt = max(150, (r.get("b", 300) - r.get("t", 0)))
        if a.repaint == "resize":
            rr = g.command("winact", {"window": target["ref"],
                                      "action": "resize",
                                      "width": w, "height": hgt})
        else:
            g.command("hide", {"target": a.app})
            time.sleep(2)
            rr = g.command("reveal", {"target": a.app})
        print("  second composite (%s): %s"
              % (a.repaint, json.dumps(rr)[:220]), flush=True)
        time.sleep(a.settle)

    status1 = g.command("qdtrace", {"op": "status"})
    # Drain from the arm-time write cursor, not 0: the ring persists
    # across arms and a drain from 0 replays the previous phase.
    cursor = ring_floor
    recs = []
    live_until = time.time() + a.drain_seconds
    for i in range(256):
        d = g.command("qdtrace", {"op": "drain", "cursor": str(cursor),
                                  "maxRecords": 500})
        out = d.get("output", {}).get("qdtrace", {})
        recs.extend(out.get("ops", []))
        nxt = out.get("nextCursor", cursor)
        more = out.get("more", False)
        cursor = nxt
        if not more:
            if time.time() >= live_until:
                break
            time.sleep(0.4)
    status2 = g.command("qdtrace", {"op": "status"})
    g.command("qdtrace", {"op": "stop"})

    mix, texts, bits = {}, [], []
    for r in recs:
        port, op = r.get("port", "?"), r.get("op", "?")
        mix.setdefault(port, {}).setdefault(op, 0)
        mix[port][op] += 1
        if op == "text":
            texts.append(r)
        if op == "bits":
            bits.append(r)
    summary = {
        "label": a.label, "app": a.app,
        "window": "0x%08x" % addr, "psn": psn,
        "records": len(recs), "perPort": mix,
        "texts": texts, "bits": bits,
        "statusAfterSettle": status1, "statusAfterDrain": status2,
    }
    with open(os.path.join(outdir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    with open(os.path.join(outdir, "records.json"), "w") as f:
        json.dump(recs, f, indent=2)
    with open(os.path.join(outdir, "wire-log.json"), "w") as f:
        json.dump(g.log, f, indent=2)
    # THE HEALTH CHECK THE COUNTERS CANNOT DO. A crashed application
    # shows a dialog and reports nothing; this run's own counters read
    # green through exactly that, 2026-08-06. So every phase ends by
    # asking the machine what windows exist and saying so out loud.
    alerts = []
    try:
        post = g.scene()
        with open(os.path.join(outdir, "scene-after.json"), "w") as f:
            json.dump(post, f, indent=2)
        for w in post.get("windows", []):
            t = (w.get("title") or "").lower()
            if w.get("kind") in (1, 2, 3) or "quit" in t or "error" in t:
                alerts.append({"app": w.get("app"), "title": w.get("title"),
                               "kind": w.get("kind")})
        apps = [pr.get("name") for pr in post.get("processes", [])]
        if a.app not in apps and a.app != "Finder":
            alerts.append({"gone": a.app, "running": apps})
        if "Finder" not in apps:
            alerts.append({"gone": "Finder", "running": apps})
    except Exception as e:
        alerts.append({"sceneFailed": str(e)})
    if alerts:
        print("!! POST-RUN HEALTH: %s" % json.dumps(alerts), flush=True)
    summary["postRunAlerts"] = alerts
    with open(os.path.join(outdir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    probe = (status2.get("output", {}).get("qdtrace", {})
             .get("probe", {}))
    print(json.dumps({"records": len(recs), "alerts": alerts,
                      "ports": {p: sum(v.values()) for p, v in mix.items()},
                      "texts": len(texts), "probe": probe}, indent=2))
    return 0

if __name__ == "__main__":
    sys.exit(main())
