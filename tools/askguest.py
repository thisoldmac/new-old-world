#!/usr/bin/env python3
"""Listen as a NOW host, take one dialling guest, ask it verbs, print what
it said — verbatim.

    tools/askguest.py --port 5250 --wait 240 qdtrace:op=status actselftest

READ THIS BEFORE TRUSTING WHAT IT PRINTS. It is the mirror image of
`tools/fakeguest.py`: that one impersonates a guest to exercise the host,
this one impersonates a host to interrogate a REAL guest. So the direction
of evidence is opposite. fakeguest can prove nothing about a guest; this
proves nothing about the host app, and everything it prints is the guest's
own words. It is an instrument, not a product surface — the shipped host is
`now-host`, and this exists so that a staging run has an oracle that is the
guest rather than a script's exit code.

The wire runs guest -> host: the guest DIALS, so the listener must be up
first. Under QEMU user-mode networking the guest's default host address
(10.0.2.2, from now-guest-ppc/src/core/prefs.c set_defaults) is this Mac's
loopback, and its default port is 5250 (kNowDefaultHostPort), so a guest
with no preferences file finds this without being configured.

Framing is contract/asyncapi.yaml's 8-byte big-endian header: channel u8,
flags u8, transfer u16, length u32. Control channel 0, END flag 1.

Verb syntax: `name` or `name:key=value,key=value`. Values that parse as an
integer are sent as numbers, because the guest's argument readers are typed
(now_json_find_int vs now_json_find_string) and a quoted 3 is not a 3.
"""

import argparse
import json
import socket
import struct
import sys
import time

CONTROL, END = 0, 1
CONTRACT = 1


def frame(payload: bytes) -> bytes:
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


def parse_verb(spec: str):
    name, _, rest = spec.partition(":")
    args = {}
    for pair in filter(None, rest.split(",")):
        k, _, v = pair.partition("=")
        try:
            args[k] = int(v)
        except ValueError:
            args[k] = v
    return name, args


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("verbs", nargs="*", default=[])
    ap.add_argument("--port", type=int, default=5250)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wait", type=float, default=240.0,
                    help="seconds to wait for a guest to dial in")
    ap.add_argument("--reply-timeout", type=float, default=30.0)
    ap.add_argument("--name", default="askguest")
    a = ap.parse_args()

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.host, a.port))
    srv.listen(1)
    srv.settimeout(a.wait)
    print(f"listening on {a.host}:{a.port}, waiting up to {a.wait:.0f}s "
          f"for the guest to dial", flush=True)
    try:
        sock, peer = srv.accept()
    except socket.timeout:
        print(f"no guest dialled in within {a.wait:.0f}s", flush=True)
        return 2
    print(f"guest connected from {peer[0]}:{peer[1]}", flush=True)
    sock.settimeout(a.reply_timeout)

    buf = b""

    def read_message():
        nonlocal buf
        while True:
            while len(buf) >= 8:
                _, _, _, length = struct.unpack(">BBHI", buf[:8])
                if len(buf) < 8 + length:
                    break
                payload, buf = buf[8:8 + length], buf[8 + length:]
                # Guest JSON carries raw MacRoman bytes in names: repair-decode
                # rather than die on a machine whose owner used an option key.
                return json.loads(payload.decode("utf-8", "replace"))
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the connection")
            buf += chunk

    def send(obj):
        sock.sendall(frame(json.dumps(obj).encode()))

    # The guest sends its hello first and then waits up to 8s for ours
    # (wire.c kHelloTimeoutTicks); miss that window and it fails the link.
    guest_hello = read_message()
    print("guest hello: " + json.dumps(guest_hello), flush=True)
    send({"type": "hello", "contract": CONTRACT, "side": "host",
          "version": "0", "name": a.name, "chunk": 4096})

    rc = 0
    mid = 100
    for spec in a.verbs:
        name, args = parse_verb(spec)
        mid += 1
        req = {"type": "command.request", "id": mid, "name": name}
        if args:
            req["args"] = args
        print(f"\n-> {json.dumps(req)}", flush=True)
        send(req)
        # Skip anything that is not this request's answer: the guest emits
        # log and status traffic unprompted, and a reader that treats the
        # first frame as the reply reports whatever happened to arrive.
        deadline = time.monotonic() + a.reply_timeout
        while True:
            try:
                msg = read_message()
            except Exception as e:
                print(f"<- (no reply: {e})", flush=True)
                rc = 1
                break
            if msg.get("type") == "ping":
                send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            print("<- " + json.dumps(msg), flush=True)
            if not msg.get("ok", msg.get("type") != "error"):
                rc = 1
            break
        else:
            rc = 1
        if time.monotonic() > deadline:
            rc = 1

    try:
        send({"type": "bye"})
    except OSError:
        pass
    sock.close()
    srv.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
