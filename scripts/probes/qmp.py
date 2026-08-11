"""A real mouse, from OUTSIDE the guest. Ported near-verbatim from
`archive/mirror-standalone-2026-08-09/tests/nohijack-probe.py`.

This is the one part of the no-hijack harness that crossed unchanged, because
it never touched Mirror's wire: it drives QEMU's own input plane over QMP. The
emulated machine's hardware input arrives from outside the guest CPU and is
indistinguishable to the application from a human's hand. That is what "a real
user click" has to mean in this measurement.

QMP is the STIMULUS, never the mechanism under test. The act verbs have no QMP
anywhere in their path; if they did, the probe would be measuring itself.

The closed-loop positioning is here too, and its comments are upstream's
because they are a record of what a machine did rather than an opinion. The
short version, which cost a whole run to learn: the mac99 mouse is
RELATIVE-only and OS 9 applies acceleration, so an absolute position can only
be reached with feedback — and feedback is exactly what is unavailable during
the moment the measurement is about, because the responder is inside the verb
and not servicing its socket. Hence pin-then-replay-a-learned-hop.

WHAT THIS NEEDS FROM NOW THAT NOW DOES NOT HAVE: a `mouseloc` verb. Every
feedback loop below takes the reader as a callable so the harness does not
hard-code a verb spelling that has not been decided, but there is no reading
of the guest's cursor on NOW's wire today and these functions cannot run
without one. The probes that use them refuse at the top; see
`nohijack-probe.py`.
"""

from __future__ import annotations

import json
import socket
import time

# Measured by pinning, not assumed. Upstream's guest was 800x600; a different
# screen makes every learned hop wrong, which is why `pin` returns where it
# believes it is and the callers verify against the guest.
SCREEN_W, SCREEN_H = 800, 600


