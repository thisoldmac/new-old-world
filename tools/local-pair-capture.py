#!/usr/bin/env python3
"""Capture PAIRS from a live guest: the guest's own pixels and the envelope
the host renders from, taken at the same moment.

    tools/local-pair-capture.py --port 18065 --qmp /path/qmp.sock \
        --out DIR --target finder-icon:Finder --target desktop:

This is a RIG INSTRUMENT for an integration look, not product code. It is
deliberately not the app: the app's render is produced afterwards by
MirrorApp --render-fixture over the envelope this writes, so the pixels
being compared and the pixels being explained came from one instant.

Two rules from docs/mirror-drive-loop.md are encoded here rather than
remembered:

  * The screendump is taken AFTER the walk returns, never before. QMP is
    for looking and the walk is what takes time; a dump taken first shows
    a machine that has since moved.
  * A target is FRONTED before it is walked. An application acquires an
    anchor slot only while it is itself pumping events with the plane
    armed, so walking an undriven machine yields the anchor defect and it
    reads exactly like a render defect.

A third rule, learned 2026-08-07 and the reason this file changed:

  * A SCENE IS NOT AN INTERIOR. `SceneBuilder.normalizeWindows` sets
    `display: nil` for every window it builds, unconditionally — so no
    scene envelope from any capture has ever carried content ops, and a
    render made from one alone hatches every window by construction. The
    interior arrives on a SECOND artifact: a `qdtrace` drain, composed
    onto the scene by `NOWMirrorContentPlane.apply(drain, to: scene)`.
    This tool used to write only the scene, so every pair it produced
    showed a hatch that said nothing about the renderer.

    Hence `<slug>-drain.json` beside `<slug>-scene.json`, and hence
    `contentArm` in the manifest: an UNARMED capture and a genuinely
    empty window must not look the same to a reader, because for a day
    they did.
"""
import argparse, json, os, socket, struct, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sweeplimits import stamp as stamp_limits, write_limits  # noqa: E402

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,
                         CHANNEL_BULK as BULK, FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


# Stated in the artifacts, not only in whatever report a human writes
# afterwards. See tools/sweeplimits.py for why this is data.
LIMITS = {
    "scene-alone-cannot-hatch-or-not": (
        "A window's interior is NOT in the scene. SceneBuilder sets "
        "`display: nil` on every window it builds, so a render made from "
        "`<slug>-scene.json` alone hatches every window whatever the "
        "guest drew. Judge an interior only from a pair where "
        "`contentArm.ok` is true and `<slug>-drain.json` is composed onto "
        "the scene, as NOWMirrorContentPlane does."),
    "content-is-a-spotlight-not-a-plane": (
        "P3 (content) is not armed by a scene walk. P1/P2/P4 echo the "
        "resident's arm request unconditionally; P3's bit is set in one "
        "place, under a per-window, per-A5, TTL-bounded verdict over "
        "`qdtrace start`. One arm covers ONE window, and it lapses. A "
        "target with `contentArm.ok` false was never looked at."),
    "one-window-per-target": (
        "Only the target's own front window is armed. Every other window "
        "in the same capture has no drain and will hatch — that is this "
        "tool's shape, not a finding about those windows."),
    "emulator-not-metal": (
        "Emulated mac99/OS 9 unless the run says otherwise. Nothing here "
        "is metal-verified."),
}


