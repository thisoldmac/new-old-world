"""The probe harnesses' wire client — NOW's transport, not Mirror's.

Ported from `timbottu/mirror/tests/trials.py` (class `Agent`). The measurement
methodology crossed intact; the transport could not, because the two projects
run their wire in OPPOSITE DIRECTIONS.

    Mirror   the probe DIALS 127.0.0.1:<agent-port>, newline-delimited JSON,
             one request object per line, one reply object per line.
    NOW      the probe LISTENS. The guest dials it, speaks `hello` first, and
             every message is an 8-byte frame (channel, flags, transfer,
             length) with a JSON payload.

That inversion is not a detail to paper over. Upstream's client carried a
hard-won comment about ONE PERSISTENT CONNECTION, because Mirror's guest
served a single connection serially and a socket-per-request raced its
accept — producing, once, a completely fictitious bug report. NOW cannot
have that bug: there is exactly one connection because the guest opened it,
and a second dial with a live session's name is refused `busy` by the host.
The lesson survives as its consequence rather than its mechanism: this
client never reconnects mid-run, and a dropped link ends the run rather than
silently starting a second session against a machine in an unknown state.

What did NOT change, and must not:

  * `ok:false` is a REPLY, not a failure to talk. `GuestError` is raised so an
    honest refusal (`unknown-command`, `not_actionable`) can never be counted
    as a transport failure. Conflating the two is how a healthy act plane once
    got written up as broken.
  * The split send/receive pair (`send_async` / `read_result`) exists for one
    reason: an act request is ARMED for as long as the responder is inside it,
    and the whole no-hijack question is what a real click does DURING that
    window. It deliberately has no retry — a retry re-arms and quietly
    measures a machine in a state the trial never asked for.
  * MacRoman. Guest payloads carry raw MacRoman bytes, and a UTF-8 decode
    turns them into U+FFFD. The contract says `exec.output.text` is MacRoman
    and pins `é` = 0x8E.

One thing this client does that upstream's did not have to: **it reads a
transfer.** Mirror's `observe` answered with the menu bar in a bounded reply,
so its probes never touched the bulk plane. NOW ships a menu bar only as part
of a scene — `scene.begin`, bulk frames, `scene.end` — so `scene()` here is
what four probe cases stand on. The reassembly, the IR gate and the staleness
rule live in `scene.py`, where a test can drive them; this file holds only the
socket half.

Sources for the transport half: `contract/wire_limits.h`,
`contract/asyncapi.yaml` (preamble), `now-host/Sources/Host/Session.swift`
(`gate`), `tools/fakeguest.py` (the framing, which is symmetric).
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import time

from scene import SceneReader, SceneUnavailable

# contract/wire_limits.h. Restated here rather than parsed because a probe is
# not part of the build, and a probe that silently followed a changed constant
# would report numbers from a wire it did not describe.
WIRE_CONTRACT_REVISION = 2
FRAME_HEADER_BYTES = 8
CHANNEL_CONTROL = 0
CHANNEL_BULK = 1
FLAG_END = 0x01
MAX_PAYLOAD = 32768

# Both guests size their CONTROL receive buffer at 4096 (now-guest-ppc
# src/core/contract.h kNowMaxControl, now-guest-68k src/core/frame.h
# NOW68K_CONTROL_BUFFER_CAP). wire_limits.h deliberately does not hoist this.
MAX_CONTROL_PAYLOAD = 4096

# now-host/Sources/Host/ContractMessages.swift
DEFAULT_CHUNK = 8192

# now-guest-ppc/src/core/wire.c: kHelloTimeoutTicks = 60 * 8. The guest gives
# the host EIGHT SECONDS to answer hello, then drops and redials. A probe that
# is slow here measures its own reconnect loop.
HELLO_REPLY_BUDGET = 8.0

# now-host/Tests/HostTests/MetalExecTests.swift: "The guest dials out on its
# own cadence, so the harness waits rather than connecting. 90s is generous on
# purpose: the claim under test is never 'it comes back fast'."
GUEST_DIAL_BUDGET = 90.0

# How long one scene may take, walk and transfer together. Generous on
# purpose: the producer's own note sizes the document at ~21.5 KB with menus,
# the walk runs inside a cooperative event loop with the whole wire machine
# above it, and `scene.begin` reports `walkMs` precisely because nobody has
# measured that time on a real Macintosh yet. A budget tight enough to be
# interesting would be a budget that fails a healthy machine.
SCENE_BUDGET = 60.0


class GuestError(Exception):
    """The guest answered `ok:false`. This is a RESULT, not a failure to talk.

    Verbatim in intent from upstream's `trials.GuestError`. The distinction it
    encodes is the reason the reply rate and the actuation rate are counted
    separately in `tally.py`.
    """

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class MissingVerbs(SystemExit):
    """This machine does not serve what the harness measures.

    Raised loudly, at the top of a run, BEFORE any trial. The alternative — a
    harness that connects, finds nothing to drive, and reports 0/0 — is the
    failure mode this repository has a standing rule against: a gate that
    reads as coverage in a directory listing and proves nothing.

    The exit status is 2 (not 1) so a caller can tell "this machine cannot be
    measured yet" from "the measurement found something".
    """

    def __init__(self, probe: str, missing, served, note: str = ""):
        self.probe = probe
        self.missing = list(missing)
        self.served = sorted(served)
        lines = [
            "",
            f"{probe}: REFUSING TO RUN — this guest does not serve what this "
            "harness measures.",
            "",
            "missing:",
        ]
        for verb in self.missing:
            lines.append(f"    {verb}")
        lines += [
            "",
            f"served by this guest ({len(self.served)}): "
            + " ".join(self.served),
            "",
        ]
        if note:
            lines += [note, ""]
        lines += [
            "This harness is a PORT of an upstream measurement (see its "
            "docstring for",
            "the number it produced there). It is checked in so that the day "
            "the verbs",
            "above land, the measurement reports instead of having to be "
            "re-authored.",
            "It is not evidence about this machine until then, and it will "
            "not pretend",
            "to be by exiting 0.",
            "",
        ]
        self.report = "\n".join(lines)
        # SystemExit's first argument IS its exit status, so the message
        # cannot be passed to it: `SystemExit("text")` prints the text and
        # exits 1, which is the status a FINDING uses. A machine that cannot
        # be measured is not a finding, and the two must not share a code.
        print(self.report, file=sys.stderr)
        super().__init__(2)


class MissingScenePlane(SystemExit):
    """This guest does not answer `scene.request`, so its menu bar is unreadable.

    A sibling of `MissingVerbs` and for the same reason: a harness that
    connected, found no scene plane, and reported 0/0 would read as a guard
    holding. Exit status 2, again so "this machine cannot be measured" is
    distinguishable from "the measurement found something".

    It is a SEPARATE refusal from a missing verb because it is a separate
    fact. `scene.request` is a typed control message and never appears in
    `help`, so no verb list can carry it: NOW-68K serves `observe` and would
    pass a verb gate while having no scene plane and no act plane at all.
    """

    def __init__(self, probe: str, detail: str, note: str = ""):
        lines = [
            "",
            f"{probe}: REFUSING TO RUN — this guest does not serve the SCENE "
            "plane.",
            "",
            f"    {detail}",
            "",
            "The menu bar comes from a scene and from nowhere else: `observe` "
            "does not",
            "report one, deliberately (docs/streaming-a-scene.md ruled that a "
            "tree is a",
            "TRANSFER, and src/scene/scene_walk.c already walks the bar over "
            "scene.request).",
            "A guest with no scene plane therefore has no menu bar this "
            "harness can read,",
            "and every menu case would be measuring a machine it could not "
            "address.",
            "",
            "`scene.request` is a typed control message, not a command, so it "
            "is not in",
            "`help` and the verb gate above cannot see it. This is the only "
            "way to know.",
            "",
        ]
        if note:
            lines += [note, ""]
        self.report = "\n".join(lines)
        print(self.report, file=sys.stderr)
        super().__init__(2)


def frame(payload: bytes, channel: int = CHANNEL_CONTROL,
          flags: int = FLAG_END, transfer: int = 0) -> bytes:
    """One frame, header and payload in ONE buffer.

    The contract requires a single contiguous send per frame: back-to-back
    small writes are dropped by real classic-Mac NICs (the PB1400c Farallon
    driver drops the second frame of a TX burst). Building the bytes here and
    handing them to one `sendall` is what makes that true at the call site.
    """
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload {len(payload)} > {MAX_PAYLOAD}")
    return struct.pack(">BBHI", channel, flags, transfer, len(payload)) + payload


def _decode(raw: bytes) -> str:
    """MacRoman first. See the module docstring."""
    try:
        return raw.decode("mac_roman")
    except Exception:
        return raw.decode("utf-8", "replace")


class GuestLink:
    """A host-side listener that a NOW guest dials, gated and driven.

    Usage:

        link = GuestLink.await_guest(port=5252)
        print(link.hello["name"], link.hello.get("build"))
        rows = link.command("ps")

    Everything is single-threaded and synchronous on purpose. A probe is a
    measurement instrument; a background reader thread would make the moment a
    frame arrived unobservable, and the no-hijack case is entirely about
    moments.
    """

    def __init__(self, sock: socket.socket, hello: dict, *,
                 identity_name: str = "NOW probe harness",
                 identity_version: str = "probe"):
        self.sock = sock
        self.hello = hello
        self.identity_name = identity_name
        self.identity_version = identity_version
        self._buf = b""
        self._id = 0
        self._pending: dict = {}      # id -> reply object already read
        self._unsolicited: list = []  # guest-initiated messages, kept in order
        self._verbs: set | None = None

    # --- construction --------------------------------------------------

    @classmethod
    def await_guest(cls, port: int, *, host: str = "0.0.0.0",
                    timeout: float = GUEST_DIAL_BUDGET,
                    expect_name: str | None = None,
                    identity_name: str = "NOW probe harness",
                    identity_version: str = "probe") -> "GuestLink":
        """Listen, accept ONE guest, run the hello gate, return the link.

        `expect_name` is this harness's version of `MetalMachineGuard`: every
        QEMU guest on this Mac sees the host as 10.0.2.2, and any session's VM
        can answer this listener. A run that does not say which machine it
        expected can silently measure someone else's — upstream's lab notes
        record a refusal case passing against another branch's guest, because
        "unknown command" is also a refusal with a reason.
        """
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((host, port))
        srv.listen(1)
        srv.settimeout(timeout)
        print(f"listening on {host}:{port} — waiting up to {timeout:.0f}s for "
              f"a guest to dial", flush=True)
        try:
            conn, peer = srv.accept()
        except socket.timeout:
            raise SystemExit(
                f"no guest dialed {host}:{port} within {timeout:.0f}s. "
                "The guest dials the host, never the other way round: check "
                "the machine's settings file names THIS Mac and THIS port "
                "(docs/lab-setup.md, scripts/deploy-68k).")
        finally:
            srv.close()
        conn.settimeout(HELLO_REPLY_BUDGET)
        link = cls(conn, {}, identity_name=identity_name,
                   identity_version=identity_version)
        link.hello = link._gate()
        name = link.hello.get("name")
        print(f"guest {name!r} from {peer[0]} — contract "
              f"{link.hello.get('contract')}, version "
              f"{link.hello.get('version')}, build {link.hello.get('build')}",
              flush=True)
        if expect_name is not None and \
                (name or "").strip().lower() != expect_name.strip().lower():
            link.close()
            raise SystemExit(
                f"WRONG MACHINE: expected guest {expect_name!r}, got {name!r}. "
                "Refusing to measure. Every VM on this Mac can reach this "
                "listener; a number attributed to the wrong machine is worse "
                "than no number.")
        conn.settimeout(None)
        return link

    def _gate(self) -> dict:
        """The host half of the handshake, as `Session.gate()` performs it."""
        msg = self._read_message()
        if msg.get("type") != "hello":
            self._send({"type": "refuse", "contract": WIRE_CONTRACT_REVISION,
                        "reason": "hello must be first"})
            self.close()
            raise SystemExit(f"guest spoke {msg.get('type')!r} before hello")
        if msg.get("contract") != WIRE_CONTRACT_REVISION:
            self._send({"type": "refuse", "contract": WIRE_CONTRACT_REVISION,
                        "reason": "contract revision"})
            self.close()
            raise SystemExit(
                f"contract revision {msg.get('contract')} != "
                f"{WIRE_CONTRACT_REVISION}")
        chunk = min(int(msg.get("chunk") or DEFAULT_CHUNK), DEFAULT_CHUNK)
        self._send({"type": "hello", "contract": WIRE_CONTRACT_REVISION,
                    "side": "host", "version": self.identity_version,
                    "name": self.identity_name, "chunk": chunk})
        return msg

    # --- framing -------------------------------------------------------

    def _send(self, obj: dict) -> None:
        payload = json.dumps(obj).encode("mac_roman", "replace")
        if len(payload) > MAX_CONTROL_PAYLOAD:
            raise ValueError(
                f"control payload {len(payload)} > {MAX_CONTROL_PAYLOAD}; "
                "both guests' control receive buffers are 4096 bytes")
        self.sock.sendall(frame(payload))

    def _read_frame(self) -> tuple:
        """One frame: (channel, flags, transfer, payload). Blocks.

        Split out from `_read_message` when the scene read landed: a scene is
        a TRANSFER, so one caller in this file needs the bulk frames rather
        than the control stream, and both need the same header parse. One
        parser, two readers.
        """
        while True:
            if len(self._buf) >= FRAME_HEADER_BYTES:
                channel, flags, transfer, length = struct.unpack(
                    ">BBHI", self._buf[:FRAME_HEADER_BYTES])
                if len(self._buf) >= FRAME_HEADER_BYTES + length:
                    payload = self._buf[FRAME_HEADER_BYTES:
                                        FRAME_HEADER_BYTES + length]
                    self._buf = self._buf[FRAME_HEADER_BYTES + length:]
                    if channel not in (CHANNEL_CONTROL, CHANNEL_BULK):
                        raise ConnectionError(f"unknown channel {channel}")
                    return channel, flags, transfer, payload
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("guest closed the link")
            self._buf += chunk

    @staticmethod
    def _control_json(payload: bytes) -> dict:
        text = _decode(payload)
        try:
            return json.loads(text)
        except ValueError as exc:
            raise ConnectionError(
                f"guest sent unparseable control JSON: {exc}: {text[:200]!r}")

    def _read_message(self) -> dict:
        """Read one CONTROL frame's JSON object.

        Bulk frames are consumed and discarded with a note: no probe reads the
        bulk plane through THIS path, and silently interleaving them into the
        control stream would corrupt a reply. `scene()` reads its own
        transfer whole, synchronously, so a scene's bytes never reach here.
        """
        while True:
            channel, _flags, _transfer, payload = self._read_frame()
            if channel == CHANNEL_BULK:
                continue              # not this instrument's plane
            return self._control_json(payload)

    def _pump(self, want_id: int | None, deadline: float | None) -> dict:
        """Read until the reply for `want_id` arrives, servicing the link.

        Keepalive is GUEST-DRIVEN: it pings after 30s of silence and declares
        the host dead after two unanswered pings (~65s). A probe that blocks
        on a slow verb without answering ping kills its own session at the
        65-second mark and reports it as a wedge. So ping is answered here,
        inside the wait, rather than by a thread.
        """
        while True:
            if want_id is not None and want_id in self._pending:
                return self._pending.pop(want_id)
            if deadline is not None:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(
                        f"no reply for id {want_id} within the trial's budget")
                self.sock.settimeout(left)
            msg = self._read_message()
            if self._route(msg):
                continue
            self._unsolicited.append(msg)
            if want_id is None:
                return msg

    def _route(self, msg: dict) -> bool:
        """Service one control message. True when this consumed it.

        The link's own housekeeping, in one place because two readers need it:
        `_pump`, which waits for a command's reply, and `scene()`, which waits
        for a transfer and must not swallow a command reply that arrives
        mid-scene — an act request is often still in flight, and its reply is
        the trial's.
        """
        kind = msg.get("type")
        if kind == "ping":
            self._send({"type": "pong", "id": msg.get("id")})
            return True
        if kind == "bye":
            raise ConnectionError(f"guest said bye: {msg.get('code')}")
        if kind in ("command.result", "exec.result"):
            mid = msg.get("id")
            if mid is None:
                return False
            self._pending[mid] = msg
            return True
        if kind == "error" and msg.get("id") is not None:
            self._pending[msg["id"]] = msg
            return True
        return False

    # --- the command plane ---------------------------------------------

    def send_async(self, name: str, args: dict | None = None,
                   line: str | None = None) -> int:
        """Send one `command.request` and return its id, WITHOUT reading.

        The armed-window primitive. See the module docstring: no retry, ever.
        """
        self._id += 1
        req = {"type": "command.request", "id": self._id, "name": name}
        if args:
            for key in args:
                # contract preamble, the arg-key shadowing rule. The classic
                # guest scans a frame FLAT and first occurrence wins, so an arg
                # named `name` is read as the COMMAND name. `launch` shipped
                # that bug to metal; the family uses `target`.
                if key in ("type", "id", "name", "args", "line"):
                    raise ValueError(
                        f"arg {key!r} shadows an envelope key — the guest "
                        "scans flat and would read it as the command name")
            req["args"] = args
        if line is not None:
            req["line"] = line
        self._send(req)
        return self._id

    def read_result(self, mid: int, timeout: float | None = 30.0) -> dict:
        """The whole reply object, `ok` included — never raises on `ok:false`.

        For the no-hijack probe an honest refusal is the EXPECTED answer and
        must be readable as data, so this is the raw form. `command()` is the
        form that raises.
        """
        deadline = None if timeout is None else time.time() + timeout
        return self._pump(mid, deadline)

    def command(self, name: str, args: dict | None = None,
                line: str | None = None, timeout: float | None = 30.0) -> dict:
        """Send one command, return its `output` object. Raises GuestError."""
        mid = self.send_async(name, args, line)
        reply = self.read_result(mid, timeout)
        if not reply.get("ok"):
            err = reply.get("error") or {}
            raise GuestError(err.get("code") or reply.get("code") or "error",
                             err.get("message") or reply.get("message") or "")
        return reply.get("output") or {}

    # --- the scene plane (a TRANSFER, not a command) --------------------

    def scene(self, *, stale_after_ms: int | None = None,
              chunk_kb: int | None = None, pace_ms: int | None = None,
              timeout: float = SCENE_BUDGET) -> tuple:
        """Ask for one walk of the machine and read it whole.

        Returns `(document, envelope)`: the decoded supported IR object and what
        `scene.begin` said about the walk. Raises `scene.SceneUnavailable`
        when there is no document — including when the GUEST refused, which
        is a different fact and is flagged on the exception.

        Synchronous and blocking, by the same argument as everything else in
        this file: a probe is a measurement instrument, and a background
        reader would make the moment a frame arrived unobservable. It reads
        its own transfer to the end, which is also why `_read_message`'s
        bulk-discarding path can never see a scene's bytes.

        Commands whose replies arrive during the transfer are STASHED, not
        dropped (`_route`). That is not a nicety: the menu cases hold an armed
        act while they work, and a scene read that ate its reply would turn a
        measured trial into a timeout.
        """
        self._id += 1
        req: dict = {"type": "scene.request", "id": self._id}
        if stale_after_ms is not None:
            req["staleAfterMs"] = int(stale_after_ms)
        if chunk_kb is not None:
            req["chunkKb"] = int(chunk_kb)
        if pace_ms is not None:
            req["paceMs"] = int(pace_ms)
        self._send(req)

        reader = SceneReader(self._id)
        deadline = time.time() + timeout
        # SILENCE IS NOT A REFUSAL, and the two must not arrive here as the
        # same exception. A guest that serves the plane and cannot serve this
        # scene says `scene.end ok:false`; a guest that does not serve the
        # plane says nothing at all, because `scene.request` is a control
        # message it does not recognise.
        silent = SceneUnavailable(
            f"no scene.end within {timeout:.0f}s. A guest that serves the "
            "scene plane answers a scene it cannot give with scene.end "
            "ok:false, so silence here is not a refusal — it is a guest with "
            "no scene plane, or one whose walk did not return.")
        try:
            while not reader.done:
                left = deadline - time.time()
                if left <= 0:
                    raise silent
                self.sock.settimeout(left)
                try:
                    channel, flags, transfer, payload = self._read_frame()
                except socket.timeout:
                    raise silent
                if channel == CHANNEL_BULK:
                    reader.on_bulk(transfer, payload, bool(flags & FLAG_END))
                    continue
                msg = self._control_json(payload)
                if self._route(msg):
                    continue
                reader.on_control(msg)
                if msg.get("type") not in ("scene.begin", "scene.end"):
                    self._unsolicited.append(msg)
        finally:
            self.sock.settimeout(None)
        return reader.result(), reader.envelope()

    def require_scene_plane(self, probe: str, note: str = "",
                            timeout: float = SCENE_BUDGET) -> tuple:
        """Refuse unless this guest serves scenes — and keep the first one.

        `scene.request` is a typed control message, NOT a command, so it does
        not appear in `help` and `require_verbs` cannot see it. The only way
        to know is to ask: a guest that serves the plane answers `scene.begin`
        or an honest `scene.end ok:false`, and one that does not (NOW-68K
        serves neither scene nor act) answers nothing at all.

        The ask is not wasted. The gate IS the case's first fetch, and the
        caller keeps the document.
        """
        try:
            return self.scene(timeout=timeout)
        except SceneUnavailable as exc:
            if exc.refused_by_guest:
                # It answered. The plane is there; this moment was wrong.
                raise
            raise MissingScenePlane(probe, str(exc), note)

    # --- the typed message planes (file.*, process.*) -------------------
    #
    # Six of the guest's verbs are console-only (`wire=0` in cmd_help.c) and
    # cross the wire as typed CONTROL MESSAGES rather than commands:
    # put/mv/trash/untrash/mkdir/clear are `file.get`, `file.move`,
    # `file.trash`, `file.restore`, `file.mkdir`. Sending
    # `{"name":"mkdir"}` gets `unknown-command`, which a probe would then have
    # to interpret — so the two planes are separate here, and a harness that
    # needs the filesystem oracle uses this one.

    def message(self, obj: dict) -> None:
        """Send one typed control message. No id correlation: these planes
        answer with their own message types, not `command.result`."""
        self._send(obj)

    def wait_for_types(self, types, timeout: float = 30.0) -> dict:
        """Read until an unsolicited message of one of `types` arrives.

        Anything else the guest sends in the meantime is kept, in order, in
        `self._unsolicited` — a probe that discarded interleaved messages would
        lose the one that explained why the oracle read the way it did.
        """
        want = set(types)
        deadline = time.time() + timeout
        # Anything already buffered counts, oldest first.
        for i, msg in enumerate(self._unsolicited):
            if msg.get("type") in want:
                return self._unsolicited.pop(i)
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise TimeoutError(f"no {sorted(want)} within {timeout:.0f}s")
            self.sock.settimeout(left)
            msg = self._pump(None, deadline)
            if msg.get("type") in want:
                if self._unsolicited and self._unsolicited[-1] is msg:
                    self._unsolicited.pop()
                return msg

    # --- reading a rowArray --------------------------------------------
    #
    # NOW answers a command with `output: {"<verb>": [[label, value], ...]}` —
    # a table for a person to read, not a struct. Mirror answered with a typed
    # result object (`r["x"]`, `r["value"]`, `r["windows"]`). Every ported
    # probe that reaches for a field goes through here, so the impedance
    # mismatch lives in ONE place and a probe reading a label that no longer
    # exists fails loudly instead of comparing against None.

    @staticmethod
    def rows(output: dict, verb: str) -> list:
        rows = output.get(verb)
        if rows is None:
            raise GuestError("no-rows",
                             f"reply carried no {verb!r} rows: "
                             f"{sorted(output)}")
        return rows

    @classmethod
    def field(cls, output: dict, verb: str, label: str):
        for row in cls.rows(output, verb):
            if row and row[0] == label:
                return row[1] if len(row) > 1 else None
        raise GuestError("no-field",
                         f"{verb} reported no {label!r} row: "
                         f"{[r[0] for r in cls.rows(output, verb) if r]}")

    @classmethod
    def maybe_field(cls, output: dict, verb: str, label: str, default=None):
        try:
            return cls.field(output, verb, label)
        except GuestError:
            return default

    # --- the verb surface, as THIS machine reports it -------------------

    def served_verbs(self) -> set:
        """What this guest actually serves, from its own `help` table.

        Asked of the machine rather than assumed from the contract. The
        contract declares `winact`/`textget`/`textset` AHEAD OF ANY GUEST by
        its own rule, so a harness that trusted the contract would run against
        a machine that answers every call `unknown-command` and would report
        that as a measurement.
        """
        if self._verbs is None:
            try:
                out = self.command("help")
                self._verbs = {row[0] for row in self.rows(out, "help")
                               if row and isinstance(row[0], str)}
            except GuestError as exc:
                # A peer that does not serve `help` cannot be asked what it
                # serves, so it serves nothing this instrument can verify.
                # Reported as an empty set rather than an exception, so the
                # caller's refusal names the verbs the harness needs — which
                # is the useful message — instead of a confusing failure in
                # the discovery step.
                print(f"  (this peer does not answer `help`: {exc}. Treating "
                      f"its verb surface as unknown, which refuses "
                      f"everything.)", file=sys.stderr)
                self._verbs = set()
        return self._verbs

    def require_verbs(self, probe: str, *verbs: str, note: str = "") -> None:
        """Refuse loudly unless every named verb is served. See MissingVerbs."""
        served = self.served_verbs()
        missing = [v for v in verbs if v not in served]
        if missing:
            raise MissingVerbs(probe, missing, served, note)

    def close(self) -> None:
        try:
            self._send({"type": "bye", "code": "normal"})
        except Exception:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


# --- argument plumbing every probe shares ------------------------------------

def add_link_args(ap) -> None:
    """The connection flags, spelled the same way in every probe.

    Deliberately NOT `--agent-port`: upstream's flag named a port the probe
    dialed, and keeping the name for a port the probe LISTENS on would be a
    trap for anyone reading both repositories side by side.
    """
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("NOW_METAL_PORT") or 0) or None,
                    help="port THIS harness listens on and the guest dials "
                         "(default: $NOW_METAL_PORT)")
    ap.add_argument("--expect-guest",
                    default=os.environ.get("NOW_METAL_GUEST") or None,
                    help="refuse any guest whose hello name is not this. "
                         "Every VM on this Mac can reach the listener.")
    ap.add_argument("--wait", type=float, default=GUEST_DIAL_BUDGET,
                    help="seconds to wait for the guest to dial")


def link_from_args(args) -> GuestLink:
    if not args.port:
        raise SystemExit(
            "no port: pass --port or set NOW_METAL_PORT. The guest dials the "
            "host, so this is the port THIS process listens on and the port "
            "the machine's settings file must name (docs/lab-setup.md).")
    return GuestLink.await_guest(args.port, timeout=args.wait,
                                 expect_name=args.expect_guest)


def refuse_without_metal(probe: str) -> None:
    """These drive a live machine. Running one is an attended decision.

    Ported harnesses are checked in unrun (P2, 2026-07-31: no hardware, no VM,
    no NOW_METAL on the porting bench). The repo's own convention already
    gates live-machine work behind NOW_METAL; this makes an accidental
    `python3 scripts/probes/<x>.py` a refusal rather than a machine being
    driven by someone who was reading the file.
    """
    if not os.environ.get("NOW_METAL"):
        print(f"{probe}: NOW_METAL is not set.\n"
              "  This harness drives a LIVE Macintosh: it moves the mouse, "
              "clicks menus,\n"
              "  creates and deletes folders, and in one case closes windows. "
              "Set NOW_METAL=1\n"
              "  when you mean it, and read the harness's docstring first — "
              "it says what it\n"
              "  will do to the machine.", file=sys.stderr)
        raise SystemExit(2)
