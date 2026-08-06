#!/usr/bin/env python3
"""The socket half of the scene read — scripts/probes/nowwire.py :: scene().

    python3 scripts/probes/tests/scenewire_test.py   # or via scripts/test-native

`scene_test.py` drives the reassembly and the gates with no socket at all.
This drives the part that could only be got wrong on a socket, over a
`socketpair` with a scripted peer: no listener, no accept, no sleeping, no
machine — the peer's whole conversation is written into the buffer before the
call, so the test is deterministic.

Three things here are worth a test and nothing else can check them:

  * **a command reply that arrives DURING the transfer must survive it.**
    Every menu trial holds an armed `menuact` while it works. A scene read
    that ate that reply would turn a measured trial into a timeout, and the
    trial would be recorded as a machine that did not answer.
  * **a guest ping during the transfer must be answered.** Keepalive is
    guest-driven: two unanswered pings and the guest declares the host dead at
    about 65 s. A scene has a 60 s budget, so this is not a hypothetical.
  * **silence is not a refusal.** A guest with no scene plane says nothing —
    NOW-68K serves neither scene nor act — and the harness has to refuse with
    that fact rather than hang or report an empty machine.

MUTATIONS THIS HAS BEEN SEEN TO FAIL UNDER. Run 2026-07-31 against
scripts/probes/nowwire.py, one at a time, tree restored from git after each.

    mutation                                          tests that went red
    ------------------------------------------------  -------------------
 1  the scene loop stops servicing the link while a   midflight/reply-ok
    transfer is moving — no stash, no pong            ping/answered
      -  if self._route(msg): continue
      +  if False: continue

 2  bulk frames are read as control                   (dies: ConnectionError,
      -  if channel == CHANNEL_BULK: reader.on_bulk    "unparseable control
      +  if False: ...                                  JSON" on the body)

 3  a silent guest is reported as a refusal rather    silence/exit-2
    than a missing plane
      -  raise MissingScenePlane(...)
      +  raise

Mutation 1 is the one to read twice: BOTH failures it causes look like the
machine's fault from the trial's side. A lost act reply records a Mac that
never answered, and a missed pong has the guest declare this host dead
mid-run.
"""

import json
import os
import socket
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import nowwire  # noqa: E402
import scene as scenemod  # noqa: E402

FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append(f"{name}: got {got!r}, want {want!r}")


DOC = {"version": 1, "seq": 5, "capturedAt": 1.0, "source": "peek",
       "screen": {"w": 640, "h": 480},
       "menubar": {"app": "Finder",
                   "menus": [{"title": "\x14", "id": 128, "left": 10},
                             {"title": "File", "id": 129, "left": 38}]},
       "windows": [], "meta": {"errors": []}}


def ctl(obj) -> bytes:
    payload = json.dumps(obj).encode("mac_roman", "replace")
    return struct.pack(">BBHI", 0, 1, 0, len(payload)) + payload


def bulk(transfer, payload, end) -> bytes:
    return struct.pack(">BBHI", 1, 1 if end else 0, transfer,
                       len(payload)) + payload


def linked():
    """A GuestLink over one end of a socketpair, and the peer's end."""
    host, guest = socket.socketpair()
    link = nowwire.GuestLink(host, {"name": "test",
                                    "contract": nowwire.WIRE_CONTRACT_REVISION})
    return link, guest


def deliver(guest, request_id, doc=DOC, *, transfer=4, chunk=64, extra=()):
    """Write one whole scene, with `extra` frames spliced after the first."""
    body = json.dumps(doc).encode("utf-8")
    frames = [ctl({"type": "scene.begin", "id": request_id,
                   "transfer": transfer, "bytes": len(body), "irVersion": 1,
                   "seq": doc["seq"], "walkMs": 55, "source": "peek"})]
    pieces = [body[i:i + chunk] for i in range(0, len(body), chunk)]
    for i, piece in enumerate(pieces):
        frames.append(bulk(transfer, piece, i == len(pieces) - 1))
        if i == 0:
            frames.extend(extra)
    frames.append(ctl({"type": "scene.end", "id": request_id,
                       "transfer": transfer, "ok": True, "sendMs": 9}))
    guest.sendall(b"".join(frames))


def sent_by_host(guest) -> list:
    """Everything the link wrote, decoded. Drains without blocking."""
    guest.setblocking(False)
    buf = b""
    try:
        while True:
            chunk = guest.recv(65536)
            if not chunk:
                break
            buf += chunk
    except BlockingIOError:
        pass
    guest.setblocking(True)
    out = []
    while len(buf) >= 8:
        _c, _f, _t, length = struct.unpack(">BBHI", buf[:8])
        out.append(json.loads(buf[8:8 + length].decode("mac_roman")))
        buf = buf[8 + length:]
    return out


