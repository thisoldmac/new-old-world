"""A host-side wire client for gates that drive a REAL guest.

`tools/askguest.py` is an instrument for a person: it prints the wire
verbatim and its exit code means "every verb answered ok". A gate needs
something else — the ability to ask a question, to notice that the answer
never came because the machine DIED, and to tell those two apart in its
report. This is that, factored out so the census gate and whatever
integration suite follows it share one implementation rather than two
copies of a framing loop.

WHAT IT IS FOR, AND THE THREE PROPERTIES IT ENCODES

1. LIVENESS IS AN ANSWER, NOT A PROCESS CHECK. `alive()` asks the guest a
   question and requires a reply. On 2026-08-07 NOW's Workshop was dead
   with its window still drawn on the desktop and the anchor worker still
   holding its TCP port: every process-shaped check on this Mac would have
   said "fine". The wire is pumped by the application's own event loop
   (now-guest-ppc/src/core/pump.h), so a reply to a control frame is
   proof that loop is turning — which is exactly the fact a gate wants
   and the one `pgrep` cannot supply.

2. A DEAD GUEST ENDS THE RUN. `GuestGone` is raised, not returned. Every
   check after it is UNRUN — never "skipped", never "passed". A suite
   that walks past a dead machine and reports greens is this project's
   most-repeated defect class, and a gate written for a crash must not be
   the next instance of it.

3. THE BUILD UNDER TEST IS ASSERTED ON EVERY CONNECT. Every QEMU guest on
   this Mac sees the host as 10.0.2.2 under user-mode networking and the
   human's own app may hold a port, so ANY session's VM running ANY
   branch's build can answer your listener (AGENTS.md > Testing).
   `require_build()` asks `mirror` for the resident's sourceManifest and
   build fingerprint and compares them to this checkout's — so a gate
   that reads green has at least proven it was talking to the right
   machine. It matters more here than for a one-shot: a suite that
   restores a snapshot reconnects repeatedly, and each reconnect is a
   fresh chance to be answered by somebody else's guest.

WHAT IT IS NOT. It impersonates a host and therefore proves nothing about
the host application — same direction-of-evidence rule as askguest.py.
"""

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


class GuestGone(Exception):
    """The guest stopped answering: the connection closed, or a reply that
    the guest always sends never arrived. Raised rather than returned so a
    caller cannot accidentally continue past a dead machine."""


class WrongGuest(Exception):
    """Somebody answered, and it was not the build under test."""


