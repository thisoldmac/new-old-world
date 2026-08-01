#!/usr/bin/env python3
"""Lane G1's probe: menu titles, the `launch` verb, and the build stamp.

Three unrelated guest truths, each measured against GUEST STATE rather than a
verb's own return value:

  menus   dump every menu title and item title of the front app as RAW BYTES,
          so "leading NUL" is an observation and not an inference. Then assert
          that every item is addressable by its reported title.
  launch  launch a real application by path (and by name), and require its
          WINDOW to appear in `axtree` — `ok:true` from the verb proves only
          that LaunchApplication returned.
  stamp   report `hello`'s build stamp so a deploy can be confirmed.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/g1-probe.py --agent-port 1722 [--case menus|launch|stamp]

Shares trials.py's client shape deliberately: ONE persistent connection,
reused. A socket per request races the guest's accept and gets refused.
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
# Lab INSTRUMENT, exactly as trials.py uses it: the anchor worker resets state
# BETWEEN trials (it can send a quit Apple Event; this agent cannot). Nothing
# under host/ or guest/ imports it. Trials that are not independent measure a
# different machine each time — that is what manufactured the "~9 actuations
# per boot" ceiling.
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))


class GuestError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class Agent:
    """One persistent connection; `ok:false` is a reply, not a failure."""

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

    def call_raw(self, verb: str, args: dict | None = None, retries: int = 3):
        """Return the reply's raw BYTES (undecoded) plus the parsed object.

        Raw bytes matter here: a NUL inside a title arrives as the six ASCII
        characters `\\u0000`, and any lossy decode on the way would hide the
        very thing being measured.
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
                try:
                    text = line.decode("mac_roman")
                except Exception:
                    text = line.decode("utf-8", "replace")
                reply = json.loads(text)
                if not reply.get("ok"):
                    err = reply.get("error", {})
                    raise GuestError(err.get("code", "error"),
                                     err.get("message", ""))
                return line, reply.get("result", {})
            except GuestError:
                raise
            except Exception as e:
                last = e
                self._drop()
                time.sleep(1.5)
        raise last if last else RuntimeError("unreachable")

    def call(self, verb: str, args: dict | None = None, retries: int = 3):
        return self.call_raw(verb, args, retries)[1]

    def close(self) -> None:
        self._drop()


def front_app(a: Agent) -> dict:
    """`axtree scope=front` returns ONE app inline (front/windows/menus);
    `scope=all` returns an `apps` array of {process, windows, ...}. Two shapes,
    one reader."""
    return a.call("axtree", {"scope": "front"})


def case_stamp(a: Agent) -> int:
    hello = a.call("hello")
    print(f"  version={hello['version']} build={hello['build']}")
    print(f"  oracle={hello.get('oracle')} status={hello.get('oracleStatus')}")
    return 0


def case_menus(a: Agent) -> int:
    """Dump menu/item titles with their raw bytes, then assert addressability."""
    line, app = a.call_raw("axtree", {"scope": "front"})
    print(f"  front app: {(app.get('front') or {}).get('name')!r}")
    bad = 0
    for menu in app.get("menus", []):
        title = menu.get("title", "")
        print(f"  menu id={menu.get('id')} title={title!r} "
              f"bytes={[hex(ord(c)) for c in title][:6]}")
        for item in menu.get("items", []):
            t = item.get("title", "")
            nul = t.count("\x00")
            if nul:
                bad += 1
            pref = item.get("titleNulPrefix")
            print(f"      {item.get('index'):>2} {t!r}"
                  f"{f'   [{pref} leading NUL(s) dropped]' if pref else ''}"
                  f"{'  <-- NUL IN TITLE' if nul else ''}")
    # The raw frame is the primary evidence:  in the wire bytes.
    wire_nuls = line.count(b"\\u0000")
    print(f"  items whose reported title contains a NUL: {bad}")
    print(f"  '\\u0000' escapes in the raw axtree frame:   {wire_nuls}")
    return 0 if bad == 0 and wire_nuls == 0 else 1


