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

THE OTHER FACE: prefix a spec with `exec ` and the rest of it is sent as an
exec.request line instead — the whole line, untouched, the way a host
console sends it — and what comes back is the text the guest's OWN console
would have drawn.

    tools/askguest.py --port 5510 putstat "exec putstat"

Those two lines ask one Macintosh the same question through its two faces,
and printing them side by side is the only way to see the class of defect
docs/command-parity.md is about: a verb PRESENT on both faces and working
on one. `putstat` answered its table on the wire and printed
"command failed" at the console for as long as anyone had been typing it.
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


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
    # A just-launched application has not been ANCHORED yet: the extension's
    # jGNE filter captures a process's A5 world the first time that process
    # pumps an event, so for the first moments of its life it is invisible to
    # the anchor plane and `actselftest` answers `no-such-process`. Measured
    # 2026-08-01 on mac99: the very first actselftest after a launch failed
    # that way and the identical call moments later returned `abi-agreed`.
    # That is a settle window, not a defect, and a run that reports the first
    # answer reports a lie about the trap ABI — which is precisely the class
    # of failure actselftest exists to catch.
    ap.add_argument("--retries", type=int, default=0,
                    help="re-ask a verb that failed, this many times")
    ap.add_argument("--retry-delay", type=float, default=6.0)
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

    def run_exec(mid, line):
        """The console face. Collects exec.output in seq order until the one
        exec.result that terminates it, and prints the text verbatim — the
        host composes no sentence of its own (contract: ExecResult)."""
        req = {"type": "exec.request", "id": mid, "line": line}
        print(f"\n-> {json.dumps(req)}", flush=True)
        send(req)
        chunks = {}
        while True:
            try:
                msg = read_message()
            except Exception as e:
                print(f"<- (no reply: {e})", flush=True)
                return False
            if msg.get("type") == "ping":
                send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            if msg.get("type") == "exec.output":
                chunks[msg.get("seq", len(chunks))] = msg.get("text", "")
                continue
            if msg.get("type") != "exec.result":
                continue
            text = "".join(chunks[k] for k in sorted(chunks))
            for out_line in text.split("\r" if "\r" in text else "\n"):
                print(f"<| {out_line}", flush=True)
            print("<- " + json.dumps(msg), flush=True)
            return bool(msg.get("ok"))

    rc = 0
    mid = 100
    for spec in a.verbs:
        if spec.startswith("exec "):
            mid += 1
            ok = run_exec(mid, spec[len("exec "):])
            if not ok:
                rc = 1
            continue
        name, args = parse_verb(spec)
        for attempt in range(a.retries + 1):
            mid += 1
            req = {"type": "command.request", "id": mid, "name": name}
            if args:
                req["args"] = args
            print(f"\n-> {json.dumps(req)}", flush=True)
            send(req)
            # Skip anything that is not this request's answer: the guest emits
            # log and status traffic unprompted, and a reader that treats the
            # first frame as the reply reports whatever happened to arrive.
            ok = False
            while True:
                try:
                    msg = read_message()
                except Exception as e:
                    print(f"<- (no reply: {e})", flush=True)
                    break
                if msg.get("type") == "ping":
                    send({"type": "pong", "id": msg.get("id", 0)})
                    continue
                if msg.get("id") != mid:
                    continue
                print("<- " + json.dumps(msg), flush=True)
                ok = bool(msg.get("ok", msg.get("type") != "error"))
                break
            if ok:
                break
            if attempt < a.retries:
                print(f"   (retrying in {a.retry_delay:.0f}s — "
                      f"{a.retries - attempt} left)", flush=True)
                time.sleep(a.retry_delay)
        if not ok:
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