class GuestWire:
    def __init__(self, port, host="127.0.0.1", name="nowwire",
                 reply_timeout=45.0, log=None):
        self.port = port
        self.host = host
        self.name = name
        self.reply_timeout = reply_timeout
        self._log = log if log is not None else (lambda s: print(s, flush=True))
        self._srv = None
        self._sock = None
        self._buf = b""
        self._id = 1000
        self.hello = None

    # --- the listener ----------------------------------------------------
    # Bound ONCE and kept across reconnects. The guest dials us, so between
    # a crash (or a snapshot restore) and the guest's next dial there must
    # be something listening; rebinding per connection leaves a window in
    # which the guest's retry is refused and the gate blames the guest.

    def listen(self):
        if self._srv is None:
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((self.host, self.port))
            s.listen(4)
            self._srv = s
        return self

    def accept(self, wait=240.0):
        """Take the next guest that dials in, and exchange hellos."""
        self.listen()
        self._srv.settimeout(wait)
        try:
            sock, peer = self._srv.accept()
        except socket.timeout:
            raise GuestGone(f"no guest dialled {self.host}:{self.port} "
                            f"within {wait:.0f}s")
        self._sock = sock
        self._sock.settimeout(self.reply_timeout)
        self._buf = b""
        # The guest sends its hello first and waits up to 8s for ours
        # (wire.c kHelloTimeoutTicks); miss that window and it drops the link.
        self.hello = self._read()
        self._send({"type": "hello", "contract": CONTRACT, "side": "host",
                    "version": "0", "name": self.name, "chunk": 4096})
        self._log(f"  guest dialled from {peer[0]}:{peer[1]} — "
                  f"{self.hello.get('name')} {self.hello.get('os')} "
                  f"build {self.hello.get('build')}")
        return self.hello

    def rebind(self):
        """Close the listener and open a fresh one.

        REQUIRED AFTER A SNAPSHOT RESTORE, and this is measured rather than
        precautionary. The guest retries its dial while no host is up, so
        connections pile up in the listening socket's ACCEPT BACKLOG. A
        `loadvm` rewinds the GUEST and touches none of them, so the next
        accept() hands back a connection whose guest-side no longer exists
        — and it is indistinguishable from a real dial until the guest
        never answers. Watched twice on 2026-08-07: once as "the guest
        closed the connection", once as "the connection is open and the
        event loop is not turning". Two different symptoms, one stale
        socket."""
        self.drop()
        if self._srv is not None:
            self._srv.close()
            self._srv = None
        return self.listen()

    def drop(self):
        """Close the guest connection but KEEP listening. This is how a
        gate hands the machine to a snapshot: the guest sees its host go
        away and falls back to redialling, which is a state that restores
        cleanly — unlike a live TCP conversation, whose peer no longer
        exists after a loadvm."""
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None
                self._buf = b""

    def close(self):
        self.drop()
        if self._srv is not None:
            self._srv.close()
            self._srv = None

    # --- framing ---------------------------------------------------------

    def _frame(self, payload):
        return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload

    def _send(self, obj):
        if self._sock is None:
            raise GuestGone("no guest connection")
        self._sock.sendall(self._frame(json.dumps(obj).encode()))

    def _read(self):
        while True:
            while len(self._buf) >= 8:
                _, _, _, length = struct.unpack(">BBHI", self._buf[:8])
                if len(self._buf) < 8 + length:
                    break
                payload = self._buf[8:8 + length]
                self._buf = self._buf[8 + length:]
                # Guest JSON carries raw MacRoman in names: repair-decode
                # rather than die on a machine whose owner used an option key.
                return json.loads(payload.decode("utf-8", "replace"))
            try:
                chunk = self._sock.recv(65536)
            except socket.timeout:
                raise GuestGone(
                    f"the guest did not answer within {self.reply_timeout:.0f}s "
                    "— the connection is open and the event loop is not turning")
            except OSError as e:
                raise GuestGone(f"the connection failed: {e}")
            if not chunk:
                raise GuestGone("the guest closed the connection")
            self._buf += chunk

    # --- asking ----------------------------------------------------------

    def ask(self, type_, **fields):
        """Send one request and return the reply that echoes its id.

        Frames that are not this request's answer are skipped: the guest
        emits log and status traffic unprompted, and a reader that treats
        the first frame as the reply reports whatever happened to arrive.
        A ping is answered inline — refusing to pong would make the guest
        drop a link this gate is about to call dead."""
        self._id += 1
        mid = self._id
        req = dict(fields)
        req["type"] = type_
        req["id"] = mid
        self._send(req)
        while True:
            msg = self._read()
            if msg.get("type") == "ping":
                self._send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            return msg

    def command(self, name, **args):
        req = {"name": name}
        if args:
            req["args"] = args
        return self.ask("command.request", **req)

    def census(self, probe, cursor=0):
        """One page of one probe, the way the Hardware module pages
        (contract: censusExchange). The `census` COMMAND cannot do this —
        it is declared single-page and always gathers cursor 0 — so a gate
        that only used the command would never reach page two of a probe
        and would call a machine safe that is not."""
        return self.ask("census.request", probe=probe, cursor=cursor)

    def exec_line(self, line):
        """The console face: a whole line in, the text this Mac's own
        Console page would have drawn back out (contract: the exec plane).
        Returns (ok, text)."""
        self._id += 1
        mid = self._id
        self._send({"type": "exec.request", "id": mid, "line": line})
        chunks = {}
        while True:
            msg = self._read()
            if msg.get("type") == "ping":
                self._send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") != mid:
                continue
            if msg.get("type") == "exec.output":
                chunks[msg.get("seq", len(chunks))] = msg.get("text", "")
                continue
            if msg.get("type") == "exec.result":
                text = "".join(chunks[k] for k in sorted(chunks))
                return bool(msg.get("ok")), text

    # --- liveness and identity -------------------------------------------

    def alive(self, note=""):
        """Require an ANSWER. Raises GuestGone if none comes."""
        reply = self.command("vers")
        # `vers` with no file refuses — deliberately. The gate wants a
        # REPLY, not an ok: a well-formed refusal proves the command table
        # was reached and the event loop pumped it, which is the whole
        # question. Requiring ok would make the gate depend on the verb's
        # semantics instead of on the machine being alive.
        if reply.get("type") != "command.result":
            raise GuestGone(f"the guest answered {reply.get('type')!r} "
                            f"rather than a command.result{note}")
        return reply

    def mirror(self):
        reply = self.command("mirror")
        out = reply.get("output", {}).get("mirror", {})
        if not out:
            raise GuestGone("the guest answered `mirror` with no mirror in it")
        return out

    def require_build(self, source_manifest, build_fingerprint):
        """Assert WHICH guest answered. See the class docstring."""
        ext = self.mirror().get("extension", {})
        got_src = ext.get("sourceManifest")
        got_build = ext.get("buildFingerprint")
        if got_src != source_manifest or got_build != build_fingerprint:
            raise WrongGuest(
                "this is not the build under test — the guest reports "
                f"sourceManifest {got_src} / buildFingerprint {got_build}, "
                f"this checkout built {source_manifest} / {build_fingerprint}. "
                "Another session's VM answered your listener (AGENTS.md > "
                "Testing: every guest on this Mac sees the host as 10.0.2.2).")
        return ext


def local_identity(build_dir):
    """This checkout's (sourceManifest, buildFingerprint), read from the
    generated Rez the extension build emits — the same two 40-hex fields
    scripts/bake-ext-image compares the guest's answer against."""
    path = os.path.join(build_dir, "ext", "now_ext_identity.r")
    with open(path) as f:
        raw = f.read()
    hex_ = ""
    for chunk in raw.replace("\r", "\n").split("\n"):
        if '$"' in chunk:
            hex_ += chunk.split('$"')[1].split('"')[0]
    if len(hex_) < 80:
        raise RuntimeError(f"could not read a fingerprint from {path}")
    return hex_[:40], hex_[40:80]


def wait_for(fn, timeout, interval=2.0):
    """Poll until fn() returns truthy or the timeout expires; returns the
    elapsed seconds and the value, or (elapsed, None)."""
    start = time.time()
    while time.time() - start < timeout:
        value = fn()
        if value:
            return time.time() - start, value
        time.sleep(interval)
    return time.time() - start, None
