#!/usr/bin/env python3
"""NO HIJACK. Does an armed request fire on someone else's click?

Ported from `timbottu/mirror/tests/nohijack-probe.py` (50 KB, 1209 lines).
THIS IS THE HARNESS BEHIND 18/20 -> 0/19 — the measurement NOW's own contract
cites, in the act plane's preamble, as the reason every act verb must address
one element by a reference the responder minted:

    "upstream's request that merely disarmed after one use rode the user's
     own press 18 times in 20; the variant that had to name its exact target
     rode 0 in 20."
                    -- contract/asyncapi.yaml, the winact/textget/textset block

NOW is porting the act plane on the strength of that number and, until this
file existed, had no way to reproduce it. That is the whole reason this port
was worth doing before the verbs it drives exist.

## STATUS ON NOW TODAY: REFUSES

Every case needs verbs no NOW guest serves. It refuses at the top, names them,
and exits 2. It does not connect-and-report-0/0, which would read as a guard
holding and would be a lie. See "What this needs from NOW" below.

## The question, and why it gates everything after it

A trap-patch act plane is system-wide: every application's `MenuSelect` and
`TrackControl` go through it. The guard is supposed to make that invisible —
act only for an armed request in the matching context, chain through
otherwise. Ordinary work produced no stray actuation across forty trials
upstream. But nobody had ever armed a request and then deliberately clicked
something ELSE. This does exactly that.

It gates the rest because each new op patches another trap, so a leaky guard
MULTIPLIES rather than repeats.

## The shape of a trial

The act verbs are atomic — they arm in the target's context, post their own
click, and wait (~5 s) for the patch to fire. There is no "arm only" verb, so
the armed window is manufactured honestly: the request is armed against a
DECOY that its own posted click cannot make the app track, so the arm stays
live for the full wait, and the real click is injected during it.

  * control decoy — a control whose rect the app will not track (a hidden or
    rangeless one). The verb's own click lands on nothing trackable.
  * menu decoy — `titleLeft` far off-screen, so the posted click is not in the
    menu bar and the app never calls `MenuSelect` for it.

The stimulus is a REAL mouse press over QMP: the emulated machine's own
hardware input, arriving from outside the guest CPU, indistinguishable to the
application from a human's hand. QMP is the test's stimulus, never the act
plane's mechanism — the ops under test have no QMP in their path.

## Oracles — guest state, never the verb's own report

| Case | armed | real click | hijack shows as | chain-through shows as |
|---|---|---|---|---|
| control | scroll `inPageUp` (22) on a decoy | the LIVE bar's down arrow | the live bar jumps a PAGE (armed part) | it moves one LINE down (its own part) |
| menu | Finder File/New Folder | the Apple menu -> About This Computer | an `untitled folder` on the Desktop | the About window opens |
| stale | either, then no click at all | the same click, ten seconds later | same as above | same as above |

The control case is discriminating BY DIRECTION, which is the same trick that
ruled out "the click did it" for the control op itself: a hijack and an honest
chain-through move the same control in opposite directions by different
amounts, so no single reading can be read both ways. The menu case's hijack
oracle is a folder on disk — the strongest oracle this project has.

`ok:true` is never evidence here. It is recorded, because a reply that
disagrees with the guest is itself a finding, but the verdict is the guest's.

## What this needs from NOW to become runnable

    observe        mint element/window/control references, and report the
                   process list, the menu bar, and each window's controls with
                   their rect / value / min / max. Wave 2A of the fold-in.
                   NOTHING here can be addressed without it: NOW's act plane
                   takes "now-window-<uuid>" and "now-element-<uuid>", and only
                   an observation can mint one.
    mouseloc       read the guest's cursor. Every hop calibration is a closed
                   loop against it, and there is no substitute: QMP can tell
                   you what it ASKED for, and acceleration means that is not
                   where the cursor went.
    ctlinvoke      the control op, for the control and text cases.
    menuinvoke     the menu op, for the menu, stale and window cases.

    winact         DECLARED in NOW's contract, served by no guest. Not used by
    textget        the three headline cases, but the text case below is the
    textset        one lane that could run first, since two of its three verbs
                   are already through design review.

The Desktop-folder oracle needs NOTHING further: it is built on `ls` and
`file.trash`, which NOW already serves. See oracles.py — upstream needed a
second guest process for that read and this port does not.

## Comparability with upstream's numbers

Preserved deliberately, and the places it could have been lost:

  * the counting is `tally.py`, ported wholesale and covered by a test with a
    watched mutation list. A dropped trial is still dropped; the denominator
    is still trials-minus-dropped. Upstream's 0/19 is 19 because one click
    missed, and this port still produces 19 there rather than 20.
  * `paged_to_minimum` still requires the bar to reach its MINIMUM. Upstream
    saw one trial move exactly one line up with the patch reporting it never
    fired, and notes that scoring "went up" as a hijack "would have published
    that as a leak".
  * N defaults to 20, the arm delay to 1.5 s and the stale delay to 10 s —
    upstream's values. Changing any of them changes what the number means.
  * the per-trial record keys are upstream's, so a run here can be diffed
    field-for-field against `upstream/p2-nohijack.json`.

WHAT IS NOT COMPARABLE, and must be said before anyone lines up two tables:
upstream measured a trap-patch Portal on Mirror's guest. NOW's act plane is
not that implementation. A 0/20 here would be evidence about NOW's guard, and
agreeing with upstream's 0/20 is corroboration, not the same measurement.

Usage (a guest must be up and dialing this host):

    NOW_METAL=1 python3 scripts/probes/nohijack-probe.py \\
        --port 5252 --qmp run/qmp.sock --case control --n 20
    NOW_METAL=1 python3 scripts/probes/nohijack-probe.py ... --case menu --n 20
    NOW_METAL=1 python3 scripts/probes/nohijack-probe.py ... --case stale
    NOW_METAL=1 python3 scripts/probes/nohijack-probe.py ... --case window
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oracles                                                    # noqa: E402
import qmp as qmpmod                                              # noqa: E402
import tally                                                      # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "nohijack-probe"

# Control Manager part codes — Inside Macintosh, the Control Manager;
# ControlDefinitions.h. Not invented: upstream records that a phantom
# 10/11/12/13 in a doc comment is what made the control op look broken for a
# day. 12 and 13 are NOT part codes.
IN_BUTTON, IN_CHECKBOX = 10, 11
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
# Computer): the menu bar is 20px tall and item 1 is 16px, so its row is
# y 21..36 and its middle is 28. MEASURED rather than guessed — upstream's
# releases at y 33..35 selected nothing, and a drag that reached y 37 landed on
# item 3 and launched AirPort. The REQUEST that gets there is learned per run,
# because the guest moves less than it is asked and by an amount that is not
# linear in the distance.
MENU_ITEM1_Y = 28

# Upstream's defaults. Each is part of what the number means.
DEFAULT_N = 20
DEFAULT_ARM_DELAY = 1.5         # must be INSIDE the verb's ~5s wait
DEFAULT_STALE_DELAY = 10.0
DISARM_SWEEP = [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 12.0]

REQUIRED = {
    "control": ("observe", "mouseloc", "ctlinvoke"),
    "menu": ("observe", "mouseloc", "menuinvoke"),
    "stale": ("observe", "mouseloc", "menuinvoke"),
    "window": ("observe", "mouseloc", "menuinvoke"),
    "baseline": ("observe", "mouseloc"),
    "text": ("observe", "textget", "textset"),
}

GATE_NOTE = """\
This is the harness behind 18/20 -> 0/19, the measurement NOW's own contract
cites in the act plane's preamble as the reason winact/textget/textset address
one element by a minted reference. NOW is building that plane now and cannot
yet reproduce the number that justifies it.

