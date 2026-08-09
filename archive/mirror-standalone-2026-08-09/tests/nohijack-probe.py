#!/usr/bin/env python3
"""Portal acceptance 3 — NO HIJACK. Does an armed request fire on someone
else's click?

The Portal's trap patches are system-wide: every application's `MenuSelect`
and `TrackControl` go through them. The guard is supposed to make that
invisible — act only for an armed request in the matching A5 world, chain
through otherwise — and forty trials of ordinary work produced no stray
actuation. But nobody had ever armed a request and then deliberately clicked
something ELSE. This does exactly that.

Why it gates the rest of the Portal: each new op patches another trap, so a
leaky guard MULTIPLIES rather than repeats.

## The shape of a trial

`ctlinvoke` and `menuinvoke` are atomic — they arm the patch in the target's
context, post their own click, and wait (300 ticks = ~5 s) for the patch to
fire. There is no "arm only" verb, so the armed window is manufactured
honestly: the request is armed against a DECOY that its own posted click
cannot make the app track, so the arm stays live for the full wait, and the
real click is injected during it.

  * control decoy — a control whose rect the app will not track (a hidden or
    rangeless one). The verb's own click lands on nothing trackable.
  * menu decoy — `titleLeft` far off-screen, so the posted click is not in
    the menu bar and the app never calls `MenuSelect` for it.

The stimulus is a REAL mouse press over QMP: the emulated machine's own
hardware input, arriving from outside the guest CPU, indistinguishable to the
application from a human's hand. That is what "a real user click" has to mean
here. QMP is the test's stimulus, never the Portal's mechanism — the ops under
test have no QMP in their path.

## Oracles — guest state, never the verb's own report

| Case | armed | real click | hijack shows as | chain-through shows as |
|---|---|---|---|---|
| control | scroll `inPageDown` (23) on a decoy | the LIVE bar's up arrow | the live bar jumps a PAGE (armed part) | it moves one LINE up (its own part) |
| menu | Finder File/New Folder | the Apple menu → About This Computer | an `untitled folder` on the Desktop | the About window opens |
| stale | either, then no click at all | the same click, ten seconds later | same as above | same as above |

The control case is discriminating BY DIRECTION, which is the same trick that
ruled out "the click did it" for `CONTROL_INVOKE` itself: a hijack and an
honest chain-through move the same control in opposite directions by different
amounts, so no single reading can be read both ways. The menu case's hijack
oracle is a folder on disk — the strongest oracle this project has.

`answered:true` is never evidence here. It is recorded, because a reply that
disagrees with the guest is itself a finding, but the verdict is the guest's.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/nohijack-probe.py --agent-port 1724 --anchor-port 1704 \
        --qmp run/qmp.sock --case control --n 20
    python3 tests/nohijack-probe.py ... --case menu --n 20
    python3 tests/nohijack-probe.py ... --case stale --n 20
    python3 tests/nohijack-probe.py ... --case window     # disarm-window sweep
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from trials import Agent, GuestError  # noqa: E402

MIRROR = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.path.abspath(os.path.join(MIRROR, ".."))
# Lab INSTRUMENT (AGENTS.md): the anchor client reads the guest filesystem,
# which is the menu case's actuation oracle. Nothing under host/ or guest/
# imports it.
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402

# Control Manager part codes — Inside Macintosh, the Control Manager;
# ControlDefinitions.h. Not invented: the phantom 10/11/12/13 in a doc comment
# is what made CONTROL_INVOKE look broken for a day.
IN_UP_BUTTON = 20               # one line up
IN_DOWN_BUTTON = 21             # one line down
IN_PAGE_UP = 22                 # one page up — the armed decoy's part
IN_PAGE_DOWN = 23               # one page down

# A menu-bar x that is NOT in the menu bar. The screen is 1024 wide at most
# here; 4000 is off any plausible screen, so the app's FindWindow does not
# report inMenuBar and it never calls MenuSelect for our own posted click.
# That is what keeps the request armed for the full wait.
OFFSCREEN_TITLE_LEFT = 4000

# Where the drag must END for the release to select item 1 (About This
# Computer): the menu bar is 20px tall and `menugeom` reports item 1 as 16px,
# so its row is y 21..36 and its middle is 28. Measured rather than guessed —
# releases at y 33..35 selected nothing, and a drag that reached y 37 landed on
# item 3 and launched AirPort. The REQUEST that gets there is learned per run
# (see learn_drag), because the guest moves less than it is asked and by an
# amount that is not linear in the distance.
MENU_ITEM1_Y = 28


# --- a real mouse, from outside the guest ------------------------------------

class Qmp:
    """Minimal QMP input driver — the same two primitives MirrorKit's
    QmpClient uses (`rel` and `btn`). The mac99 mouse is RELATIVE-only and OS 9
    applies acceleration, so absolute positioning has to be closed-loop against
    the guest's own `mouseloc`; an open-loop move lands somewhere else and the
    trial silently clicks the wrong thing."""

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


def mouseloc(agent: Agent) -> tuple:
    r = agent.call("mouseloc")
    return int(r["x"]), int(r["y"])


# --- positioning while the wire is BUSY --------------------------------------
#
# The armed window is exactly the time the agent spends inside the verb, and it
# does not service the socket while it is there — so `mouseloc` feedback, which
# is how everything else on this project positions the cursor, is unavailable
# for the one click that matters.
#
# Worse, the verb MOVES THE CURSOR: `post_click_at` writes `MouseTemp`,
# `RawMouseLocation` and `MouseLocation` before posting its click, so wherever
# the trial parked the pointer beforehand, arming warps it to the decoy. A
# click sent afterwards without correcting for that lands on the decoy's
# window content and measures nothing — which is exactly what the first run of
# this probe did: 0 hijacks, 0 chain-throughs, an unmoved bar, and a very
# confident-looking table.
#
# So positioning here is open-loop, and made honest three ways:
#
#   1. PIN to a screen corner first. A huge relative move saturates against the
#      screen edge, so the cursor is at a known absolute point no matter what
#      acceleration did to the deltas — measured exact, (0,0) and (799,599).
#   2. Keep the remaining move SHORT. Acceleration makes a relative move land
#      at a repeatable FRACTION of what was asked (~0.62 here, ±2.5%), so the
#      error is proportional to the distance: the trial arranges its target
#      within a few tens of pixels of the corner it pins to.
#   3. VERIFY where it landed once the wire is free again. A trial whose click
#      did not land on its target is not a failure to hijack — it is not a
#      trial, and it is dropped rather than scored.

SCREEN_W, SCREEN_H = 800, 600           # measured by pinning, not assumed

# How many `untitled folder*` names the Desktop oracle looks for. `trials.py`
# scans 59 of them because its case lets them accumulate; here every trial
# clears them first, so at most a couple can exist — and each name is a wire
# round trip, which at 59 names made a trial take minutes.
DESKTOP_FOLDER_SCAN = 6


def desktop_untitled_folders(h: Harness) -> set:
    """Finder new-folder names on the Desktop — the menu case's hijack oracle,
    and a fact on disk rather than anything the verb said."""
    found = set()
    for suffix in [""] + [f" {i}" for i in range(2, DESKTOP_FOLDER_SCAN + 1)]:
        path = f"Macintosh HD:Desktop Folder:untitled folder{suffix}"
        if h.request("stat", {"path": path}).get("exists"):
            found.add(suffix or "1")
    return found


def clear_desktop_untitled_folders(h: Harness) -> int:
    """Independent trials: what one trial created must not be there for the
    next one to see."""
    removed = 0
    for name in desktop_untitled_folders(h):
        suffix = "" if name == "1" else f" {name}"
        try:
            h.request("delete", {"path": "Macintosh HD:Desktop Folder:"
                                         f"untitled folder{suffix}"})
            removed += 1
        except Exception:
            pass
    return removed


def pin(qmp: Qmp, corner: str = "bottom-right") -> tuple:
    """Saturate the cursor against a screen corner and return where it is."""
    sx = 2000 if "right" in corner else -2000
    sy = 2000 if "bottom" in corner else -2000
    qmp.rel(sx, 0, step=8, pace=0.001)
    qmp.rel(0, sy, step=8, pace=0.001)
    return ((SCREEN_W - 1) if sx > 0 else 0, (SCREEN_H - 1) if sy > 0 else 0)


def position(agent: Agent, qmp: Qmp, tx: int, ty: int,
             tolerance: int = 2, tries: int = 25) -> tuple:
    """Closed-loop the cursor onto (tx,ty) using `mouseloc` feedback. Usable
    only while the wire is free — setup, never inside an armed window."""
    x, y = mouseloc(agent)
    for _ in range(tries):
        dx, dy = tx - x, ty - y
        if abs(dx) <= tolerance and abs(dy) <= tolerance:
            break
        qmp.rel(dx, dy)
        time.sleep(0.15)
        x, y = mouseloc(agent)
    return x, y


def learn_hop(agent: Agent, qmp: Qmp, corner: str, target: tuple,
              tries: int = 12) -> tuple:
    """Learn the exact relative request that carries the cursor from a pinned
    corner to `target`, with feedback, BEFORE any request is armed.

    A gain constant does not survive here: the guest's acceleration makes the
    landing a non-linear function of the request, and it differs per axis and
    per distance (a 300px calibration mis-sent a 21px hop by 5px; a 30px
    vertical calibration measured a gain of 0.17). What IS stable is the hop
    itself — the same corner to the same target, learned by closed loop while
    the wire is still free, then replayed verbatim inside the armed window
    where no feedback exists."""
    rx = ry = 0
    best = None
    for _ in range(tries):
        here = pin(qmp, corner)
        if rx:
            qmp.rel(rx, 0, step=3, pace=0.003)
        if ry:
            qmp.rel(0, ry, step=3, pace=0.003)
        x, y = mouseloc(agent)
        ex, ey = target[0] - x, target[1] - y
        if best is None or abs(ex) + abs(ey) < best[0]:
            best = (abs(ex) + abs(ey), rx, ry)
        if abs(ex) <= 2 and abs(ey) <= 2:
            return rx, ry
        # The guest moves LESS than asked over these distances, so correct by
        # the error inflated a little; the loop converges in a few passes.
        rx += int(round(ex * 1.4)) or (1 if ex > 0 else -1 if ex else 0)
        ry += int(round(ey * 1.4)) or (1 if ey > 0 else -1 if ey else 0)
        _ = here
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


# --- guest-state readers -----------------------------------------------------

def front_app(agent: Agent):
    procs = agent.call("observe").get("processes", [])
    return next((p.get("name") for p in procs if p.get("front")), None)


def windows(agent: Agent) -> list:
    return agent.call("axtree", {"scope": "front"}).get("windows") or []


def window_titles(agent: Agent) -> list:
    return [w.get("title") for w in windows(agent)]


def controls(agent: Agent) -> list:
    return [c for w in windows(agent) for c in (w.get("controls") or [])]


def control_by_ref(agent: Agent, ref: str):
    return next((c for c in controls(agent) if c.get("ref") == ref), None)


def decoy_control(agent: Agent, live: dict):
    """A control to arm AGAINST whose own posted click the app will not track.

    `ctlinvoke` posts a click at the armed control's centre, so an ordinary
    control fires its own request in milliseconds and there is no armed window
    to test at all. A HIDDEN control is the honest decoy: `FindControl`
    declines it, so the app never calls `TrackControl` for it, the request
    stays armed for the verb's whole ~5 s wait, and the click lands in the
    window's content where it does nothing.

    Rejected alternatives, so the choice is not mistaken for convenience: a
    disabled control (the Finder's windows expose none), and a second window's
    control (its click ACTIVATES that window, which moves the thing the real
    click is aimed at)."""
    for c in controls(agent):
        if c.get("ref") == live.get("ref"):
            continue
        if not c.get("visible"):
            return c
    return None


def bring_finder_front(agent: Agent) -> None:
    if front_app(agent) == "Finder":
        return
    agent.call("click", {"x": 500, "y": 380})       # empty desktop
    for _ in range(10):
        time.sleep(1)
        if front_app(agent) == "Finder":
            return


def close_finder_windows(agent: Agent) -> None:
    """The menu cases need NO Finder window open: `New Folder` creates its
    folder inside the front window, and the oracle watches the Desktop. With a
    window open the folder lands somewhere the oracle cannot see it, and a real
    hijack would be scored clean."""
    bring_finder_front(agent)
    for _ in range(6):
        if not [w for w in windows(agent) if w.get("title") != "Desktop"]:
            return
        agent.call("key", {"code": 13, "char": 119, "mods": 256})    # cmd+W
        time.sleep(1.2)


def finder_menu(agent: Agent, title: str):
    tree = agent.call("axtree", {"scope": "front"})
    for m in tree.get("menus") or []:
        if (m.get("title") or "").strip("\x00\x14 ") == title:
            return m
    return None


def apple_menu(agent: Agent):
    """The Apple menu is the one whose title is the apple glyph (0x14), and
    whose first item is About This Computer. Matched by POSITION (it is always
    first, leftmost) rather than by title, because its item titles carry
    leading NULs — a known guest defect that another lane owns."""
    tree = agent.call("axtree", {"scope": "front"})
    menus = tree.get("menus") or []
    return menus[0] if menus else None


# --- case: control cross-fire ------------------------------------------------

def finder_window(agent: Agent, title: str = "Macintosh HD"):
    return next((w for w in windows(agent) if w.get("title") == title), None)


def place_window_bottom_right(agent: Agent, qmp: Qmp,
                              title: str = "Macintosh HD") -> dict:
    """Drag the window into the bottom-right corner so its scroll bar's down
    arrow sits a few tens of pixels from the corner the trial pins to. This is
    what keeps the open-loop click accurate — see the positioning note above."""
    for _ in range(5):
        w = finder_window(agent, title)
        if w is None:
            raise SystemExit(f"window {title!r} is gone")
        left, top, right, bottom = w["rect"]
        dx, dy = (SCREEN_W - 5) - right, (SCREEN_H - 4) - bottom
        if abs(dx) < 8 and abs(dy) < 8:
            return w
        position(agent, qmp, (left + right) // 2, top - 8)     # the title bar
        qmp.button(True)
        time.sleep(0.3)
        qmp.rel(int(dx / 0.62), 0, step=3, pace=0.003)
        qmp.rel(0, int(dy / 0.62), step=3, pace=0.003)
        time.sleep(0.3)
        qmp.button(False)
        time.sleep(1.5)
    raise SystemExit("could not place the window in the corner")


def setup_finder_window(agent: Agent) -> dict:
    """The Finder, frontmost, with the `Macintosh HD` window open — one window
    carrying BOTH the live scroll bar the real click drives and the hidden
    control the request is armed against, so the trial tests the guard that
    matters most: same process, same A5 world, different control."""
    bring_finder_front(agent)
    if front_app(agent) != "Finder":
        raise SystemExit("PRECONDITION FAILED: the Finder is not frontmost")
    # Anything already open — an About window a previous case left up — takes
    # the keystrokes below and the window never opens. Start from the desktop.
    close_finder_windows(agent)
    if finder_window(agent) is None:
        agent.call("key", {"code": 46, "char": 109, "mods": 0})      # 'm'
        time.sleep(1.0)
        agent.call("key", {"code": 31, "char": 111, "mods": 256})    # cmd+O
        for _ in range(10):
            time.sleep(1.5)
            if finder_window(agent) is not None:
                break
    w = finder_window(agent)
    if w is None:
        raise SystemExit("PRECONDITION FAILED: the Macintosh HD window would "
                         "not open")
    return w


def window_bar(agent: Agent, title: str = "Macintosh HD"):
    w = finder_window(agent, title)
    if w is None:
        return None
    live = [c for c in (w.get("controls") or [])
            if c.get("visible") and c.get("enabled")
            and (c.get("max") or 0) > (c.get("min") or 0)]
    return live[0] if live else None


def reset_bar_to_middle(agent: Agent, ref: str) -> int:
    """Put the bar strictly between its ends, so BOTH verdicts have room.

    At an end one of the two outcomes is a legitimate no-op, and a no-op is
    indistinguishable from a click that missed — the trap `ctlinvoke-probe`
    was written to avoid. Driven with `ctlinvoke` itself, which is measured
    good at 20/20 and whose own click fires it immediately."""
    bar = control_by_ref(agent, ref)
    agent.call("ctlinvoke", {"ref": ref, "part": IN_PAGE_UP})   # to the top
    time.sleep(1.2)
    for _ in range(2):                                          # two lines down
        agent.call("ctlinvoke", {"ref": ref, "part": IN_DOWN_BUTTON})
        time.sleep(1.0)
    bar = control_by_ref(agent, ref)
    v, lo, hi = bar.get("value"), bar.get("min"), bar.get("max")
    if not (lo < v < hi):
        raise SystemExit(f"PRECONDITION FAILED: bar sits at {v} in {lo}..{hi}; "
                         f"a trial started at an end cannot tell a no-op from "
                         f"a missed click")
    return v


def case_control(agent: Agent, h: Harness, qmp: Qmp, n: int,
                 arm_delay: float) -> dict:
    """Arm against control A, click control B for real. B must do B's thing and
    A must not move.

    Both controls live in the SAME window of the SAME process, so the only
    thing standing between the armed request and the user's click is the
    patch's `controlHandle` test — the A5 test cannot help here.

    The discriminator is DIRECTION. The armed part is `inPageUp`, the real
    click is on the down arrow, and the two move the bar opposite ways:

        chain-through  value INCREASES (the bar did what the click asked)
        hijack         value DECREASES (the bar did what the REQUEST asked)

    which no single reading can be read both ways."""
    setup_finder_window(agent)
    place_window_bottom_right(agent, qmp)
    bar0 = window_bar(agent)
    target0 = ((bar0["rect"][0] + bar0["rect"][2]) // 2, bar0["rect"][3] - 8)
    hop = learn_hop(agent, qmp, "bottom-right", target0)
    print(f"    down arrow at {target0}, learned hop {hop}")

    trials = []
    print(f"\n=== control cross-fire (same process, different control), N={n}")
    for i in range(n):
        bar = window_bar(agent)
        if bar is None:
            raise SystemExit("PRECONDITION FAILED: no control with a live range")
        decoy = decoy_control(agent, bar)
        if decoy is None:
            raise SystemExit(
                "PRECONDITION FAILED: no hidden control to arm against — "
                "without one the request fires on its own click and there is "
                "no armed window to test.")

        target = ((bar["rect"][0] + bar["rect"][2]) // 2, bar["rect"][3] - 8)
        if target != target0:
            # The window moved: the learned hop no longer aims anywhere known.
            place_window_bottom_right(agent, qmp)
            bar = window_bar(agent)
            target0 = ((bar["rect"][0] + bar["rect"][2]) // 2,
                       bar["rect"][3] - 8)
            hop = learn_hop(agent, qmp, "bottom-right", target0)
            target = target0
        b_before = reset_bar_to_middle(agent, bar["ref"])
        a_before = (control_by_ref(agent, decoy["ref"]) or {}).get("value")

        agent.send_async("ctlinvoke", {"ref": decoy["ref"],
                                       "part": IN_PAGE_UP})
        time.sleep(arm_delay)                    # let the arm and its warp land
        replay_hop(qmp, "bottom-right", hop)     # undo the verb's cursor warp
        qmp.click()                              # the real user's click
        t0 = time.time()
        reply = agent.read_reply(timeout=40)
        elapsed = time.time() - t0
        time.sleep(1.5)

        landed = mouseloc(agent)
        b_after = (control_by_ref(agent, bar["ref"]) or {}).get("value")
        a_after = (control_by_ref(agent, decoy["ref"]) or {}).get("value")

        went_down = (b_before is not None and b_after is not None
                     and b_after > b_before)      # the click's own direction
        # The armed part is inPageUp, and a page here is the WHOLE range, so a
        # hijack lands the bar on its minimum. Any smaller decrease is not the
        # armed request — one trial moved exactly one line up with the patch
        # reporting it never fired, and scoring "went up" as a hijack would
        # have published that as a leak.
        paged_up = (b_after is not None and bar.get("min") is not None
                    and b_after <= bar["min"])
        hijacked = bool(reply.get("ok")) or bool(paged_up)
        # A click that missed is not a trial. Scoring it would report a clean
        # no-hijack that never tested anything. The bar's own rect is the
        # bound: a ±6px box around the aim point rejected clicks that plainly
        # landed on the arrow and worked.
        rect = bar["rect"]
        valid = (rect[0] - 4 <= landed[0] <= rect[2] + 4
                 and rect[1] <= landed[1] <= rect[3] + 4)
        trials.append({
            "trial": i + 1, "decoy": decoy["ref"], "bar": bar["ref"],
            "barBefore": b_before, "barAfter": b_after,
            "decoyBefore": a_before, "decoyAfter": a_after,
            "replyOk": bool(reply.get("ok")),
            "error": (reply.get("error") or {}).get("code"),
            "elapsed": round(elapsed, 2), "target": list(target),
            "landed": list(landed), "valid": valid,
            "hijacked": hijacked, "chained": bool(went_down),
            "pagedUp": bool(paged_up), "decoyMoved": a_before != a_after,
        })
        sys.stdout.write("!" if not valid else
                         ("H" if hijacked else ("." if went_down else "?")))
        sys.stdout.flush()
    print()
    return summarize("control", trials)


# --- case: menu cross-fire ---------------------------------------------------

def menu_trial(agent: Agent, h: Harness, qmp: Qmp, click_delay: float,
               wait_for_reply_first: bool, hop: tuple, drag: int) -> dict:
    """One armed Finder File/New Folder, one real Apple-menu selection.

    `wait_for_reply_first` is the stale case: read the verb's reply (it times
    out `not_taken` and disarms) BEFORE clicking, so the click lands after the
    Portal should already be disarmed."""
    bring_finder_front(agent)
    if front_app(agent) != "Finder":
        raise SystemExit("PRECONDITION FAILED: the Finder is not frontmost")
    clear_desktop_untitled_folders(h)
    close_about(agent)
    folders_before = desktop_untitled_folders(h)

    file_menu = finder_menu(agent, "File")
    apple = apple_menu(agent)
    if file_menu is None or apple is None:
        raise SystemExit("PRECONDITION FAILED: the Finder's menus are not "
                         "visible in the scene")

    # The Apple menu's title, near the top-left corner — which is why the trial
    # pins THERE: the replayed hop is a dozen pixels long.
    target = apple_title_point(agent)

    agent.send_async("menuinvoke", {"menuID": int(file_menu["id"]), "item": 1,
                                    "titleLeft": OFFSCREEN_TITLE_LEFT})
    reply = None
    if wait_for_reply_first:
        reply = agent.read_reply(timeout=40)
        time.sleep(click_delay)
    else:
        time.sleep(click_delay)

    replay_hop(qmp, "top-left", hop)        # undo the verb's cursor warp

    # A real menu selection: press on the title, let the menu drop, drag down
    # onto item 1 (About This Computer), release. If the Portal hijacks, the
    # app's MenuSelect returns our armed item the instant the button goes down
    # and no menu is ever drawn — the drag then falls on the desktop, harmless.
    #
    # When the wire is free (the stale case, whose reply has already been read)
    # the press also carries the tracking probe, which says whether the app ran
    # its own menu loop. While a request is in flight it cannot: the agent is
    # inside the verb and would not answer either way.
    pending = False
    if wait_for_reply_first:
        starved, pending = press_with_tracking_probe(agent, qmp)
    else:
        starved = None
        qmp.button(True)
        time.sleep(0.8)
    qmp.rel(0, drag, step=3, pace=0.004)
    time.sleep(0.6)
    qmp.button(False)
    time.sleep(2.5)

    if reply is None:
        reply = agent.read_reply(timeout=40)
    if pending:
        agent.read_reply(timeout=30)
    time.sleep(2.0)

    # Where the press actually landed. The drag adds ~10px in y, so the check
    # is that the press was on the Apple menu's TITLE (which spans ~28px) and
    # still in the menu bar's row of the screen.
    landed = mouseloc(agent)
    valid = abs(landed[0] - target[0]) <= 12 and landed[1] <= 40

    folders_after = desktop_untitled_folders(h)
    new_folder = bool(folders_after - folders_before)
    about = about_window(agent)
    return {
        "newFolder": new_folder,          # the ARMED command fired: a hijack
        "aboutOpened": about,             # the user's own selection worked
        "replyOk": bool(reply.get("ok")),
        "error": (reply.get("error") or {}).get("code"),
        "hijacked": new_folder or bool(reply.get("ok")),
        "tracked": starved,       # recorded, not scored: menu tracking does
                                  # NOT reliably starve the agent (measured)
        "chained": about,
        "selected": about,
        "target": list(target), "landed": list(landed), "valid": valid,
    }


def learn_drag(agent: Agent, qmp: Qmp, hop: tuple, item_y: int,
               tries: int = 8) -> int:
    """Learn the downward request that carries the cursor from the menu title
    onto item 1's row, with feedback and the button UP, before any trial runs.
    Replayed verbatim during the real press, where nothing can be measured."""
    r = 20
    best = None
    for _ in range(tries):
        replay_hop(qmp, "top-left", hop)
        qmp.rel(0, r, step=3, pace=0.004)
        _, y = mouseloc(agent)
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


def press_with_tracking_probe(agent: Agent, qmp: Qmp, hold: float = 1.2):
    """Press the mouse and find out whether the front app entered a MENU
    TRACKING LOOP — usable only when the wire is free.

    This is a much stronger "the menu behaved normally" oracle than whether an
    item ended up selected, which depends on landing a drag inside a 16px row
    and was only ~60% reliable here. Cooperative multitasking gives it for
    free: `MenuSelect`'s tracking loop does not yield, so while a menu is down
    the agent gets no time and cannot answer. A request that goes unanswered
    for as long as the button is held is the app tracking a menu; a prompt
    answer means `MenuSelect` returned immediately and no menu was ever drawn —
    which is exactly what the Portal's patch does.

    Returns (starved, pending) — `pending` says a reply still has to be drained
    once the button is released."""
    agent.send_async("ping")
    qmp.button(True)
    try:
        agent.read_reply(timeout=hold)
        return False, False
    except (socket.timeout, TimeoutError, OSError):
        return True, True


def apple_title_point(agent: Agent) -> tuple:
    """A point ON the Apple menu's title.

    Aimed near its LEFT edge, not at the midpoint to the next menu's `left`:
    the gap between two titles is padding, not title, and a press that lands
    there opens no menu at all. Measured, not assumed — with the Apple title at
    x=10 and File at x=38, presses at x=27..30 selected nothing while presses
    at x=18 worked every time.""" 
    tree = agent.call("axtree", {"scope": "front"})
    menus = tree.get("menus") or []
    if not menus:
        raise SystemExit("PRECONDITION FAILED: no menus in the bar")
    return (int(menus[0]["left"]) + 8, 9)


def menu_setup(agent: Agent, qmp: Qmp) -> tuple:
    """Everything that needs feedback, done while the wire is still free."""
    close_finder_windows(agent)
    hop = learn_hop(agent, qmp, "top-left", apple_title_point(agent))
    drag = learn_drag(agent, qmp, hop, MENU_ITEM1_Y)
    return hop, drag


def about_window(agent: Agent) -> bool:
    return any("About This Computer" in (t or "") for t in window_titles(agent))


def close_about(agent: Agent) -> None:
    for _ in range(3):
        if not about_window(agent):
            return
        agent.call("key", {"code": 13, "char": 119, "mods": 256})   # cmd+W
        time.sleep(1.2)


def baseline_trial(agent: Agent, h: Harness, qmp: Qmp, hop: tuple,
                   drag: int) -> dict:
    """The same real Apple-menu selection with NOTHING armed.

    Without this the menu case cannot tell "the armed request stole the click"
    from "my drag never selected anything", and the whole finding would rest on
    an unfalsified assumption about my own stimulus."""
    bring_finder_front(agent)
    clear_desktop_untitled_folders(h)
    close_about(agent)
    before = desktop_untitled_folders(h)
    replay_hop(qmp, "top-left", hop)
    starved, pending = press_with_tracking_probe(agent, qmp)
    qmp.rel(0, drag, step=3, pace=0.004)
    time.sleep(0.6)
    qmp.button(False)
    time.sleep(2.0)
    if pending:
        agent.read_reply(timeout=30)
    time.sleep(1.0)
    landed = mouseloc(agent)
    target = apple_title_point(agent)
    return {
        "newFolder": bool(desktop_untitled_folders(h) - before),
        "aboutOpened": about_window(agent),
        "replyOk": False, "error": None,
        "hijacked": bool(desktop_untitled_folders(h) - before),
        "tracked": starved,       # recorded, not scored (see menu_trial)
        "chained": about_window(agent),
        "selected": about_window(agent),
        "target": list(target), "landed": list(landed),
        "valid": abs(landed[0] - target[0]) <= 12 and landed[1] <= 40,
    }


def case_baseline(agent: Agent, h: Harness, qmp: Qmp, n: int) -> dict:
    hop, drag = menu_setup(agent, qmp)
    print(f"\n=== baseline: the same real click, nothing armed, N={n}")
    trials = []
    for i in range(n):
        t = baseline_trial(agent, h, qmp, hop, drag)
        t["trial"] = i + 1
        trials.append(t)
        sys.stdout.write("." if t["chained"] else ("H" if t["hijacked"] else "?"))
        sys.stdout.flush()
    print()
    return summarize("baseline", trials)


def simpletext_psn(agent: Agent):
    for p in agent.call("observe").get("processes", []):
        if p.get("name") == "SimpleText":
            return p
    return None


def simpletext_app(agent: Agent):
    tree = agent.call("axtree", {"scope": "all"})
    for app in tree.get("apps") or []:
        if (app.get("process") or {}).get("name") == "SimpleText":
            return app
    return None


def simpletext_window_count(agent: Agent) -> int:
    app = simpletext_app(agent)
    return -1 if app is None else len(app.get("windows") or [])


def simpletext_file_menu(agent: Agent) -> int:
    """SimpleText's File menu id, read from its own menu list rather than
    written down — a menu id is exactly the kind of number that is right until
    the day it is not."""
    app = simpletext_app(agent)
    for m in ((app or {}).get("menus") or []):
        if (m.get("title") or "").strip("\x00 ") == "File":
            return int(m["id"])
    raise SystemExit("PRECONDITION FAILED: SimpleText exposes no File menu")


def cross_trial(agent: Agent, h: Harness, qmp: Qmp, hop: tuple,
                drag: int, delay: float) -> dict:
    """The A5 guard: arm a request against a BACKGROUND application, then click
    a menu in the FRONT one.

    This is the blast-radius question the same-process cases cannot ask. The
    armed command is SimpleText's File → New, whose effect is a new SimpleText
    window; the real click is the Finder's Apple menu. A leak here would mean
    driving one application can fire commands in another."""
    st = simpletext_psn(agent)
    if st is None:
        raise SystemExit("PRECONDITION FAILED: SimpleText is not running")
    bring_finder_front(agent)
    close_about(agent)
    windows_before = simpletext_window_count(agent)
    file_menu = simpletext_file_menu(agent)
    folders_before = desktop_untitled_folders(h)

    agent.send_async("menuinvoke", {"menuID": file_menu, "item": 1,
                                    "titleLeft": OFFSCREEN_TITLE_LEFT,
                                    "serialHi": st["serialHi"],
                                    "serialLo": st["serialLo"]})
    time.sleep(delay)
    replay_hop(qmp, "top-left", hop)
    qmp.button(True)
    time.sleep(0.8)
    qmp.rel(0, drag, step=3, pace=0.004)
    time.sleep(0.6)
    qmp.button(False)
    time.sleep(2.5)
    reply = agent.read_reply(timeout=40)
    time.sleep(2.0)

    landed = mouseloc(agent)
    target = apple_title_point(agent)
    windows_after = simpletext_window_count(agent)
    return {
        "replyOk": bool(reply.get("ok")),
        "error": (reply.get("error") or {}).get("code"),
        "stWindowsBefore": windows_before, "stWindowsAfter": windows_after,
        "newFolder": bool(desktop_untitled_folders(h) - folders_before),
        "hijacked": bool(reply.get("ok"))
                    or (windows_after > windows_before >= 0),
        "chained": about_window(agent),
        "selected": about_window(agent),
        "target": list(target), "landed": list(landed),
        "valid": abs(landed[0] - target[0]) <= 12 and landed[1] <= 45,
    }


def case_cross(agent: Agent, h: Harness, qmp: Qmp, n: int,
               arm_delay: float) -> dict:
    hop, drag = menu_setup(agent, qmp)
    print(f"\n=== cross-process arm (SimpleText armed, Finder clicked), N={n}")
    trials = []
    for i in range(n):
        t = cross_trial(agent, h, qmp, hop, drag, arm_delay)
        t["trial"] = i + 1
        trials.append(t)
        sys.stdout.write("H" if t["hijacked"] else ("." if t["chained"] else "?"))
        sys.stdout.flush()
    print()
    return summarize("cross", trials)


def case_menu(agent: Agent, h: Harness, qmp: Qmp, n: int,
              arm_delay: float) -> dict:
    hop, drag = menu_setup(agent, qmp)
    print(f"\n=== menu cross-fire, N={n} (hop {hop}, drag {drag})")
    trials = []
    for i in range(n):
        t = menu_trial(agent, h, qmp, arm_delay, False, hop, drag)
        t["trial"] = i + 1
        trials.append(t)
        sys.stdout.write("H" if t["hijacked"] else ("." if t["chained"] else "?"))
        sys.stdout.flush()
    print()
    return summarize("menu", trials)


def case_stale(agent: Agent, h: Harness, qmp: Qmp, n: int,
               stale_delay: float) -> dict:
    """Arm, never click during the window, then click LONG after. A request
    that lurks and fires on the user's next unrelated click is the failure this
    case exists to find."""
    hop, drag = menu_setup(agent, qmp)
    print(f"\n=== stale arm (click {stale_delay:.0f}s after the reply), N={n}")
    trials = []
    for i in range(n):
        t = menu_trial(agent, h, qmp, stale_delay, True, hop, drag)
        t["trial"] = i + 1
        trials.append(t)
        sys.stdout.write("H" if t["hijacked"] else ("." if t["chained"] else "?"))
        sys.stdout.flush()
    print()
    return summarize("stale", trials)


def case_window(agent: Agent, h: Harness, qmp: Qmp, delays: list) -> dict:
    """Measure the DISARM WINDOW rather than assume it: click at increasing
    delays after arming and find where hijacking stops."""
    hop, drag = menu_setup(agent, qmp)
    print(f"\n=== disarm window sweep, delays={delays}")
    trials = []
    for d in delays:
        t = menu_trial(agent, h, qmp, d, False, hop, drag)
        t["delay"] = d
        trials.append(t)
        print(f"    +{d:4.1f}s  hijacked={t['hijacked']!s:5} "
              f"about={t['aboutOpened']!s:5} reply={t['error'] or 'ok'}")
    return {"case": "window", "trials": trials}


# --- reporting ---------------------------------------------------------------

# --- lane P2 (2026-07-31): the text ops -------------------------------------

TEXT_SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"
TEXT_ITEM_DISABLE, TEXT_EDIT_TEXT, TEXT_STAT_TEXT = 128, 16, 8
TEXT_KEYCODES = {"A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5,
                 "H": 4, "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45,
                 "O": 31, "P": 35, "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32,
                 "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6}


def text_dialog(agent: Agent):
    for w in windows(agent):
        if w.get("kind") == 2:
            return w
    return None


def text_open_find(agent: Agent, h: Harness):
    """SimpleText's Find dialog: one editText item (144 = editText|itemDisable)
    and one statText label (136). Two text objects in ONE window, which is what
    makes a cross-fire measurable at all."""
    if front_app(agent) != "SimpleText":
        h.request("launch", {"path": TEXT_SIMPLETEXT})
        for _ in range(15):
            time.sleep(2)
            if front_app(agent) == "SimpleText":
                break
    for _ in range(3):
        if text_dialog(agent) is None:
            agent.call("key", {"code": 3, "char": 102, "mods": 256})   # cmd-F
            time.sleep(2.5)
        w = text_dialog(agent)
        if w is not None:
            return w
    return None


def text_close_dialog(agent: Agent) -> None:
    for _ in range(3):
        if text_dialog(agent) is None:
            return
        agent.call("key", {"code": 53, "char": 27, "mods": 0})         # esc
        time.sleep(1.2)


def text_items_of(agent: Agent, w: dict) -> dict:
    """{masked type: item number} for the dialog's text items, discovered
    rather than assumed."""
    found = {}
    for item in range(1, 17):
        try:
            r = agent.call("textget", {"windowZ": w["z"], "window": w["title"],
                                       "kind": "ditem", "item": item})
        except GuestError as e:
            if "no such dialog item" in str(e):
                break
            continue
        found.setdefault(r["itemType"] & ~TEXT_ITEM_DISABLE, item)
    return found


def text_letters(i: int) -> str:
    """A per-trial value in LETTERS only — the `key` verb takes a keycode, and
    the probe only has the A-Z table."""
    return "USER" + chr(65 + i % 26) + chr(65 + (i // 26) % 26)


def text_type(agent: Agent, w: dict, item: int, s: str) -> None:
    """Clear the field, then type through the guest's own key plane.

    The clear goes through `textset`, which is the verb under test — as SETUP,
    not as the oracle. If it silently failed the leftover string would not
    match this trial's value and the trial would fail, so it cannot
    manufacture a pass."""
    try:
        agent.call("textset", {"windowZ": w["z"], "window": w["title"],
                               "kind": "ditem", "item": item, "text": ""})
    except GuestError:
        pass
    time.sleep(0.3)
    for ch in s:
        agent.call("key", {"code": TEXT_KEYCODES[ch], "char": ord(ch),
                           "mods": 0})


def text_read(agent: Agent, w: dict, item: int):
    try:
        return agent.call("textget", {"windowZ": w["z"], "window": w["title"],
                                      "kind": "ditem", "item": item})["text"]
    except GuestError as e:
        return f"<error {e}>"


def text_trial(agent: Agent, h: Harness, i: int) -> dict:
    """One cross-fire trial.

    `textget`/`textset` install no trap patch, so there is no armed window in
    which a user's own call could be answered — the hook serves the request
    directly. The hijack question therefore takes its OTHER form, which is the
    form that can lose a user's data: does a write land on an object the
    request did not name?

    Two stimuli per trial, both aimed at the object NOT named:

      1. the user's own typing, in the editText field, put there by the guest's
         key plane while a `textset` is aimed at the statText label beside it;
      2. a request naming a window that is not in the target's window list at
         all — the case that used to dereference an arbitrary integer and take
         SimpleText's dialog with it (fixed 2026-07-31; see portal.c,
         pt_handle_in_heap).
    """
    t = {"valid": False}
    w = text_open_find(agent, h)
    if w is None:
        t["why"] = "no dialog"
        return t
    items = text_items_of(agent, w)
    edit, label = items.get(TEXT_EDIT_TEXT), items.get(TEXT_STAT_TEXT)
    if edit is None or label is None:
        t["why"] = f"dialog has no edit+label pair: {items}"
        return t

    mine = text_letters(i)         # what the USER typed — must survive
    theirs = "PORTAL" + chr(65 + i % 26)   # what the request asked for,
                                           # aimed at the OTHER object
    text_type(agent, w, edit, mine)
    time.sleep(0.8)
    before_edit = text_read(agent, w, edit)

    # 1. write to the LABEL while the user's string sits in the FIELD.
    try:
        agent.call("textset", {"windowZ": w["z"], "window": w["title"],
                               "kind": "ditem", "item": label,
                               "text": theirs})
        t["namedOk"] = (text_read(agent, w, label) == theirs)
    except GuestError as e:
        t["namedOk"] = False
        t["namedError"] = str(e)

    # 2. a window the target does not own. Must refuse, and must not write.
    t["strayRefused"] = False
    try:
        agent.call("textset", {"windowZ": 40, "kind": "ditem", "item": edit,
                               "text": theirs})
    except GuestError as e:
        t["strayRefused"] = True
        t["strayError"] = str(e)

    after_edit = text_read(agent, w, edit)
    t.update(valid=True, mine=mine, theirs=theirs,
             beforeEdit=before_edit, afterEdit=after_edit)
    # A hijack is the user's field holding something the user did not type.
    t["hijacked"] = (after_edit != before_edit)
    t["chained"] = (after_edit == mine)
    text_close_dialog(agent)
    return t


def case_text(agent: Agent, h: Harness, qmp: Qmp, n: int) -> dict:
    print(f"\n== case text — a textset aimed elsewhere, N={n} ==")
    trials = []
    for i in range(n):
        t = text_trial(agent, h, i)
        trials.append(t)
        if t.get("valid"):
            print(f"  {i + 1:2}/{n}  user field {t['afterEdit']!r} "
                  f"(typed {t['mine']!r})  named-target ok={t['namedOk']}  "
                  f"stray refused={t['strayRefused']}")
        else:
            print(f"  {i + 1:2}/{n}  dropped: {t.get('why')}")
    scored = [t for t in trials if t.get("valid")]
    named = sum(1 for t in scored if t.get("namedOk"))
    stray = sum(1 for t in scored if t.get("strayRefused"))
    print(f"    the named object got the write:                 "
          f"{named}/{len(scored)}")
    print(f"    a request naming a foreign window was refused:  "
          f"{stray}/{len(scored)}")
    return summarize("text", trials)


def summarize(name: str, trials: list) -> dict:
    """Score only the trials whose click landed where the case aimed it.

    A click that missed is not evidence of a guard holding — it is evidence of
    nothing, and averaging it in would manufacture the exact false green this
    project keeps having to retract."""
    scored = [t for t in trials if t.get("valid", True)]
    n = len(scored)
    dropped = len(trials) - n
    hijacks = sum(1 for t in scored if t["hijacked"])
    chained = sum(1 for t in scored if t["chained"])
    print(f"    armed requests that fired on the wrong target: {hijacks}/{n}")
    print(f"    the real click did its own thing:               {chained}/{n}")
    if dropped:
        print(f"    dropped (the click missed its target):          {dropped}")
    return {"case": name, "n": n, "dropped": dropped, "hijacks": hijacks,
            "chained": chained, "trials": trials}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    ap.add_argument("--qmp", default=os.path.join(MIRROR, "run", "qmp.sock"))
    ap.add_argument("--case", action="append",
                    choices=("baseline", "control", "cross", "menu", "stale",
                             "window", "text"))
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--arm-delay", type=float, default=1.5,
                    help="seconds between sending the request and the real "
                         "click (must be inside the verb's ~5s wait)")
    ap.add_argument("--stale-delay", type=float, default=10.0)
    ap.add_argument("--json")
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})
    qmp = Qmp(args.qmp)

    hello = agent.call("hello")
    print(f"agent v{hello['version']} build={hello['build']} "
          f"portal={hello.get('portal')}")
    print(f"portal: {agent.call('portal')}")

    results = []
    for case in (args.case or ["baseline", "control", "menu", "stale"]):
        if case == "baseline":
            results.append(case_baseline(agent, h, qmp, min(args.n, 5)))
        elif case == "cross":
            results.append(case_cross(agent, h, qmp, args.n, args.arm_delay))
        elif case == "control":
            results.append(case_control(agent, h, qmp, args.n, args.arm_delay))
        elif case == "menu":
            results.append(case_menu(agent, h, qmp, args.n, args.arm_delay))
        elif case == "stale":
            results.append(case_stale(agent, h, qmp, args.n, args.stale_delay))
        elif case == "text":
            results.append(case_text(agent, h, qmp, args.n))
        elif case == "window":
            results.append(case_window(agent, h, qmp,
                                       [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0,
                                        8.0, 12.0]))

    print("\n--- summary ---")
    for r in results:
        if r["case"] == "window":
            continue
        print(f"{r['case']:8} hijacks {r['hijacks']}/{r['n']}   "
              f"clean chain-through {r['chained']}/{r['n']}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"agent": hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")

    # A hijack is a FINDING, not a crash: report it, and say so in the exit
    # status, because this number gates every later Portal op.
    total = sum(r.get("hijacks", 0) for r in results
                if r["case"] not in ("window", "baseline"))
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
