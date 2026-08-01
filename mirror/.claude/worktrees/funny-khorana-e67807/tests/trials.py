#!/usr/bin/env python3
"""Measure a verb's RATE, not its last result.

Built because a single-run experiment on this project's input plane produced a
confident, wrong conclusion: a keyDown/keyUp change looked like a fix at N=1
(zero actuations before, five after) and was falsified by the next two runs.
An intermittent behaviour cannot be reasoned about from single runs, and a
mutation test against one proves nothing at all.

So every claim about an act verb goes through here. Two rates are measured
separately, because they fail independently:

  reply rate     - did the verb answer at all (vs. failing to talk)
  actuation rate - did the guest actually DO the thing

An `ok:false` answer counts as a REPLY. The guest saying "not_actionable" is a
working verb reporting a fact, and conflating that with a transport failure is
how a healthy act plane got written up as broken.

Actuation needs a real oracle in the guest, never the verb's own say-so: the
reply says the event was posted, which is not evidence the front app acted.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/trials.py --agent-port 1720 --anchor-port 1700 --n 30
    python3 tests/trials.py --agent-port 1720 --anchor-port 1700 --case key-cmd-n
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.path.abspath(os.path.join(MIRROR, ".."))
# Lab INSTRUMENT: the anchor client drives the actuation oracle (reading the
# guest filesystem). Nothing under host/ or guest/ imports it (AGENTS.md).
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402


class Agent:
    """Client for the mirror agent's wire, shaped like MirrorKit's WireClient.

    ONE PERSISTENT CONNECTION, reused across requests. This is not an
    optimisation — it is correctness. The guest serves a single connection
    serially, and a fresh socket per request races its accept: the transport
    refuses the new indication (`ot.c`, the T_LISTEN busy path, which exists to
    reap crashed clients) and the caller sees a connection reset.

    An earlier version of this file opened a socket per request and did not
    retry. It produced a completely fictitious bug report — resets blamed on
    tracking-loop starvation and a verb accused of "poisoning the session",
    when the guest was healthy the whole time and the client was simply being
    refused. WireClient.swift had the comment warning about this before I
    wrote the mistake. Do not go back to per-request sockets.

    Errors are surfaced, not swallowed: an `ok:false` reply raises, so an
    honest refusal like `not_actionable` can never be mistaken for a wedge.
    """

    def __init__(self, port: int, timeout: float = 30.0):
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._buf = b""
        self._id = 0

    def _connect(self) -> socket.socket:
        if self._sock is None:
            self._sock = socket.create_connection(("127.0.0.1", self.port),
                                                  timeout=self.timeout)
            self._buf = b""
        return self._sock

    def _drop(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        self._sock = None
        self._buf = b""

    def call(self, verb: str, args: dict | None = None, retries: int = 3):
        """Send one request, return the `result` object.

        Retries a dropped connection: a reset means the slot was busy, and the
        transport's contract is that the client reconnects.
        """
        self._id += 1
        req = {"proto": 1, "id": self._id, "verb": verb}
        if args:
            req.update(args)
        payload = (json.dumps(req) + "\n").encode()

        last: Exception | None = None
        for _ in range(retries + 1):
            try:
                s = self._connect()
                s.sendall(payload)
                while b"\n" not in self._buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        raise ConnectionError("guest closed mid-reply")
                    self._buf += chunk
                line, _, self._buf = self._buf.partition(b"\n")
                # Guest JSON carries raw MacRoman bytes; decode as MacRoman so
                # high bytes become real characters instead of U+FFFD.
                try:
                    text = line.decode("mac_roman")
                except Exception:
                    text = line.decode("utf-8", "replace")
                reply = json.loads(text)
                if not reply.get("ok"):
                    err = reply.get("error", {})
                    raise GuestError(err.get("code", "error"),
                                     err.get("message", ""))
                return reply.get("result", {})
            except GuestError:
                raise                      # a real answer, never a retry
            except Exception as e:
                last = e
                self._drop()
                time.sleep(1.5)
        raise last if last else RuntimeError("unreachable")

    def close(self) -> None:
        self._drop()


class GuestError(Exception):
    """The guest answered `ok:false`. This is a RESULT, not a failure to talk."""

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


# --- actuation oracles -------------------------------------------------------
# Each returns a comparable snapshot of guest state. The oracle must be
# something the GUEST changed, not something the agent reported.

def desktop_untitled_folders(h: Harness) -> set:
    """Finder new-folder names on the Desktop. cmd+N in the Finder is the
    cheapest actuation with a durable, countable side effect."""
    found = set()
    for suffix in [""] + [f" {i}" for i in range(2, 60)]:
        path = f"Macintosh HD:Desktop Folder:untitled folder{suffix}"
        if h.request("stat", {"path": path}).get("exists"):
            found.add(suffix or "1")
    return found


def clear_desktop_untitled_folders(h: Harness) -> int:
    """Delete every `untitled folder*` on the Desktop.

    Trials must be INDEPENDENT. Left alone, this oracle accumulates: nine
    folders pile up on the Desktop over a run, so trial 12 is measured against a
    guest in a different state from trial 1, and the Finder's own behaviour
    (icon placement, inline-rename state, a crowded desktop) becomes a hidden
    variable. The famous `A-AAAAAAAA----------` sequence was measured under
    exactly that accumulation, so it could not distinguish "the verb stops
    working" from "this scenario poisons itself".

    Restoring state between trials is what makes the ceiling falsifiable.
    """
    removed = 0
    for name in desktop_untitled_folders(h):
        suffix = "" if name == "1" else f" {name}"
        try:
            h.request("delete",
                      {"path": f"Macintosh HD:Desktop Folder:untitled folder{suffix}"})
            removed += 1
        except Exception:
            pass
    return removed


# Control Manager part codes — Inside Macintosh, the Control Manager, and
# ControlDefinitions.h. Named rather than inlined because the wrong four
# numbers (10/11/12/13) are what made `ctlinvoke` look broken: the verb
# answered truthfully and the app's action procedure was handed a part its
# scroll bar has no meaning for, so nothing moved.
CTL_BUTTON_PART = 10            # inButton, a push button
CTL_UP_BUTTON_PART = 20         # inUpButton, a scroll bar's up arrow


def front_controls(agent: Agent) -> list:
    tree = agent.call("axtree", {"scope": "front"})
    return [c for w in (tree.get("windows") or []) for c in (w.get("controls") or [])]


def scroll_bar(agent: Agent) -> dict | None:
    """The visible, enabled control with the widest live range.

    Re-resolved on every use rather than cached: a ref is only meaningful
    against the tree it came from, and a trial that acts on a stale one is
    measuring the wrong thing.
    """
    live = [c for c in front_controls(agent)
            if c.get("visible") and c.get("enabled")
            and (c.get("max") or 0) > (c.get("min") or 0)]
    return max(live, key=lambda c: (c.get("max") or 0) - (c.get("min") or 0)) \
        if live else None


def scroll_value(agent: Agent):
    bar = scroll_bar(agent)
    return None if bar is None else bar.get("value")


def reset_scroll_to_bottom(agent: Agent) -> None:
    """One Return, so the trial starts from a known place.

    SimpleText scrolls to its insertion point, which is at the end of the
    document, so the bar lands at its MAXIMUM — the only position where an
    up-arrow is guaranteed to have somewhere to go. Without this the trials are
    not independent, and worse, a bar already at its minimum makes `inUpButton`
    a legitimate no-op that is indistinguishable from a broken verb.
    """
    agent.call("key", {"code": 36, "char": 13, "mods": 0})
    time.sleep(0.7)


def act_ctlinvoke_scroll(agent: Agent):
    bar = scroll_bar(agent)
    if bar is None:
        raise RuntimeError("no control with a live range is exposed")
    return agent.call("ctlinvoke",
                      {"ref": bar["ref"], "part": CTL_UP_BUTTON_PART})


def front_alerts(agent: Agent) -> list:
    """Modal dialog windows of the front app (`kind` 2 in the scene IR)."""
    tree = agent.call("axtree", {"scope": "front"})
    return [w for w in (tree.get("windows") or []) if w.get("kind") == 2]


def reset_open_alert(agent: Agent) -> bool:
    """cmd+W on a modified SimpleText document raises the save-changes alert.

    Cancel — the button the trial presses — puts the guest back exactly where
    it started, which is what makes these trials independent.
    """
    if front_alerts(agent):
        return True
    agent.call("key", {"code": 13, "char": 119, "mods": 256})    # cmd+W
    for _ in range(10):
        time.sleep(0.5)
        if front_alerts(agent):
            return True
    return False


def act_ctlinvoke_button(agent: Agent):
    alerts = front_alerts(agent)
    if not alerts:
        raise RuntimeError("no alert is present to press a button in")
    cancel = next((c for c in (alerts[-1].get("controls") or [])
                   if (c.get("title") or "").lower().startswith("cancel")), None)
    if cancel is None:
        raise RuntimeError("the alert exposes no Cancel button")
    return agent.call("ctlinvoke",
                      {"ref": cancel["ref"], "part": CTL_BUTTON_PART})


def front_window_titles(agent: Agent) -> list:
    """Window titles of the front app, via the agent's own perceive plane.
    Weaker than a filesystem oracle (same process reports both) but the only
    option for acts whose effect is purely on screen."""
    try:
        tree = agent.call("axtree", {"scope": "front"})
    except Exception:
        return []
    return [w.get("title") for w in (tree.get("windows") or [])]


# name: (description, act, oracle, settle_seconds, requires_front)
#
# requires_front is a PRECONDITION, enforced before a single trial runs. It
# exists because a case can be silently meaningless: cmd+N only creates a
# Desktop folder when the FINDER is frontmost, and running it against whatever
# app happened to be open reports a confident 0% actuation that says nothing
# about the verb. That exact mistake was made (2026-07-30) with Graphing
# Calculator in front. A harness that cannot verify its own premise must refuse
# to publish a number, so this one does.
CASES = {
    "key-cmd-n": (
        "cmd+N to the front Finder (keycode 45, mods 256 = cmdKey)",
        lambda a: a.call("key", {"code": 45, "char": 110, "mods": 256}),
        "folders",
        3.0,
        "Finder",
    ),
    "key-plain": (
        "plain 'n' keystroke, no modifiers (the PostEvent branch)",
        lambda a: a.call("key", {"code": 45, "char": 110, "mods": 0}),
        None,          # no durable side effect to check; reply rate only
        0.5,
        None,
    ),
    "click-desktop": (
        "click on empty desktop, then confirm the cursor moved",
        lambda a: a.call("click", {"x": 400, "y": 300}),
        "cursor",
        0.5,
        None,
    ),
    # The Portal's CONTROL_INVOKE, measured on BOTH halves of TrackControl,
    # because they succeed and fail independently. The tracking half runs the
    # app's action procedure during the call; the return-value half runs the
    # app's own mouse-down handler after it. A verb that drives one and not the
    # other is a half-working op, and the number has to be able to say which.
    "ctlinvoke-scroll": (
        "ctlinvoke inUpButton (20) on SimpleText's scroll bar - the TRACKING "
        "half, where the app's action procedure does the work",
        act_ctlinvoke_scroll,
        "ctlvalue",
        1.5,
        "SimpleText",
    ),
    "ctlinvoke-button": (
        "ctlinvoke inButton (10) on the save-changes alert's Cancel - the "
        "RETURN-VALUE half, which needs no action procedure at all",
        act_ctlinvoke_button,
        "alert",
        2.0,
        "SimpleText",
    ),
}


def front_app(agent: Agent) -> str | None:
    """Name of the frontmost process, from the guest's own process plane."""
    procs = agent.call("observe").get("processes", [])
    return next((p.get("name") for p in procs if p.get("front")), None)


