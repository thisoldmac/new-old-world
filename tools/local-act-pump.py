#!/usr/bin/env python3
"""Did making the act wait pump the wire actually collapse the queue?

    tools/local-act-pump.py --port 5630 --expect-build 04f5dba645ad

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

THE PAIR IT REPRODUCES. Before 2026-08-06, `act_client.c :: act_yield`
did not service the wire, so an act the target would not take held
`conn_service` off for its whole deadline. Measured then: the act
answered after **6.6 s** and a `scene.request` issued in the same instant
answered in **6634 ms** — the same number twice, because it was the same
wait seen from both ends (docs/open-issues.md). This sends the same shape
and prints both clocks against one wall clock. The act's own number must
NOT collapse — an act nobody takes is *supposed* to cost its deadline —
and the scene's must.

HOW IT MAKES AN ACT RUN ITS FULL DEADLINE, deterministically and without
a modal. It fronts another process, then aims `ctlact` at a control in
NOW's own window, which is now BEHIND. A click in a background window
activates it; the application does not reach `TrackControl`, so the
request runs out its 300 ticks. Nothing on the machine is changed by it.

This shape was chosen after two others failed on a fresh clone, and both
failures are worth knowing before reaching for them again:

  * **A foreign target cannot be bound at all here.** Every process but
    the front one reports `not-observed` in the scene's coverage and
    every act aimed at one answers `no-such-process` — the anchor-bind
    defect the ledger already carries. So "aim at a background
    application" is not available; "aim at OUR OWN window while it is
    background" is, and it exercises the same wait.
  * **The first passes of a fresh connection report `bind: no-plane`.**
    An act sent then answers `no-such-process` for a reason that has
    nothing to do with the act wait, so this refuses to publish any
    number until `axsnap` says `bind: ok`.

THREE THINGS IT MEASURES, and they are three separate claims:

  1. **queue** — the act, and the scenes issued while it is in flight.
     Also runs the act SILENTLY first, so "the act expired" cannot be
     blamed on the polling that is measuring it.
  2. **lease** — the extension's `requested`/`active`, before and after,
     plus whether the NEXT act is refused. A non-pumping act used to
     lapse the ten-second owner lease because renewal rides
     `conn_service`; that is "refused the first time, worked the second".
  3. **busy** — two acts sent back to back, deliberately overlapping.
     Before the pump this was unobservable: the second command sat in the
     socket. Now it is dispatched INTO the first one's armed window,
     which is both the hazard the pump bought and the thing the
     interlock answers. `act-busy` here is the guard watched working on
     a machine rather than in a unit test.

It refuses a guest whose hello build is not `--expect-build`: every QEMU
guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener (AGENTS.md).
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402
from scene import SceneUnavailable  # noqa: E402

OURS = "New Old World"


def scene(link, full=True):
    return link.scene(full=full, timeout=120)[0]


def front_name(doc):
    for proc in doc.get("processes") or []:
        if proc.get("front"):
            return (proc.get("name") or "").strip()
    return None


def put_someone_else_in_front(link, doc):
    """Front any process that is not us, and say which.

    Our own window has to be BEHIND for the act to go untaken; that is
    the whole mechanism, so it is asserted rather than hoped for.
    """
    if front_name(doc) != OURS:
        return front_name(doc), doc
    for proc in doc.get("processes") or []:
        name = (proc.get("name") or "").strip()
        if name == OURS or not proc.get("psn"):
            continue
        hi, lo = str(proc["psn"]).split(".", 1)
        try:
            link.command("activate", {"serialHi": int(hi), "serialLo": int(lo)},
                         timeout=60)
        except nowwire.GuestError:
            continue
        time.sleep(3)
        doc = scene(link)
        if front_name(doc) != OURS:
            return front_name(doc), doc
    return front_name(doc), doc


def background_control(doc):
    """A control in a window that is NOT front. Ours, in practice."""
    for win in doc.get("windows") or []:
        if win.get("front"):
            continue
        for ctl in win.get("controls") or []:
            if ctl.get("ref") and (ctl.get("title") or "").strip():
                return ctl, win
    return None, None


def act(link, ref, part=10):
    return link.send_async("ctlact", {"element": ref, "part": part})


def code_of(reply):
    return (reply.get("error") or {}).get("code") or "ok"


def phase_queue(link, ref, budget, silent_runs):
    print("\n== 1. the act, and the scenes issued while it is in flight ==")
    # THE CONTROL RUN FIRST. If the act only expires when something is
    # polling it, the polled number says nothing.
    silent = []
    for _ in range(silent_runs):
        start = time.time()
        reply = link.read_result(act(link, ref), timeout=budget)
        silent.append((time.time() - start, code_of(reply)))
        print(f"  silent   {silent[-1][0]:5.2f}s  {silent[-1][1]}")
        time.sleep(1.5)

    start = time.time()
    mid = act(link, ref)
    deadline = start + budget
    scenes = []
    while time.time() < deadline:
        if mid in link._pending:
            break
        at = time.time()
        try:
            link.scene(full=False, timeout=max(1.0, deadline - at))
            scenes.append((time.time() - at) * 1000.0)
        except (SceneUnavailable, TimeoutError) as exc:
            print(f"  {at - start:6.2f}s  scene FAILED {type(exc).__name__}")
    reply = (link._pending.pop(mid) if mid in link._pending
             else link.read_result(mid, timeout=max(1.0, deadline - time.time())))
    took = time.time() - start
    print(f"  polled   {took:5.2f}s  {code_of(reply)}")
    if not scenes:
        print("  NO SCENE COMPLETED during the act - the queue is NOT "
              "collapsed. That is the pre-2026-08-06 reading.")
        return took, scenes
    scenes.sort()
    print(f"  scenes served DURING that act: n={len(scenes)}  "
          f"min={scenes[0]:.0f} ms  median={scenes[len(scenes) // 2]:.0f} ms  "
          f"max={scenes[-1]:.0f} ms")
    print("  Before this change ONE scene issued in the same instant "
          "answered in 6634 ms, matching the act's own 6.6 s.")
    return took, scenes


def lease(link):
    ext = ((link.command("mirror", timeout=60).get("mirror") or {})
           .get("extension") or {})
    return {k: ext.get(k) for k in ("lifecycle", "requested", "active")}


def phase_lease(link, ref, budget):
    print("\n== 2. does a full-deadline act still lapse the owner lease? ==")
    before = lease(link)
    print(f"  before: {before}")
    start = time.time()
    reply = link.read_result(act(link, ref), timeout=budget)
    print(f"  the act ran {time.time() - start:.2f}s and answered "
          f"{code_of(reply)}")
    after = lease(link)
    print(f"  after:  {after}")
    start = time.time()
    nxt = link.read_result(act(link, ref), timeout=budget)
    print(f"  the NEXT act ran {time.time() - start:.2f}s and answered "
          f"{code_of(nxt)} - a lapsed lease answers act-plane-absent")
    return before, after, code_of(nxt)


def phase_busy(link, ref, budget):
    print("\n== 3. two acts, deliberately overlapping ==")
    first = act(link, ref)
    second = act(link, ref)
    print("  both sent without reading between them. The second can only "
          "reach the guest's dispatcher if the first one's wait pumps.")
    codes = {}
    start = time.time()
    for label, mid in (("first", first), ("second", second)):
        reply = link.read_result(mid, timeout=budget)
        codes[label] = code_of(reply)
        message = (reply.get("error") or {}).get("message") or ""
        print(f"  {time.time() - start:5.2f}s  {label:6s} -> "
              f"{codes[label]}: {message[:100]}")
    if codes.get("second") == "act-busy":
        print("  THE INTERLOCK FIRED. The second act was dispatched inside "
              "the first one's armed window and refused before it could "
              "write a field - the new hazard and its answer, both watched "
              "on a machine.")
    else:
        print("  the second act was NOT refused as busy. That is an absence "
              "of the event the guard is for, not evidence the guard is "
              "absent - read it as inconclusive.")
    return codes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5630)
    ap.add_argument("--expect-build", default=None)
    ap.add_argument("--budget", type=float, default=45.0)
    ap.add_argument("--warm", type=float, default=60.0,
                    help="seconds to wait for the anchor plane to arm")
    ap.add_argument("--silent-runs", type=int, default=2,
                    help="unpolled acts before the polled one (the control)")
    ap.add_argument("--phases", nargs="*", default=["queue", "lease", "busy"])
    a = ap.parse_args()

    link = nowwire.GuestLink.await_guest(a.port, timeout=240)
    build = str(link.hello.get("build") or "")
    print(f"guest build: {build}")
    if a.expect_build and a.expect_build not in build:
        raise SystemExit(f"WRONG BUILD: wanted {a.expect_build!r}, got "
                         f"{build!r} - refusing to measure a guest this run "
                         "did not build")

    warm_deadline = time.time() + a.warm
    bind = "?"
    doc = None
    while time.time() < warm_deadline:
        try:
            doc = scene(link)
        except SceneUnavailable:
            pass
        snap = link.command("axsnap", timeout=60)
        bind = ((snap.get("axsnap") or {}).get("front") or {}).get("bind")
        if bind == "ok":
            break
        time.sleep(1.0)
    print(f"anchor bind after warm-up: {bind}")
    if bind != "ok" or doc is None:
        raise SystemExit(
            "the anchor plane never armed inside --warm seconds, so every "
            "act would answer no-such-process for a reason that has nothing "
            "to do with the act wait. Refusing to publish a number from it "
            "(docs/open-issues.md, the plane-bind entry).")

    who, doc = put_someone_else_in_front(link, doc)
    print(f"front process: {who!r}")
    if who == OURS:
        raise SystemExit("could not put anything in front of us, so no "
                         "window is behind and no act would go untaken")
    ctl, win = background_control(doc)
    if ctl is None:
        raise SystemExit("no control in a background window to aim at - "
                         "refusing to report a number from an act that was "
                         "never aimed")
    print(f"target: {ctl.get('title')!r} in {win.get('title')!r} (behind)")
    ref = ctl["ref"]

    if "queue" in a.phases:
        phase_queue(link, ref, a.budget, a.silent_runs)
    if "lease" in a.phases:
        phase_lease(link, ref, a.budget)
    if "busy" in a.phases:
        phase_busy(link, ref, a.budget)
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