class Qmp:
    """Minimal QMP input driver — `rel` and `btn`, the same two primitives
    MirrorKit's QmpClient uses."""

    def __init__(self, path: str, timeout: float = 15.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self._readline()                    # greeting
        self.command("qmp_capabilities")

    def _readline(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("qmp closed")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line) if line.strip() else {}

    def command(self, execute: str, arguments: dict | None = None) -> dict:
        obj = {"execute": execute}
        if arguments:
            obj["arguments"] = arguments
        self.sock.sendall((json.dumps(obj) + "\r\n").encode())
        while True:
            msg = self._readline()
            if "error" in msg:
                raise RuntimeError(f"qmp {execute}: {msg['error']}")
            if "return" in msg:
                return msg["return"]

    def _events(self, events: list) -> None:
        self.command("input-send-event", {"events": events})

    def rel(self, dx: int, dy: int, step: int = 3, pace: float = 0.003) -> None:
        for axis, delta in (("x", dx), ("y", dy)):
            if not delta:
                continue
            sign = step if delta > 0 else -step
            moved = 0
            while moved < abs(delta):
                self._events([{"type": "rel",
                               "data": {"axis": axis, "value": sign}}])
                time.sleep(pace)
                moved += step

    def button(self, down: bool) -> None:
        self._events([{"type": "btn",
                       "data": {"button": "left", "down": down}}])

    def click(self, hold: float = 0.12) -> None:
        self.button(True)
        time.sleep(hold)
        self.button(False)


# --- positioning while the wire is BUSY --------------------------------------
#
# The armed window is exactly the time the responder spends inside the verb,
# and it does not service the socket while it is there — so cursor feedback,
# which is how everything else positions the pointer, is unavailable for the
# one click that matters.
#
# Worse, the verb MOVES THE CURSOR: arming writes MouseTemp, RawMouseLocation
# and MouseLocation before posting its own click, so wherever the trial parked
# the pointer beforehand, arming warps it to the decoy. A click sent afterwards
# without correcting for that lands on the decoy's window content and measures
# nothing — which is exactly what the first run of this probe did upstream:
# 0 hijacks, 0 chain-throughs, an unmoved bar, and a very confident-looking
# table.
#
# So positioning here is open-loop, and made honest three ways:
#
#   1. PIN to a screen corner first. A huge relative move saturates against the
#      screen edge, so the cursor is at a known absolute point no matter what
#      acceleration did to the deltas.
#   2. Keep the remaining move SHORT. Acceleration makes a relative move land
#      at a repeatable FRACTION of what was asked (~0.62 upstream, +/-2.5%), so
#      the error is proportional to the distance: the trial arranges its target
#      within a few tens of pixels of the corner it pins to.
#   3. VERIFY where it landed once the wire is free again. A trial whose click
#      did not land on its target is NOT A TRIAL and is dropped rather than
#      scored. That rule lives in tally.py and is tested.


def pin(qmp: Qmp, corner: str = "bottom-right") -> tuple:
    """Saturate the cursor against a screen corner and return where it is."""
    sx = 2000 if "right" in corner else -2000
    sy = 2000 if "bottom" in corner else -2000
    qmp.rel(sx, 0, step=8, pace=0.001)
    qmp.rel(0, sy, step=8, pace=0.001)
    return ((SCREEN_W - 1) if sx > 0 else 0, (SCREEN_H - 1) if sy > 0 else 0)


def position(read_mouse, qmp: Qmp, tx: int, ty: int,
             tolerance: int = 2, tries: int = 25) -> tuple:
    """Closed-loop the cursor onto (tx,ty). Usable only while the wire is
    free — setup, never inside an armed window.

    `read_mouse` is a zero-argument callable returning (x, y) from the GUEST.
    Passed in rather than called directly because NOW has no `mouseloc` and the
    spelling is not decided; see the module docstring.
    """
    x, y = read_mouse()
    for _ in range(tries):
        dx, dy = tx - x, ty - y
        if abs(dx) <= tolerance and abs(dy) <= tolerance:
            break
        qmp.rel(dx, dy)
        time.sleep(0.15)
        x, y = read_mouse()
    return x, y


def learn_hop(read_mouse, qmp: Qmp, corner: str, target: tuple,
              tries: int = 12) -> tuple:
    """Learn the exact relative request that carries the cursor from a pinned
    corner to `target`, with feedback, BEFORE any request is armed.

    A gain constant does not survive here: the guest's acceleration makes the
    landing a non-linear function of the request, and it differs per axis and
    per distance (upstream: a 300px calibration mis-sent a 21px hop by 5px; a
    30px vertical calibration measured a gain of 0.17). What IS stable is the
    hop itself — the same corner to the same target, learned by closed loop
    while the wire is still free, then replayed verbatim inside the armed
    window where no feedback exists.
    """
    rx = ry = 0
    best = None
    for _ in range(tries):
        pin(qmp, corner)
        if rx:
            qmp.rel(rx, 0, step=3, pace=0.003)
        if ry:
            qmp.rel(0, ry, step=3, pace=0.003)
        x, y = read_mouse()
        ex, ey = target[0] - x, target[1] - y
        if best is None or abs(ex) + abs(ey) < best[0]:
            best = (abs(ex) + abs(ey), rx, ry)
        if abs(ex) <= 2 and abs(ey) <= 2:
            return rx, ry
        # The guest moves LESS than asked over these distances, so correct by
        # the error inflated a little; the loop converges in a few passes.
        rx += int(round(ex * 1.4)) or (1 if ex > 0 else -1 if ex else 0)
        ry += int(round(ey * 1.4)) or (1 if ey > 0 else -1 if ey else 0)
    if best is None or best[0] > 8:
        raise SystemExit(f"could not learn a hop to {target}: best error "
                         f"{best[0] if best else 'n/a'}px")
    return best[1], best[2]


def replay_hop(qmp: Qmp, corner: str, hop: tuple) -> None:
    """Pin, then replay a learned hop. No feedback is possible here — this is
    the move that happens while a request is armed and the wire is busy."""
    pin(qmp, corner)
    if hop[0]:
        qmp.rel(hop[0], 0, step=3, pace=0.003)
    if hop[1]:
        qmp.rel(0, hop[1], step=3, pace=0.003)


def learn_drag(read_mouse, qmp: Qmp, hop: tuple, corner: str, item_y: int,
               tries: int = 8) -> int:
    """Learn the downward request that carries the cursor from a menu title
    onto item 1's row, with feedback and the button UP, before any trial runs.
    Replayed verbatim during the real press, where nothing can be measured."""
    r = 20
    best = None
    for _ in range(tries):
        replay_hop(qmp, corner, hop)
        qmp.rel(0, r, step=3, pace=0.004)
        _, y = read_mouse()
        err = item_y - y
        if best is None or abs(err) < best[0]:
            best = (abs(err), r)
        if abs(err) <= 2:
            return r
        r += int(round(err * 1.4)) or (1 if err > 0 else -1)
    if best is None or best[0] > 4:
        raise SystemExit(f"could not learn a drag onto item 1 (best error "
                         f"{best[0] if best else 'n/a'}px)")
    return best[1]