class Wire:
    """The host half of the contract: we listen, the guest dials us."""

    def __init__(self, port, timeout=180):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", port))
        self.srv.listen(1)
        self.srv.settimeout(timeout)
        self.conn = None
        self.buf = b""
        self.next_id = 200

    def control_accept(self):
        self.conn, _ = self.srv.accept()
        self.conn.settimeout(120)
        hello = self.control()
        # THE HANDSHAKE IS THE HOST'S TO FINISH. The guest dials, sends
        # hello and waits; a host that says nothing is answered by the
        # guest hanging up, which on this side looks exactly like a guest
        # that never dialled. Cost one run to find.
        self.send({"type": "hello", "contract": CONTRACT, "side": "host",
                   "version": "0", "name": "019-pair-capture", "chunk": 4096})
        return hello

    def read_message(self):
        """THE WIRE IS LENGTH-FRAMED and carries TWO channels. Reading it
        as lines gets a guest that dials, says hello and hangs up — which
        on this side is indistinguishable from a guest that never
        dialled. Reading every frame as JSON gets a decode error partway
        through the first scene, because the scene body rides the BULK
        channel as raw bytes. Both cost a run.

        Returns ("control", obj) or ("bulk", bytes, endFlag)."""
        while True:
            while len(self.buf) >= 8:
                channel, flags, _, length = struct.unpack(">BBHI",
                                                          self.buf[:8])
                if len(self.buf) < 8 + length:
                    break
                payload = self.buf[8:8 + length]
                self.buf = self.buf[8 + length:]
                if channel == BULK:
                    return ("bulk", payload, bool(flags & END))
                # Guest JSON carries raw MacRoman in names: repair-decode
                # rather than die on a machine whose owner used an option key.
                return ("control",
                        json.loads(payload.decode("utf-8", "replace")))
            chunk = self.conn.recv(65536)
            if not chunk:
                raise SystemExit("guest closed the wire")
            self.buf += chunk

    def control(self):
        """The next CONTROL message, answering pings and ignoring bulk."""
        while True:
            m = self.read_message()
            if m[0] != "control":
                continue
            obj = m[1]
            if obj.get("type") == "ping":
                self.send({"type": "pong", "id": obj.get("id", 0)})
                continue
            return obj

    def scene(self, timeout=120):
        """One scene: request, collect the bulk body, return the IR."""
        self.next_id += 1
        mid = self.next_id
        self.send({"type": "scene.request", "id": mid,
                   "semantics": True, "interaction": True})
        body, begin, t0 = b"", None, time.time()
        while time.time() - t0 < timeout:
            m = self.read_message()
            if m[0] == "bulk":
                body += m[1]
                continue
            obj = m[1]
            kind = obj.get("type")
            if kind == "ping":
                self.send({"type": "pong", "id": obj.get("id", 0)})
                continue
            if kind == "scene.begin":
                begin = obj
                continue
            if kind in ("scene.end", "scene.result", "scene.complete"):
                return begin, body, obj
            if kind in ("scene.error", "error"):
                return begin, body, obj
        raise SystemExit("scene did not complete")

    def send(self, obj):
        payload = json.dumps(obj).encode()
        self.conn.sendall(
            struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload)

    def command(self, name, **args):
        self.next_id += 1
        msg = {"type": "command.request", "id": self.next_id, "name": name}
        if args:
            msg["args"] = {k: v for k, v in args.items() if v is not None}
        self.send(msg)
        while True:
            reply = self.control()
            if reply.get("type") == "command.result" \
                    and reply.get("id") == self.next_id:
                return reply


class ContentArm:
    """P3 for ONE window, for as long as its TTL lasts.

    Kept apart from `Wire` because it is not part of the wire: it is the
    one capability this instrument has to ASK for, and separating it
    makes `--no-content` a single object that refuses rather than a flag
    threaded through the capture. That matters — the disabled path is the
    control in the mutation test that proves the armed path is doing the
    work, and a control implemented as scattered `if`s is not a control.
    """

    def __init__(self, wire, ttl_ticks):
        self.wire = wire
        self.ttl = ttl_ticks
        self.cursor = 0
        self.records = []
        self.armed = False
        self.report = {"requested": False, "ok": False, "reason": None,
                       "window": None, "psn": None, "records": 0}

    def start(self, window):
        """`window` is a scene window dict. Refuses, loudly and in the
        report, rather than capturing a hatch that looks like a finding."""
        self.report["requested"] = True
        if not window:
            self.report["reason"] = "no front window with an address"
            return False
        addr = window.get("addr")
        if not addr:
            self.report["reason"] = "front window carries no addr"
            return False
        psn = window.get("psn") or "0.0"
        hi, lo = (str(psn).split(".") + ["0"])[:2]
        self.report["window"] = "0x%08x" % int(addr)
        self.report["psn"] = psn
        self.report["title"] = window.get("title")
        floor = self.wire.command("qdtrace", op="status")
        self.cursor = ((floor.get("output") or {}).get("qdtrace", {})
                       .get("ring", {}).get("writeCursor", 0))
        reply = self.wire.command(
            "qdtrace", op="start", window="0x%08x" % int(addr),
            mode="record", ttlTicks=self.ttl,
            serialHi=int(hi), serialLo=int(lo))
        if not reply.get("ok"):
            self.report["reason"] = json.dumps(reply)[:300]
            return False
        self.armed = True
        self.report["ok"] = True
        self.report["ttlTicks"] = self.ttl
        return True

    def drain(self, seconds):
        """Drain CONTINUOUSLY while the repaints happen. A source that
        draws faster than the ring holds laps the arm-time cursor, and a
        single drain afterwards resyncs to live and answers empty
        (measured 2026-08-06: 0 records against 915 recorded ops)."""
        if not self.armed:
            time.sleep(seconds)
            return
        end = time.time() + seconds
        while time.time() < end:
            reply = self.wire.command("qdtrace", op="drain",
                                      cursor=str(self.cursor),
                                      maxRecords=400)
            out = (reply.get("output") or {}).get("qdtrace", {})
            self.records.extend(out.get("ops", []))
            self.cursor = out.get("nextCursor", self.cursor)
            if not out.get("more"):
                time.sleep(0.2)

    def stop(self):
        if not self.armed:
            return
        self.drain(3)
        self.wire.command("qdtrace", op="stop")
        self.armed = False
        self.report["records"] = len(self.records)

    def fixture(self, slug, build, note):
        """FIXTURE SHAPE, so this drops straight into Fixtures/ and
        NOWMirrorContentPlane accepts it — `records` must agree with
        len(ops) or the plane refuses the drain."""
        return {
            "cmd": "drain", "ops": self.records, "cursor": 0,
            "nextCursor": self.cursor, "writeCursor": self.cursor,
            "pending": 0, "records": len(self.records), "wraps": 0,
            "more": False, "resync": False, "torn": False, "busy": False,
            "lostBytes": 0, "dropped": 0,
            "provenance": {
                "build": build or "unverified",
                "run": "local-pair-capture %s (%s)" % (slug, note),
                "guest": "mac99/OS 9.x emulated",
            },
        }