def run_case(name: str, n: int, agent: Agent, h: Harness, pause: float) -> dict:
    desc, act, oracle, settle, requires_front = CASES[name]

    if requires_front is not None:
        actual = front_app(agent)
        if actual != requires_front:
            raise SystemExit(
                f"PRECONDITION FAILED for {name}: needs {requires_front!r} "
                f"frontmost, found {actual!r}. Refusing to measure — a case "
                f"whose oracle cannot see the effect reports a meaningless 0%. "
                f"Bring {requires_front!r} to the front and re-run.")
    replies = 0
    actuations = 0
    errors: dict[str, int] = {}
    seq: list[bool] = []

    print(f"\n=== {name}: {desc}")
    print(f"    N={n}")

    for i in range(n):
        before = None
        if oracle == "folders":
            # Reset to a known state so this trial is independent of the last.
            clear_desktop_untitled_folders(h)
            before = desktop_untitled_folders(h)
        elif oracle == "cursor":
            try:
                before = agent.call("mouseloc")
            except Exception:
                before = None
        elif oracle == "ctlvalue":
            reset_scroll_to_bottom(agent)
            before = scroll_value(agent)
        elif oracle == "alert":
            # Refuse to measure a trial whose premise did not hold, rather than
            # score it a failure: "the alert never opened" is a statement about
            # the SETUP, not about ctlinvoke.
            if not reset_open_alert(agent):
                raise SystemExit(
                    "PRECONDITION FAILED for ctlinvoke-button: cmd+W did not "
                    "raise the save-changes alert. The document must be "
                    "modified and SimpleText frontmost.")
            before = True

        replied = False
        try:
            act(agent)
            replied = True
            replies += 1
        except Exception as e:
            kind = type(e).__name__
            errors[kind] = errors.get(kind, 0) + 1

        time.sleep(settle)

        acted = False
        if oracle == "folders" and before is not None:
            acted = bool(desktop_untitled_folders(h) - before)
        elif oracle == "cursor" and before is not None:
            try:
                after = agent.call("mouseloc")
                acted = (after != before or after == {"x": 400, "y": 300})
            except Exception:
                acted = False
        elif oracle == "ctlvalue":
            # The oracle is the CONTROL'S OWN value, read back out of the
            # guest's tree — never the verb's `answered` flag, which only says
            # the app's TrackControl returned our part code.
            acted = (before is not None and scroll_value(agent) != before)
        elif oracle == "alert":
            acted = not front_alerts(agent)
        if oracle:
            seq.append(acted)
            if acted:
                actuations += 1

        # Per-trial marks, because the PATTERN carries more information than the
        # rate: an alternating sequence means state leaking between trials
        # (a stuck modifier, a queued partner event), while a random scatter
        # means a genuine race. A bare percentage hides that difference.
        if not replied:
            mark = "x"                      # no reply
        elif oracle is None:
            mark = "."                      # replied; nothing to check
        else:
            mark = "A" if seq[-1] else "-"  # actuated / replied but inert
        sys.stdout.write(mark)
        sys.stdout.flush()
        time.sleep(pause)

    print()
    if oracle:
        print(f"    sequence  {''.join('A' if a else '-' for a in seq)}")
    result = {
        "case": name,
        "n": n,
        "replies": replies,
        "reply_rate": replies / n if n else 0.0,
        "actuations": actuations if oracle else None,
        "actuation_rate": (actuations / n) if (oracle and n) else None,
        "errors": errors,
        "sequence": "".join("A" if a else "-" for a in seq) if oracle else None,
    }
    print(f"    reply     {replies}/{n} = {result['reply_rate']:.0%}")
    if oracle:
        print(f"    actuation {actuations}/{n} = {result['actuation_rate']:.0%}")
    if errors:
        print(f"    errors    {errors}")
    return result


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    ap.add_argument("--n", type=int, default=30,
                    help="trials per case (default 30; N=1 proves nothing here)")
    ap.add_argument("--case", action="append", choices=sorted(CASES),
                    help="repeatable; default is every case")
    ap.add_argument("--pause", type=float, default=0.4,
                    help="seconds between trials")
    ap.add_argument("--json", help="write the full result set here")
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})

    hello = agent.call("hello")
    print(f"agent v{hello['version']} build={hello['build']} "
          f"oracle={hello['oracleStatus']}")

    cases = args.case or sorted(CASES)
    results = [run_case(c, args.n, agent, h, args.pause) for c in cases]

    print("\n--- summary ---")
    for r in results:
        act = "n/a" if r["actuation_rate"] is None else f"{r['actuation_rate']:.0%}"
        print(f"{r['case']:16} reply {r['reply_rate']:.0%}  actuation {act}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"agent": hello, "results": results}, fh, indent=2)
        print(f"\nwrote {args.json}")

    # A rate below 100% on a verb the host will depend on is a failure, and the
    # exit status must say so — this harness exists to be believed.
    for r in results:
        if r["reply_rate"] < 1.0:
            sys.exit(f"FAIL: {r['case']} reply rate {r['reply_rate']:.0%}")
        if r["actuation_rate"] is not None and r["actuation_rate"] < 1.0:
            sys.exit(f"FAIL: {r['case']} actuation rate {r['actuation_rate']:.0%}")
    print("\nall measured rates 100%")


if __name__ == "__main__":
    main()
