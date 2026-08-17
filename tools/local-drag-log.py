#!/usr/bin/env python3
"""Page the guest's WHOLE log ring back, oldest-first, and print it.

    tools/local-drag-log.py --port <wire port> [--area mirror] [--rows 2000]

WHY A SECOND PAGER. `tools/local-hg-drag-targeting-remeasure.py`'s
`tail_pages` stops as soon as one page comes back without a usable
`next` cursor, and on 2026-08-17 that returned 46 of the 111 rows the
guest itself said it was holding — so the product's own `drag drop:` and
`drag attrs:` lines, the two the whole measurement turns on, were absent
from a transcript that looked complete. An instrument that returns part
of the ring and says nothing is the "absence and defect in the same
words" failure this project has a rule about.

This one walks strictly by the row identity it already has: each page's
OLDEST row index becomes the next `before`, and it stops only when a page
repeats or comes back empty. Observe-only; needs a booted guest.
"""

import argparse
import json
import os
import socket
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


def frame(payload):
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


class Link:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.id = 700

    def send(self, obj):
        self.sock.sendall(frame(json.dumps(obj).encode()))

    def recv(self):
        while True:
            while len(self.buf) >= 8:
                _, _, _, n = struct.unpack(">BBHI", self.buf[:8])
                if len(self.buf) < 8 + n:
                    break
                payload = self.buf[8:8 + n]
                self.buf = self.buf[8 + n:]
                return json.loads(payload.decode("utf-8", "replace"))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the connection")
            self.buf += chunk

    def ask(self, name, args=None, line=None):
        self.id += 1
        req = {"type": "command.request", "id": self.id, "name": name}
        if args:
            req["args"] = args
        if line is not None:
            req["line"] = line
        self.send(req)
        while True:
            msg = self.recv()
            if msg.get("type") == "ping":
                self.send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") == self.id:
                return msg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--area", default="mirror")
    ap.add_argument("--rows", type=int, default=2000)
    ap.add_argument("--wait", type=float, default=240)
    args = ap.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    server.settimeout(args.wait)
    print(f"drag-log pager listening on {args.host}:{args.port}", flush=True)
    sock, _ = server.accept()
    sock.settimeout(30)
    link = Link(sock)
    hello = link.recv()
    link.send({"type": "hello", "contract": CONTRACT, "side": "host",
               "version": "0", "name": "drag-log-pager", "chunk": 4096})
    print("guest:", json.dumps(hello), flush=True)

    pages = []
    seen = set()
    before = None
    while sum(len(p) for p in pages) < args.rows:
        a = {"lines": 40, "area": args.area}
        if before is not None:
            a["before"] = int(before)
        reply = link.ask("tail", args=a)
        out = reply.get("output") or {}
        rows = out.get("tail") or []
        if not rows:
            break
        key = json.dumps(rows[0]) + json.dumps(rows[-1]) + str(len(rows))
        if key in seen:
            break
        seen.add(key)
        pages.append(rows)
        log = {k: v for k, v in (out.get("log") or [])}
        nxt = log.get("next")
        if nxt in (None, "", "0", 0):
            break
        before = int(nxt)

    ordered = []
    for page in reversed(pages):
        ordered.extend(page)
    for stamp, text in ordered:
        print(f"{stamp}  {text}")
    print(f"--- {len(ordered)} rows in {len(pages)} pages", flush=True)
    link.send({"type": "bye"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
