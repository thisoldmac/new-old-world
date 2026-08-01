#!/usr/bin/env python3
"""Lane G1's probe for the `apple-event` verb — the one behind `mirror.app
{op:"quit"}`.

Measured against GUEST STATE, never the verb's own reply. `apple-event` is
fire-and-forget (kAENoReply), so `sent:true` says only that the event left the
agent; the oracle for a quit is the target LEAVING `observe`.

  quit    launch an application, send the quit event to its PSN, and require
          the process to disappear from `observe`.
  dirty   the same application with an UNSAVED document. A quit Apple Event
          then raises a save-changes alert and the app STAYS RUNNING. That is
          the documented behaviour of a well-behaved application, not a
          failure of the verb — the probe reports which of the two happened
          and passes either way, because forcing it would mean discarding a
          document.
  refuse  the refusals: an event outside the quit/oapp/odoc/pdoc whitelist,
          missing serials, and a PSN that no longer names a process.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/apple-event-probe.py --agent-port 1722 [--case quit|dirty|refuse]

The client shape is g1-probe.py's, imported rather than copied: ONE persistent
connection, reused, because a socket per request races the guest's accept.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "g1_probe", os.path.join(HERE, "g1-probe.py"))
_g1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_g1)
Agent, GuestError = _g1.Agent, _g1.GuestError
running, windows_of, quit_app = _g1.running, _g1.windows_of, _g1.quit_app


def psn_of(a: Agent, name: str) -> dict | None:
    return next((p for p in a.call("observe")["processes"]
                 if p.get("name") == name), None)


def ensure_running(a: Agent, path: str, name: str,
                   timeout: float = 30.0) -> dict | None:
    """Start the target if it is not up, and wait for its WINDOW — an app that
    is still opening has not yet installed its AE handlers, and a quit sent
    into that gap measures the race and not the verb."""
    if not running(a, name):
        a.call("launch", {"path": path})
    t0 = time.time()
    while time.time() - t0 < timeout:
        if windows_of(a, name):
            return psn_of(a, name)
        time.sleep(1.0)
    return psn_of(a, name) if running(a, name) else None


def left_observe(a: Agent, name: str, timeout: float = 25.0) -> float | None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if not running(a, name):
            return time.time() - t0
        time.sleep(1.0)
    return None


def case_quit(a: Agent, path: str, name: str, trials: int) -> int:
    """Oracle = the process leaving `observe`. Trials are independent: each
    starts with the application freshly launched, because quitting an app that
    is already gone proves nothing."""
    replies = actuations = 0
    for i in range(trials):
        proc = ensure_running(a, path, name)
        if proc is None:
            print(f"  [{i}] PRECONDITION FAILED: {name} would not start")
            return 1
        hi, lo = proc["serialHi"], proc["serialLo"]
        try:
            res = a.call("apple-event",
                         {"event": "quit", "serialHi": hi, "serialLo": lo})
            replies += 1
            sent = res.get("sent")
        except GuestError as e:
            print(f"  [{i}] refused: {e}")
            replies += 1                       # an honest refusal IS a reply
            sent = False
        took = left_observe(a, name)
        if took is not None:
            actuations += 1
            print(f"  [{i}] sent={sent}  LEFT observe after {took:.1f}s "
                  f"(psn {hi}.{lo})")
        else:
            wins = [w.get("title") for w in windows_of(a, name)]
            print(f"  [{i}] sent={sent}  STILL RUNNING after 25s; "
                  f"windows={wins}")
    print(f"  quit reply {replies}/{trials}, actuation {actuations}/{trials}")
    return 0 if actuations == trials else 1


def case_dirty(a: Agent, path: str, name: str) -> int:
    """An unsaved document is a legitimate refusal by the TARGET, not by us.

    Type a character into the application's document, then send quit. Either
    outcome is reported; only an error from the verb itself fails the case.
    """
    if running(a, name) and not quit_app(a, name):
        print(f"  PRECONDITION FAILED: could not clear a running {name}")
        return 1
    proc = ensure_running(a, path, name)
    if proc is None:
        print(f"  PRECONDITION FAILED: {name} would not start")
        return 1
    hi, lo = proc["serialHi"], proc["serialLo"]
    a.call("activate", {"serialHi": hi, "serialLo": lo})
    time.sleep(1.0)
    # 'x': keycode 7, char 120 (IM: Toolbox Essentials, Event Manager — the
    # same chart g1-probe.py takes 12='q' from). Keycode, not character, is
    # what the guest wants on the raw wire (docs/CONTROL-SURFACE.md).
    a.call("key", {"code": 7, "char": 120, "mods": 0})
    time.sleep(1.5)
    before = [w.get("title") for w in windows_of(a, name)]
    print(f"  windows before quit: {before}")

    res = a.call("apple-event",
                 {"event": "quit", "serialHi": hi, "serialLo": lo})
    print(f"  sent={res.get('sent')} mechanism={res.get('mechanism')}")
    took = left_observe(a, name, timeout=15.0)
    if took is None:
        wins = [w.get("title") for w in windows_of(a, name)]
        print(f"  STILL RUNNING (expected): windows={wins}")
        print("  -> the target raised a save-changes alert and declined. The "
              "verb did its job; the document is the user's to resolve.")
    else:
        print(f"  LEFT observe after {took:.1f}s — no alert was raised "
              f"(the document was not dirty, or the app discards silently)")
    return 0


def case_refuse(a: Agent, path: str, name: str) -> int:
    """Every refusal must be a well-formed error envelope with a code that
    tells the caller which of the three things went wrong."""
    proc = ensure_running(a, path, name)
    hi = proc["serialHi"] if proc else 0
    lo = proc["serialLo"] if proc else 0
    checks = [
        ("event outside the whitelist",
         {"event": "frob", "serialHi": hi, "serialLo": lo}, "bad_request"),
        ("missing serials", {"event": "quit"}, "bad_request"),
        ("missing event", {"serialHi": hi, "serialLo": lo}, "bad_request"),
        ("odoc without a path",
         {"event": "odoc", "serialHi": hi, "serialLo": lo}, "bad_request"),
        ("odoc with a path that names nothing",
         {"event": "odoc", "serialHi": hi, "serialLo": lo,
          "path": "Macintosh HD:no-such-folder:no-such-file"}, "not_found"),
        ("a PSN that names no process",
         {"event": "quit", "serialHi": 0, "serialLo": 0x7FFFFFFF},
         "not_found"),
    ]
    bad = 0
    for label, args, want in checks:
        try:
            res = a.call("apple-event", args)
            print(f"  {label}: ACCEPTED {res} (wanted {want})")
            bad += 1
        except GuestError as e:
            ok = e.code == want
            print(f"  {label}: {e.code}{'' if ok else f' (wanted {want})'}"
                  f" — {e.message}")
            bad += 0 if ok else 1
    return 0 if bad == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--case", default="all",
                    choices=["all", "quit", "dirty", "refuse"])
    # The OS 9.1 install names the folder "Applications (Mac OS 9)"; the bare
    # "Applications" that g1-probe.py defaults to is the Mac OS X one and does
    # not exist on this image.
    ap.add_argument("--path",
                    default="Macintosh HD:Applications (Mac OS 9):SimpleText")
    ap.add_argument("--app-name", default="SimpleText")
    ap.add_argument("--trials", type=int, default=1)
    args = ap.parse_args()

    a = Agent(args.agent_port)
    rc = 0
    try:
        if args.case in ("all", "quit"):
            print("== quit ==")
            rc |= case_quit(a, args.path, args.app_name, args.trials)
        if args.case in ("all", "refuse"):
            print("== refuse ==")
            rc |= case_refuse(a, args.path, args.app_name)
        if args.case in ("all", "dirty"):
            print("== dirty ==")
            rc |= case_dirty(a, args.path, args.app_name)
    finally:
        a.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
