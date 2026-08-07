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
"""
import argparse, json, os, socket, struct, subprocess, sys, time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,
                         CHANNEL_BULK as BULK, FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


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


def screendump(qmp_sock, ppm_path):
    """QMP observes pixels only; it is never an input route."""
    lab = "/Users/michelle/Lab/Code/timbottu"
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
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    wire = Wire(args.port)
    print(f"listening on 127.0.0.1:{args.port} for the guest to dial...",
          flush=True)
    hello = wire.control_accept()
    print("guest hello:", json.dumps(hello), flush=True)

    # WARM-UP SCENE, and it is not politeness. The planes arm as a RESULT
    # of a scene.request, so the FIRST scene on a connection is walked
    # before semantics is active and comes back with every control's role
    # `unknown` — group boxes, checkboxes and radio buttons all
    # indistinguishable, which renders as a window with no frames and no
    # widgets. It looks exactly like a renderer regression. Watched
    # 2026-08-07: requested=0/active=0 before the first request,
    # requested=7/active=7 after it, and the body grew 25701 -> 42621 bytes.
    wire.command("cycle")
    warm_begin, _, _ = wire.scene()
    print(f"warm-up scene: {warm_begin.get('bytes')} bytes "
          f"(arms the planes; its content is discarded)", flush=True)

    manifest = {"hello": hello, "warmup": warm_begin, "targets": []}
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

        t0 = time.time()
        begin, body, end = wire.scene()
        record["begin"] = begin
        record["end"] = end

        # The dump comes AFTER the scene returns, so both describe one
        # moment. QMP observes pixels only; it is never an input route.
        ppm = os.path.join(args.out, f"{slug}-guest.ppm")
        screendump(args.qmp, ppm)
        to_png(ppm, os.path.join(args.out, f"{slug}-guest.png"))

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
    print("done", flush=True)


if __name__ == "__main__":
    main()