def windows_of(a: Agent, name: str) -> list:
    """Windows the GUEST reports for an app — the launch oracle.

    `scope=all` rows are {process:{name,...}, windows:[...]} and an app whose
    AXPeek sample is missing carries an `error` instead, which is not the same
    as having no windows.
    """
    tree = a.call("axtree", {"scope": "all"})
    for app in tree.get("apps", []):
        if (app.get("process") or {}).get("name") == name:
            return app.get("windows") or []
    return []


def running(a: Agent, name: str) -> bool:
    return any(p.get("name") == name
               for p in a.call("observe").get("processes", []))


def quit_app(a: Agent, name: str, timeout: float = 25.0) -> bool:
    """Bring an app to the front and send cmd-Q; confirm it left `observe`.

    Keycode 12 is 'q' and mods 256 is cmdKey (Inside Macintosh: Toolbox
    Essentials, Event Manager — the same chart trials.py takes 45='n' from).
    The oracle is the process list, never the key verb's own reply.
    """
    psn = next((p for p in a.call("observe")["processes"]
                if p["name"] == name), None)
    if psn is None:
        return True
    a.call("activate", {"serialHi": psn["serialHi"], "serialLo": psn["serialLo"]})
    time.sleep(1.0)
    a.call("key", {"code": 12, "char": 113, "mods": 256})
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(1.0)
        if not running(a, name):
            return True
    return False


def case_launch(a: Agent, path: str, app_name: str, by_name: str | None,
                trials: int, anchor_port: int | None) -> int:
    """Oracle = the application's WINDOW appearing in axtree. Never ok:true.

    Trials are INDEPENDENT: each one starts with the application not running.
    Reset between trials is activate + cmd-Q through the agent's own verbs (the
    anchor worker's `apple-event` is out of this session's scope), and it is
    confirmed in guest state — the app leaving `observe` — before the next
    trial starts. Launching an app that is already running is a DIFFERENT act
    (the Process Manager just brings it to the front), so a trial that skipped
    the reset would measure nothing.
    """

    replies = actuations = 0
    for i in range(trials):
        if running(a, app_name):
            if not quit_app(a, app_name):
                print(f"  [{i}] PRECONDITION FAILED: could not quit "
                      f"{app_name} to make this trial independent")
                return 1
        before = windows_of(a, app_name)
        args = {"name": by_name} if by_name else {"path": path}
        try:
            res = a.call("launch", args)
            replies += 1
            reported = res.get("launched")
        except GuestError as e:
            print(f"  [{i}] launch refused: {e}")
            replies += 1                # an honest refusal IS a reply
            reported = False

        found, t0 = None, time.time()
        while time.time() - t0 < 30:
            wins = windows_of(a, app_name)
            if len(wins) > len(before):
                found = wins
                break
            time.sleep(1.0)
        if found:
            actuations += 1
            print(f"  [{i}] reported={reported}  WINDOW "
                  f"{[w.get('title') for w in found]}  "
                  f"({time.time() - t0:.1f}s)")
        else:
            print(f"  [{i}] reported={reported}  NO WINDOW after 30 s")

    print(f"  launch reply {replies}/{trials}, "
          f"actuation {actuations}/{trials}")
    return 0 if actuations == trials else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--case", default="all",
                    choices=["all", "menus", "launch", "stamp"])
    ap.add_argument("--path",
                    default="Macintosh HD:Applications:SimpleText")
    ap.add_argument("--app-name", default="SimpleText")
    ap.add_argument("--by-name", default=None,
                    help="launch by name instead of path")
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--anchor-port", type=int, default=None,
                    help="lab anchor worker; resets the target between trials")
    args = ap.parse_args()

    a = Agent(args.agent_port)
    rc = 0
    try:
        if args.case in ("all", "stamp"):
            print("== stamp ==")
            rc |= case_stamp(a)
        if args.case in ("all", "menus"):
            print("== menus ==")
            rc |= case_menus(a)
        if args.case in ("all", "launch"):
            print("== launch ==")
            rc |= case_launch(a, args.path, args.app_name, args.by_name,
                              args.trials, args.anchor_port)
    finally:
        a.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