# --- the happy path ----------------------------------------------------------

def a_scene_arrives_whole():
    link, guest = linked()
    deliver(guest, 1)
    doc, env = link.scene(timeout=5.0)
    check("whole/app", scenemod.menubar_app(doc), "Finder")
    check("whole/menu-id", scenemod.menu_by_title(doc, "File")["id"], 129)
    check("whole/walkMs", env["walkMs"], 55)
    asked = sent_by_host(guest)
    check("whole/asked", asked[0]["type"], "scene.request")
    check("whole/asked-id", asked[0]["id"], 1)


def the_tuning_arguments_reach_the_wire():
    link, guest = linked()
    deliver(guest, 1)
    link.scene(stale_after_ms=250, chunk_kb=8, pace_ms=2, timeout=5.0)
    req = sent_by_host(guest)[0]
    check("tuning/stale", req["staleAfterMs"], 250)
    check("tuning/chunk", req["chunkKb"], 8)
    check("tuning/pace", req["paceMs"], 2)


# --- what else is on the wire while a scene is moving ------------------------

def a_command_reply_that_lands_mid_transfer_survives():
    """The armed act's reply. Losing it turns a trial into a timeout."""
    link, guest = linked()
    reply = ctl({"type": "command.result", "id": 77, "ok": True,
                 "output": {"menuact": [["item", "1"]]}})
    deliver(guest, 1, extra=[reply])
    doc, _env = link.scene(timeout=5.0)
    check("midflight/scene", scenemod.menubar_app(doc), "Finder")
    try:
        got = link.read_result(77, timeout=0.2)
    except (TimeoutError, OSError):
        # What the mutation looks like from the trial's side: the act never
        # answered. Named, because a bare traceback here would read as a flaky
        # test rather than as a lost measurement.
        FAILURES.append("midflight/reply-ok: the reply that arrived during "
                        "the scene was lost; the trial would record a "
                        "machine that never answered")
        return
    check("midflight/reply-ok", got.get("ok"), True)
    check("midflight/reply-id", got.get("id"), 77)


def a_ping_during_a_scene_is_answered():
    link, guest = linked()
    deliver(guest, 1, extra=[ctl({"type": "ping", "id": 900})])
    link.scene(timeout=5.0)
    replies = [m for m in sent_by_host(guest) if m.get("type") == "pong"]
    check("ping/answered", [m["id"] for m in replies], [900])


# --- refusals ----------------------------------------------------------------

def a_guest_refusal_is_the_guests():
    link, guest = linked()
    guest.sendall(ctl({"type": "scene.end", "id": 1, "transfer": 4,
                       "ok": False, "reason": "a transfer is already in "
                                              "flight"}))
    try:
        link.scene(timeout=5.0)
        FAILURES.append("refuse/raised: did not raise")
    except scenemod.SceneUnavailable as exc:
        check("refuse/by-guest", exc.refused_by_guest, True)


def silence_is_a_missing_plane_not_a_refusal():
    # A guest that does not serve the scene plane says NOTHING: the message is
    # a typed control frame it does not recognise. NOW-68K is exactly this.
    link, _guest = linked()
    quiet, sys.stderr = sys.stderr, open(os.devnull, "w")   # its report is
    try:                                                    # the point, not
        link.require_scene_plane("scenewire_test", timeout=0.2)
        FAILURES.append("silence/exit-2: did not refuse")
    except nowwire.MissingScenePlane as exc:
        check("silence/exit-2", exc.code, 2)
    except scenemod.SceneUnavailable:
        FAILURES.append("silence/exit-2: raised SceneUnavailable, which reads "
                        "as the guest having answered")
    finally:
        sys.stderr.close()
        sys.stderr = quiet


def a_served_plane_hands_the_first_scene_back():
    # The gate is not a wasted transfer: it IS the case's first fetch.
    link, guest = linked()
    deliver(guest, 1)
    doc, _env = link.require_scene_plane("scenewire_test", timeout=5.0)
    check("gate/keeps-scene", scenemod.menubar_app(doc), "Finder")


TESTS = [v for k, v in sorted(globals().items())
         if callable(v) and not k.startswith("_")
         and k not in ("check", "ctl", "bulk", "linked", "deliver",
                       "sent_by_host")
         and getattr(v, "__module__", "") == "__main__"]


def main() -> int:
    for fn in TESTS:
        fn()
    if FAILURES:
        for f in FAILURES:
            print("FAIL " + f)
        print(f"\n{len(FAILURES)} failed of {len(TESTS)} checks")
        return 1
    print(f"scenewire: {len(TESTS)} checks ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
