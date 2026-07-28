#!/usr/bin/env python3
"""A wire peer that impersonates a NOW guest, so the metal harness can be
exercised without a Macintosh on the LAN.

  tools/fakeguest.py --port 5399 --kind 68k|ppc [--self-name X] [--lie]

READ THIS BEFORE TRUSTING ANYTHING IT PRINTS. This proves things about the
HARNESS, never about the guests. It is hand-written from now-guest-68k/src and
the contract, so a run against it can only show that MetalQuitTests reacts
correctly to a guest that behaves a stated way — it cannot show that either
real guest behaves that way, and a test that constructs the message it then
parses tests one half twice. Nothing verified against this peer may be
called metal-verified, or even evidence about a guest. Its whole value is
the other direction: --lie makes it report "gone" while keeping the process
running, which is the one failure `quit` was written to catch and which no
real guest will perform on request.

68k: hello name "now-68k"; serves only launch/quit; answers process.list
     with the generic {"type":"error","code":"not-implemented"} the real
     now-guest-68k/src/core/wire68.c sends (which the host does not route, so it
     surfaces as the 15s watchdog timeout).
ppc: hello name "PowerBook 1400c"; also serves process.list from a fake
     process table.

It dials the host, because that is the direction the wire runs: start the
host listener first (or `NOW_METAL=1 swift test --filter MetalQuitTests`),
then this.
"""
import argparse
import json
import socket
import struct
import sys
import time

CONTROL = 0
END = 1


def frame(payload: bytes) -> bytes:
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


class Peer:
    def __init__(self, sock, kind, self_name, victim, lie=False):
        self.sock = sock
        self.kind = kind
        self.self_name = self_name
        self.victim = victim
        self.lie = lie
        self.buf = b""
        # The guest itself is always running; the victim starts stopped.
        self.running = {self_name.lower(): self_name}

    def send(self, obj):
        line = json.dumps(obj)
        print("  -> " + line, flush=True)
        self.sock.sendall(frame(line.encode()))

    def read_frames(self):
        while True:
            while len(self.buf) >= 8:
                _, _, _, length = struct.unpack(">BBHI", self.buf[:8])
                if len(self.buf) < 8 + length:
                    break
                payload = self.buf[8:8 + length]
                self.buf = self.buf[8 + length:]
                yield payload
            chunk = self.sock.recv(65536)
            if not chunk:
                return
            self.buf += chunk

    # --- verbs ----------------------------------------------------------
    def quit(self, mid, target):
        target = (target or "").strip()
        args = target.split()
        wait = True
        while args and args[0].startswith("--"):
            flag = args.pop(0)
            if flag == "--no-wait":
                wait = False
            elif flag == "--wait":
                if args:
                    args.pop(0)
            else:
                return self.err(mid, "quit-bad-args",
                                'quit: no flag "%s"' % flag)
        name = " ".join(args).strip('"')
        if not name:
            return self.err(mid, "quit-bad-args",
                            "quit: what? (the name of a running process)")
        if name.lower() == self.self_name.lower():
            return self.err(mid, "quit-refused",
                            "quit: NOW will not ask itself to quit")
        if name.lower() not in self.running:
            return self.ok2(mid, "%s is not running" % name, "not-running")
        if not wait:
            return self.ok2(mid, "asked %s to quit" % name,
                            "sent-unconfirmed")
        if not self.lie:
            del self.running[name.lower()]
        return self.ok2(mid, "%s quit" % name, "gone")

    def launch(self, mid, target):
        name = (target or "").strip()
        if not name:
            return self.err(mid, "launch-bad-args", "launch: what?")
        self.running[name.lower()] = name
        self.send({"type": "command.result", "id": mid, "ok": True,
                   "output": {"launch": [["Launch", "%s is running" % name]]}})

    def ok2(self, mid, detail, state):
        self.send({"type": "command.result", "id": mid, "ok": True,
                   "output": {"quit": [["Quit", detail],
                                       ["Outcome", state]]}})

    def err(self, mid, code, message):
        self.send({"type": "command.result", "id": mid, "ok": False,
                   "error": {"code": code, "message": message}})

    # --- dispatch -------------------------------------------------------
    def serve(self):
        name = ("now-68k" if self.kind == "68k" else "PowerBook 1400c")
        os_ = "7.1" if self.kind == "68k" else "9"
        self.send({"type": "hello", "contract": 1, "side": "guest",
                   "version": "0.3", "name": name, "os": os_,
                   "chunk": 4096})
        for payload in self.read_frames():
            msg = json.loads(payload.decode())
            print("  <- " + json.dumps(msg), flush=True)
            kind = msg.get("type")
            mid = msg.get("id", 0)
            if kind in ("hello", "pong", "bye"):
                if kind == "bye":
                    return
                continue
            if kind == "ping":
                self.send({"type": "pong", "id": mid})
            elif kind == "command.request":
                verb = msg.get("name")
                target = (msg.get("args") or {}).get("target")
                if verb == "quit":
                    self.quit(mid, target)
                elif verb == "launch":
                    self.launch(mid, target)
                else:
                    self.err(mid, "unknown-command",
                             "no commands implemented")
            elif kind == "process.list":
                if self.kind == "68k":
                    # now-guest-68k/src/core/wire68.c :: send_error_reply
                    self.send({"type": "error", "id": mid,
                               "code": "not-implemented",
                               "message": "unsupported message type"})
                else:
                    procs = [{"name": n, "kind": "application"}
                             for n in self.running.values()]
                    self.send({"type": "process.listing", "id": mid,
                               "processes": procs, "more": False})
            else:
                self.send({"type": "error", "id": mid,
                           "code": "not-implemented",
                           "message": "unsupported message type"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5399)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--kind", choices=["68k", "ppc"], default="68k")
    ap.add_argument("--self-name", default="now-guest-68k")
    ap.add_argument("--victim", default="TeachText")
    ap.add_argument("--lie", action="store_true",
                    help="report gone while keeping the process running")
    ap.add_argument("--wait", type=float, default=30.0,
                    help="seconds to keep retrying the dial (default 30)")
    a = ap.parse_args()
    # Retry, because the usual dev loop starts this and the host listener at
    # once and the listener is the slower of the two - a single refused
    # connect would read as a broken harness rather than a race.
    deadline = time.monotonic() + a.wait
    while True:
        try:
            s = socket.create_connection((a.host, a.port), timeout=300)
            break
        except OSError:
            if time.monotonic() >= deadline:
                print("nothing listening on %s:%d after %.0fs"
                      % (a.host, a.port, a.wait), flush=True)
                return 1
            time.sleep(0.25)
    print("connected to %s:%d as %s" % (a.host, a.port, a.kind), flush=True)
    try:
        Peer(s, a.kind, a.self_name, a.victim, a.lie).serve()
    except (ConnectionResetError, BrokenPipeError):
        print("peer closed", flush=True)
    print("done", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