class NoContent(ContentArm):
    """The control. Arms nothing and says so, so a capture taken with
    `--no-content` is legible as one rather than as an empty window."""

    def start(self, window):
        self.report["requested"] = False
        self.report["reason"] = "--no-content: P3 never armed for this run"
        return False


def screendump(qmp_sock, ppm_path):
    """QMP observes pixels only; it is never an input route."""
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lab = os.environ.get("NOW_LAB_ROOT", os.path.dirname(repo))
    subprocess.run(
        [f"{lab}/tools/qmp", qmp_sock, "screendump",
         json.dumps({"filename": ppm_path})],
        capture_output=True, check=True)


def to_png(ppm_path, png_path):
    subprocess.run(["sips", "-s", "format", "png", ppm_path,
                    "--out", png_path], capture_output=True, check=True)
    os.remove(ppm_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--target", action="append", default=[],
                    help="slug[:applescript to run first]")
    ap.add_argument("--settle", type=float, default=5.0)
    ap.add_argument("--content-ttl", type=int, default=3600,
                    help="qdtrace TTL in ticks; the arm LAPSES, it is not "
                         "a plane that stays on")
    ap.add_argument("--repaints", type=int, default=2,
                    help="front/back cycles driven under the arm, so there "
                         "is something for the ring to record")
    ap.add_argument("--no-content", action="store_true",
                    help="the CONTROL: arm nothing. Every window then "
                         "hatches, and the manifest says why it hatched.")
    ap.add_argument("--build", default=None,
                    help="build hash for the drain's provenance")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    wire = Wire(args.port)
    print(f"listening on 127.0.0.1:{args.port} for the guest to dial...",
          flush=True)
    hello = wire.control_accept()
    print("guest hello:", json.dumps(hello), flush=True)

    # WARM-UP SCENE, and it is not politeness. THREE of the four planes
    # arm as a RESULT of a scene.request — P1, P2 and P4 echo the
    # resident's arm request unconditionally — so the FIRST scene on a
    # connection is walked before semantics is active and comes back with
    # every control's role `unknown`: group boxes, checkboxes and radio
    # buttons all indistinguishable, which renders as a window with no
    # frames and no widgets. It looks exactly like a renderer regression.
    # Watched 2026-08-07: requested=0/active=0 before the first request,
    # requested=7/active=7 after it, and the body grew 25701 -> 42621 bytes.
    #
    # P3 (CONTENT) IS NOT AMONG THEM, and the sentence that used to sit
    # here said "the planes" and so implied it was. It is not a plane at
    # all: it is a per-window, per-A5, TTL-bounded spotlight, and the only
    # thing that lights it is `qdtrace start` on ONE window. That is what
    # the 7 above is — 7 requested with content dark; `qdtrace start`
    # takes it to 15 and `qdtrace stop` returns it to 7. So a warm-up
    # arms everything EXCEPT the plane that draws interiors, which is why
    # every capture this tool took before 2026-08-07 hatched.
    wire.command("cycle")
    warm_begin, _, _ = wire.scene()
    print(f"warm-up scene: {warm_begin.get('bytes')} bytes "
          f"(arms P1/P2/P4 — NOT content; its body is discarded)",
          flush=True)

    manifest = stamp_limits(
        {"hello": hello, "warmup": warm_begin,
         "contentArmed": not args.no_content, "targets": []}, LIMITS)
    for spec in args.target:
        slug, _, script = spec.partition(":")
        record = {"slug": slug, "script": script or None}

        if script:
            r = wire.command("script", source=script)
            record["scriptOk"] = bool(r.get("ok"))
            record["script_reply"] = r.get("output") or r.get("error")
            print(f"[{slug}] script: "
                  f"{'ok' if r.get('ok') else r.get('error')}", flush=True)
            time.sleep(args.settle)

        # ARM AND ACQUIRE FIRST. An application holds an anchor slot only
        # while it is pumping events with the plane armed, so a walk of an
        # undriven machine reports the anchor defect and it reads exactly
        # like a render defect. See docs/open-issues.md.
        c = (wire.command("cycle").get("output") or {}).get("cycle", {})
        record["cycle"] = c
        print(f"[{slug}] cycle armed={c.get('armed')} "
              f"acquired={c.get('acquired')} "
              f"count->{c.get('after', {}).get('count')}", flush=True)

        # PROBE WALK, then arm. The arm needs a window ADDRESS and the
        # only thing that reports one is a scene, so the order cannot be
        # otherwise: walk to learn the address, arm that one window, drive
        # repaints into the ring, and only then take the walk and the
        # screendump that become the pair. This walk's body is discarded.
        probe_begin, probe_body, _ = wire.scene()
        probe = json.loads(probe_body.decode("utf-8", "replace"))
        front = None
        for w in probe.get("windows", []):
            if w.get("addr") and (w.get("front") or front is None):
                front = w
        arm = NoContent(wire, args.content_ttl) if args.no_content \
            else ContentArm(wire, args.content_ttl)
        arm.start(front)
        print(f"[{slug}] content arm: "
              + (f"ok window={arm.report['window']} "
                 f"title={arm.report.get('title')!r}" if arm.report["ok"]
                 else f"NOT ARMED — {arm.report['reason']}"), flush=True)

        # Repaints are driven by FRONTING, not by resizing: a resize
        # reflows the window and the render then disagrees with the
        # screendump about a layout neither side got wrong.
        owner = (front or {}).get("app")
        for _ in range(args.repaints if arm.armed and owner else 0):
            wire.command("front", target="New Old World")
            arm.drain(3)
            wire.command("front", target=owner)
            arm.drain(5)

        t0 = time.time()
        begin, body, end = wire.scene()
        record["begin"] = begin
        record["end"] = end

        # The dump comes AFTER the scene returns, so both describe one
        # moment. QMP observes pixels only; it is never an input route.
        ppm = os.path.join(args.out, f"{slug}-guest.ppm")
        screendump(args.qmp, ppm)
        to_png(ppm, os.path.join(args.out, f"{slug}-guest.png"))

        # The arm is released BEFORE the next target: it is per-window,
        # and leaving it up would let one target's ring answer the next
        # target's drain.
        arm.stop()
        record["contentArm"] = arm.report
        with open(os.path.join(args.out, f"{slug}-drain.json"), "w") as fh:
            json.dump(arm.fixture(
                slug, args.build,
                "record mode" if arm.report["ok"]
                else "NOT ARMED: %s" % arm.report["reason"]),
                fh, indent=1)
        print(f"[{slug}] content: {arm.report['records']} op(s) "
              + ("" if arm.report["ok"]
                 else "— NOT ARMED, so this pair's interior is an "
                      "ARTEFACT of the instrument, not of the renderer"),
              flush=True)

        envelope = {"bytes": None, "capturedAt": begin.get("capturedAt"),
                    "latencyMs": int((time.time() - t0) * 1000),
                    "result": json.loads(body.decode("utf-8", "replace"))}
        with open(os.path.join(args.out, f"{slug}-scene.json"), "w") as fh:
            json.dump(envelope["result"], fh, indent=1, sort_keys=True)
        wins = envelope["result"].get("windows", [])
        record["windows"] = [
            {"app": w.get("app"), "title": w.get("title"),
             "controls": len(w.get("controls", [])), "rect": w.get("rect")}
            for w in wins]
        print(f"[{slug}] {len(wins)} window(s): "
              + ", ".join(f"{w.get('app')}/{w.get('title')!r}" for w in wins),
              flush=True)
        manifest["targets"].append(record)

    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1)
    write_limits(args.out, "local-pair-capture.py", LIMITS)

    unarmed = [t["slug"] for t in manifest["targets"]
               if not t.get("contentArm", {}).get("ok")]
    if unarmed:
        print("NOT ARMED, interiors are artefacts: " + ", ".join(unarmed),
              flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