`observe` is the blocker for every case: NOW's act plane addresses
"now-window-<uuid>" and "now-element-<uuid>", and only an observation mints
one. It is Wave 2A of docs/mirror-foldin-inventory.md.

The Desktop-folder oracle is NOT blocked - it is built on `ls` and
`file.trash`, which this guest already serves. Upstream needed a second guest
process for that read; see scripts/probes/oracles.py."""


# --- guest-state readers -----------------------------------------------------
#
# Each is expressed against the surface NOW has DECLARED where one exists, and
# against the Mirror spelling where NOW has not decided. A reader whose verb
# does not exist is never reached: the gate above refuses first.

def mouseloc(link) -> tuple:
    out = link.command("mouseloc")
    return int(link.field(out, "mouseloc", "x")), \
        int(link.field(out, "mouseloc", "y"))


def observe(link, scope: str = "front") -> dict:
    """One observation. Mints the references everything else addresses.

    Shape assumed: an `observe` output carrying processes, windows (each with
    controls) and the menu bar, with an opaque `ref` per element. That is what
    the reference layer is specified to produce (fold-in Wave 2A) and what
    NOW's act plane requires as input. If it lands with a different shape,
    THIS function is the only place that has to change.
    """
    return link.command("observe", {"scope": scope})


def front_window_controls(link) -> list:
    out = []
    for w in observe(link).get("windows", []):
        out.extend(w.get("controls", []))
    return out


def control_by_ref(link, ref: str):
    for c in front_window_controls(link):
        if c.get("ref") == ref:
            return c
    return None


def window_titles(link) -> list:
    return [w.get("title") for w in observe(link).get("windows", [])]


def live_scroll_bar(link):
    """A control with a LIVE RANGE — the one the real click will move.

    A scroll bar sitting at its maximum cannot page down, and a no-op that is
    correct behaviour is indistinguishable from a broken verb. The case picks
    its direction against the control's live value for that reason.
    """
    for c in front_window_controls(link):
        lo, hi = c.get("min"), c.get("max")
        if lo is None or hi is None or hi <= lo:
            continue
        if not c.get("visible"):
            continue
        if c.get("rect"):
            return c
    return None


def decoy_control(link, live: dict):
    """A control the app will NOT track: hidden, or with no range.

    Without one the request fires on its own posted click and there is no
    armed window to test. This is the single precondition that makes the
    control case a measurement rather than a re-run of the op's own test.
    """
    for c in front_window_controls(link):
        if c.get("ref") == live.get("ref"):
            continue
        lo, hi = c.get("min"), c.get("max")
        if not c.get("visible") or lo is None or hi is None or hi <= lo:
            return c
    return None


def about_window(link) -> bool:
    return any("About This Computer" in (t or "") for t in window_titles(link))


# --- case: control cross-fire ------------------------------------------------

def case_control(link, qmp, n: int, arm_delay: float) -> dict:
    """Arm against control A, click control B for real. B must do B's thing and
    A must not move.

    Both controls live in the SAME window of the SAME process, so the only
    thing standing between the armed request and the user's click is the
    guard's own identity test. A context test cannot help here — which is
    exactly why this case is the discriminating one for "identity is the
    guard".

    The discriminator is DIRECTION. The armed part is `inPageUp`, the real
    click is on the down arrow, and the two move the bar opposite ways:

        chain-through  value INCREASES (the bar did what the click asked)
        hijack         value DECREASES to the MINIMUM (it did what the
                       REQUEST asked; a page here is the whole range)

    which no single reading can be read both ways.
    """
    bar0 = live_scroll_bar(link)
    if bar0 is None:
        raise SystemExit("PRECONDITION FAILED: no control with a live range")
    target0 = ((bar0["rect"][0] + bar0["rect"][2]) // 2, bar0["rect"][3] - 8)
    hop = qmpmod.learn_hop(lambda: mouseloc(link), qmp, "bottom-right", target0)
    print(f"    down arrow at {target0}, learned hop {hop}")

    trials = []
    print(f"\n=== control cross-fire (same process, different control), N={n}")
    for i in range(n):
        bar = live_scroll_bar(link)
        if bar is None:
            raise SystemExit("PRECONDITION FAILED: no control with a live range")
        decoy = decoy_control(link, bar)
        if decoy is None:
            raise SystemExit(
                "PRECONDITION FAILED: no untrackable control to arm against — "
                "without one the request fires on its own click and there is "
                "no armed window to test.")

        target = ((bar["rect"][0] + bar["rect"][2]) // 2, bar["rect"][3] - 8)
        if target != target0:
            # The window moved: the learned hop no longer aims anywhere known.
            target0 = target
            hop = qmpmod.learn_hop(lambda: mouseloc(link), qmp,
                                   "bottom-right", target0)
        b_before = bar.get("value")
        a_before = (control_by_ref(link, decoy["ref"]) or {}).get("value")

        mid = link.send_async("ctlinvoke",
                              {"element": decoy["ref"], "part": IN_PAGE_UP})
        time.sleep(arm_delay)                       # let the arm and its warp land
        qmpmod.replay_hop(qmp, "bottom-right", hop)  # undo the verb's cursor warp
        qmp.click()                                  # the real user's click
        t0 = time.time()
        try:
            reply = link.read_result(mid, timeout=40)
        except TimeoutError:
            reply = None
        elapsed = time.time() - t0
        time.sleep(1.5)

        landed = mouseloc(link)
        b_after = (control_by_ref(link, bar["ref"]) or {}).get("value")
        a_after = (control_by_ref(link, decoy["ref"]) or {}).get("value")

        went_down = tally.moved_own_way(b_before, b_after)
        paged_up = tally.paged_to_minimum(b_after, bar.get("min"))
        hijacked = tally.hijacked(reply, paged_up)

        # A click that missed is not a trial. Scoring it would report a clean
        # no-hijack that never tested anything. The bar's own rect is the
        # bound: upstream's +/-6px box around the aim point rejected clicks
        # that plainly landed on the arrow and worked, so the rect is used.
        rect = bar["rect"]
        valid = (rect[0] - 4 <= landed[0] <= rect[2] + 4
                 and rect[1] <= landed[1] <= rect[3] + 4)
        # An unreadable control is not a clean trial either: tally refuses to
        # score missing data as a negative, and the trial is dropped here.
        if b_before is None or b_after is None:
            valid = False

        trials.append({
            "trial": i + 1, "decoy": decoy["ref"], "bar": bar["ref"],
            "barBefore": b_before, "barAfter": b_after,
            "decoyBefore": a_before, "decoyAfter": a_after,
            "replyOk": bool(reply and reply.get("ok")),
            "error": ((reply or {}).get("error") or {}).get("code"),
            "elapsed": round(elapsed, 2), "target": list(target),
            "landed": list(landed), "valid": valid,
            "hijacked": hijacked, "chained": bool(went_down),
            "pagedUp": bool(paged_up), "decoyMoved": a_before != a_after,
        })
        sys.stdout.write("!" if not valid else
                         ("H" if hijacked else ("." if went_down else "?")))
        sys.stdout.flush()
    print()
    return tally.summarize("control", trials)


# --- case: menu cross-fire ---------------------------------------------------

def apple_title_point(link) -> tuple:
    """A point ON the Apple menu's title.

    Aimed near its LEFT edge, not at the midpoint to the next menu's `left`:
    the gap between two titles is padding, not title, and a press that lands
    there opens no menu at all. MEASURED, not assumed — upstream, with the
    Apple title at x=10 and File at x=38, presses at x=27..30 selected nothing
    while presses at x=18 worked every time.
    """
    menus = observe(link).get("menus") or []
    if not menus:
        raise SystemExit("PRECONDITION FAILED: no menus in the bar")
    return (int(menus[0]["left"]) + 8, 9)


def finder_menu(link, title: str):
    for m in observe(link).get("menus") or []:
        if m.get("title") == title:
            return m
    return None


def press_with_tracking_probe(link, qmp, hold: float = 1.2):
    """Press the mouse and find out whether the front app entered a MENU
    TRACKING LOOP — usable only when the wire is free.

    A much stronger "the menu behaved normally" oracle than whether an item
    ended up selected, which depends on landing a drag inside a 16px row and
    was only ~60% reliable upstream. Cooperative multitasking gives it for
    free: `MenuSelect`'s tracking loop does not yield, so while a menu is down
    the responder gets no time and cannot answer. A request unanswered for as
    long as the button is held is the app tracking a menu; a prompt answer
    means `MenuSelect` returned immediately and no menu was ever drawn — which
    is exactly what a hijacking patch does.

    Returns (starved, pending); `pending` says a reply still has to be drained
    once the button is released.

    NOTE for the NOW port: this uses a cheap round trip as the probe. Upstream
    sent `ping`, which on Mirror's wire was a verb. On NOW's wire ping is
    GUEST-driven keepalive and the host must never initiate it, so `vers` — the
    cheapest wire-served command NOW has — stands in. The oracle is the
    LATENCY, not the verb, so the substitution is safe; it is called out
    because a reader comparing the two files will notice it.
    """
    mid = link.send_async("vers")
    qmp.button(True)
    try:
        link.read_result(mid, timeout=hold)
        return False, False
    except (TimeoutError, OSError):
        return True, (mid, True)


def menu_setup(link, qmp) -> tuple:
    """Everything that needs feedback, done while the wire is still free."""
    read = lambda: mouseloc(link)          # noqa: E731
    hop = qmpmod.learn_hop(read, qmp, "top-left", apple_title_point(link))
    drag = qmpmod.learn_drag(read, qmp, hop, "top-left", MENU_ITEM1_Y)
    return hop, drag


def menu_trial(link, qmp, click_delay: float, wait_for_reply_first: bool,
               hop: tuple, drag: int) -> dict:
    """One armed Finder File/New Folder, one real Apple-menu selection.

    `wait_for_reply_first` is the stale case: read the verb's reply (it times
    out and disarms) BEFORE clicking, so the click lands after the guard should
    already be disarmed.
    """
    if oracles.front_app(link) != "Finder":
        link.command("front", line="Finder")
        time.sleep(1.5)
    if oracles.front_app(link) != "Finder":
        raise SystemExit("PRECONDITION FAILED: the Finder is not frontmost")
    oracles.clear_desktop_untitled_folders(link)
    folders_before = oracles.desktop_untitled_folders(link)
    if folders_before:
        # An oracle that starts dirty cannot tell this trial's folder from the
        # last one's. Upstream's accumulating-oracle lesson, enforced.
        return {"valid": False, "why": "desktop was not clean",
                "hijacked": False, "chained": False}

    file_menu = finder_menu(link, "File")
    if file_menu is None:
        raise SystemExit("PRECONDITION FAILED: the Finder's File menu is not "
                         "in the observation")

    # The Apple menu's title, near the top-left corner — which is why the
    # trial pins THERE: the replayed hop is a dozen pixels long.
    target = apple_title_point(link)

    mid = link.send_async("menuinvoke", {"menu": file_menu["ref"], "item": 1,
                                         "titleLeft": OFFSCREEN_TITLE_LEFT})
    reply = None
    if wait_for_reply_first:
        reply = link.read_result(mid, timeout=40)
        time.sleep(click_delay)
    else:
        time.sleep(click_delay)

    qmpmod.replay_hop(qmp, "top-left", hop)     # undo the verb's cursor warp

    # A real menu selection: press on the title, let the menu drop, drag down
    # onto item 1 (About This Computer), release. If the guard leaks, the app's
    # MenuSelect returns our armed item the instant the button goes down and no
    # menu is ever drawn — the drag then falls on the desktop, harmless.
    pending = None
    if wait_for_reply_first:
        starved, pending = press_with_tracking_probe(link, qmp)
    else:
        starved = None
        qmp.button(True)
        time.sleep(0.8)
    qmp.rel(0, drag, step=3, pace=0.004)
    time.sleep(0.6)
    qmp.button(False)
    time.sleep(2.5)

    if reply is None:
        try:
            reply = link.read_result(mid, timeout=40)
        except TimeoutError:
            reply = None
    if pending:
        try:
            link.read_result(pending[0], timeout=30)
        except TimeoutError:
            pass
    time.sleep(2.0)

    # Where the press actually landed. The drag adds ~10px in y, so the check
    # is that the press was on the Apple menu's TITLE (which spans ~28px) and
    # still in the menu bar's row of the screen.
    landed = mouseloc(link)
    valid = abs(landed[0] - target[0]) <= 12 and landed[1] <= 40

    folders_after = oracles.desktop_untitled_folders(link)
    new_folder = bool(folders_after - folders_before)
    about = about_window(link)
    return {
        "newFolder": new_folder,          # the ARMED command fired: a hijack
        "aboutOpened": about,             # the user's own selection worked
        "replyOk": bool(reply and reply.get("ok")),
        "error": ((reply or {}).get("error") or {}).get("code"),
        "hijacked": tally.hijacked(reply, new_folder),
        "tracked": starved,       # recorded, NOT scored: menu tracking does
                                  # not reliably starve the responder (measured)
        "chained": about,
        "selected": about,
        "target": list(target), "landed": list(landed), "valid": valid,
    }


def _run_menu_cases(link, qmp, n: int, delay: float, stale: bool,
                    name: str) -> dict:
    hop, drag = menu_setup(link, qmp)
    print(f"\n=== {name}, N={n} (hop {hop}, drag {drag})")
    trials = []
    for i in range(n):
        t = menu_trial(link, qmp, delay, stale, hop, drag)
        t["trial"] = i + 1
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("H" if t["hijacked"] else
                          ("." if t["chained"] else "?")))
        sys.stdout.flush()
    print()
    return tally.summarize(name, trials)


def case_menu(link, qmp, n: int, arm_delay: float) -> dict:
    return _run_menu_cases(link, qmp, n, arm_delay, False, "menu")


def case_stale(link, qmp, n: int, stale_delay: float) -> dict:
    """Arm, never click during the window, then click LONG after. A request
    that lurks and fires on the user's next unrelated click is the failure this
    case exists to find."""
    return _run_menu_cases(link, qmp, n, stale_delay, True, "stale")


def case_baseline(link, qmp, n: int) -> dict:
    """The same real Apple-menu selection with NOTHING armed.

    Without this the menu case cannot tell "the armed request stole the click"
    from "my drag never selected anything", and the whole finding would rest on
    an unfalsified assumption about my own stimulus. This case is excluded from
    the exit status for that reason: it measures the STIMULUS.
    """
    hop, drag = menu_setup(link, qmp)
    print(f"\n=== baseline (nothing armed), N={n}")
    trials = []
    for i in range(n):
        if oracles.front_app(link) != "Finder":
            link.command("front", line="Finder")
            time.sleep(1.5)
        oracles.clear_desktop_untitled_folders(link)
        before = oracles.desktop_untitled_folders(link)
        qmpmod.replay_hop(qmp, "top-left", hop)
        starved, pending = press_with_tracking_probe(link, qmp)
        qmp.rel(0, drag, step=3, pace=0.004)
        time.sleep(0.6)
        qmp.button(False)
        time.sleep(2.5)
        if pending:
            try:
                link.read_result(pending[0], timeout=30)
            except TimeoutError:
                pass
        after = oracles.desktop_untitled_folders(link)
        t = {"trial": i + 1, "newFolder": bool(after - before),
             "aboutOpened": about_window(link), "tracked": starved,
             "hijacked": bool(after - before), "chained": about_window(link)}
        trials.append(t)
        sys.stdout.write("." if t["chained"] else "?")
        sys.stdout.flush()
    print()
    return tally.summarize("baseline", trials)


def case_window(link, qmp, delays: list) -> dict:
    """Measure the DISARM WINDOW rather than assume it: click at increasing
    delays after arming and find where hijacking stops.

    Excluded from the exit status: this case is SUPPOSED to hijack at short
    delays. That is what it measures.
    """
    hop, drag = menu_setup(link, qmp)
    print(f"\n=== disarm window sweep, delays={delays}")
    trials = []
    for d in delays:
        t = menu_trial(link, qmp, d, False, hop, drag)
        t["delay"] = d
        trials.append(t)
        print(f"    +{d:4.1f}s  hijacked={t['hijacked']!s:5} "
              f"about={t.get('aboutOpened')!s:5} reply={t.get('error') or 'ok'}")
    return {"case": "window", "trials": trials}


# --- case: the text ops (upstream's lane P2, 2026-07-31) --------------------

def case_text(link, n: int) -> dict:
    """`textset` then read back, twice, by two independent paths.

    The lane most likely to run FIRST on NOW: `textget`/`textset` are already
    declared in NOW's contract with their argument shapes fixed, so only
    `observe` (to mint the element reference) stands between this case and a
    real number.

    The oracle rule that matters here, from upstream: `textset`'s reply already
    contains a read-back, and that read-back "travels the same code, in the
    same call, through the same hook — so it cannot rule out a verb that
    faithfully reports its own private copy of a string." Two INDEPENDENT
    reads are therefore required, and both must agree:

      * a fresh `textget` in a separate round trip, after a settle;
      * the observation's own report of the element's text, which comes from
        the foreign-memory walk (now-guest-ppc/src/axwalk/axtext.c) rather than
        from the act plane, and shares no code, no call and no moment with it.

    Independence between trials: each trial writes a value UNIQUE to that
    trial. A probe that leaves the previous trial's string in the field
    measures a different machine each time — that is the accumulating oracle
    which manufactured the "~9 actuations per boot" ceiling.
    """
    print(f"\n=== text ops (textset, two independent reads), N={n}")
    trials = []
    for i in range(n):
        element = None
        for w in observe(link).get("windows", []):
            for e in w.get("elements", []):
                if e.get("kind") in ("editText", "textEdit"):
                    element = e
                    break
            if element:
                break
        if element is None:
            trials.append({"trial": i + 1, "valid": False,
                           "why": "no editable text element observed"})
            continue

        # Unique per trial, and short enough to survive a 4096-byte control
        # frame with room for the envelope.
        wanted = f"probe-{i + 1:03d}-" + "".join(
            chr(ord('a') + ((i * 7 + k) % 26)) for k in range(8))

        replied = actuated = False
        try:
            link.command("textset", {"element": element["ref"], "text": wanted})
            replied = True
        except GuestError:
            replied = True          # rule 2: ok:false IS a reply
        except TimeoutError:
            replied = False
        time.sleep(1.0)

        readback = None
        try:
            out = link.command("textget", {"element": element["ref"]})
            readback = link.maybe_field(out, "textget", "text")
        except (GuestError, TimeoutError):
            pass

        # The second, independent path: the observation's own walk.
        walked = None
        for w in observe(link).get("windows", []):
            for e in w.get("elements", []):
                if e.get("ref") == element["ref"]:
                    walked = e.get("text")
        actuated = (readback == wanted) and (walked == wanted)

        trials.append({"trial": i + 1, "element": element["ref"],
                       "wanted": wanted, "textget": readback,
                       "observed": walked, "replied": replied,
                       "actuated": actuated,
                       "agreed": readback == walked})
        sys.stdout.write("." if actuated else ("~" if replied else "?"))
        sys.stdout.flush()
    print()
    return tally.rate_summary("text", trials)


# --- main --------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--qmp", required=True,
                    help="QEMU QMP unix socket. The real mouse comes from "
                         "OUTSIDE the guest; there is no substitute and this "
                         "probe cannot run on metal.")
    ap.add_argument("--case", action="append",
                    choices=tuple(REQUIRED))
    ap.add_argument("--n", type=int, default=DEFAULT_N)
    ap.add_argument("--arm-delay", type=float, default=DEFAULT_ARM_DELAY,
                    help="seconds between sending the request and the real "
                         "click (must be inside the verb's ~5s wait)")
    ap.add_argument("--stale-delay", type=float, default=DEFAULT_STALE_DELAY)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    cases = args.case or ["baseline", "control", "menu", "stale"]

    link = link_from_args(args)
    needed = sorted({v for c in cases for v in REQUIRED[c]})
    link.require_verbs(PROBE, *needed, note=GATE_NOTE)

    qmp = qmpmod.Qmp(args.qmp)

    results = []
    for case in cases:
        if case == "baseline":
            results.append(case_baseline(link, qmp, min(args.n, 5)))
        elif case == "control":
            results.append(case_control(link, qmp, args.n, args.arm_delay))
        elif case == "menu":
            results.append(case_menu(link, qmp, args.n, args.arm_delay))
        elif case == "stale":
            results.append(case_stale(link, qmp, args.n, args.stale_delay))
        elif case == "text":
            results.append(case_text(link, args.n))
        elif case == "window":
            results.append(case_window(link, qmp, DISARM_SWEEP))

    tally.print_summary(results)

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")

    # A hijack is a FINDING, not a crash: report it, and say so in the exit
    # status, because this number gates every later act op.
    return tally.exit_status(results)


if __name__ == "__main__":
    raise SystemExit(main())
