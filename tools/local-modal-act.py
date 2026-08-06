#!/usr/bin/env python3
"""An act aimed at a REAL modal, timed — and the scenes that queue behind it.

    tools/local-modal-act.py --port 5590 --expect-build 711abdbd25ec \\
        --press Cancel

DIAGNOSTIC, `local-*`. Michelle's session of 2026-08-06 shows
`click "Cancel"` — queued behind 0, waited 0 ms, **guest 12099 ms, never
settled** — while scene requests in the same log read `request_ms=12041`.
Two twelve-second numbers side by side, and nothing has said which is
which: an act that is slow because the guest is slow, or scenes that are
slow because the act is holding the guest's only event loop.

So this sends ONE act and then keeps asking for scenes while it is in
flight, printing both clocks against one wall clock. The guest is serial,
so if the scenes stop for exactly as long as the act runs, the act is the
obstacle and the modal is only its cause.

The act is sent with `send_async` and never retried (nowwire's rule): a
retry re-arms and measures a machine in a state the run never asked for.
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402
from scene import SceneUnavailable  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5590)
    ap.add_argument("--expect-build", default=None)
    ap.add_argument("--press", default="Cancel")
    ap.add_argument("--part", type=int, default=10)
    ap.add_argument("--window", default="",
                    help="only look in the window with this title")
    ap.add_argument("--budget", type=float, default=90.0)
    a = ap.parse_args()

    link = nowwire.GuestLink.await_guest(a.port, timeout=180)
    build = str(link.hello.get("build") or "")
    if a.expect_build and a.expect_build not in build:
        raise SystemExit(f"WRONG BUILD: wanted {a.expect_build!r}, got {build!r}")

    t0 = time.time()
    doc, _ = link.scene(full=True, timeout=60)
    target = None
    for win in doc.get("windows") or []:
        if a.window and (win.get("title") or "") != a.window:
            continue
        for ctl in win.get("controls") or []:
            if (ctl.get("title") or "").strip().rstrip("…") == a.press:
                target = (win, ctl)
    if target is None:
        raise SystemExit(f"no control {a.press!r} in this scene — refusing "
                         "to time a press that did not happen")
    win, ctl = target
    print(f"target: {ctl['title']!r} in {win['title']!r} "
          f"(front={win.get('front')})", flush=True)

    sent = time.time()
    mid = link.send_async("ctlact", {"element": ctl["ref"], "part": a.part})
    print(f"{sent - t0:7.1f}s  ctlact sent (id {mid})", flush=True)

    deadline = sent + a.budget
    while time.time() < deadline:
        if mid in link._pending:
            break
        at = time.time()
        try:
            d, e = link.scene(full=False, timeout=deadline - at)
            titles = [w.get("title") for w in (d.get("windows") or [])]
            note = f"windows={len(titles)} {titles}"
        except (SceneUnavailable, TimeoutError) as exc:
            note = f"FAILED {type(exc).__name__}"
        print(f"{at - t0:7.1f}s  scene {(time.time() - at) * 1000:8.0f} ms  "
              f"{note}", flush=True)

    if mid in link._pending:
        reply = link._pending.pop(mid)
    else:
        try:
            reply = link.read_result(mid, timeout=max(1.0, deadline - time.time()))
        except TimeoutError:
            reply = {"type": "(none)", "note": "no reply inside the budget"}
    print(f"\nact answered after {time.time() - sent:.1f}s: {reply}", flush=True)

    # WHAT ACTUALLY HAPPENED ON THE MACHINE, read after: `performed` is a
    # dispatch claim and never an outcome (measurement rule 10).
    d, _ = link.scene(full=True, timeout=60)
    print("windows now: "
          f"{[w.get('title') for w in (d.get('windows') or [])]}", flush=True)
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
