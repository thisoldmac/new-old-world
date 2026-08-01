#!/usr/bin/env python3
"""Lane H2: exercise the AGENT-facing surface, not just the core.

`mirror.find {kind:"windowItem"}` and `mirror.act.open {windowItem}` are the
methods an agent actually calls. Implementing them and measuring only the core
path underneath would be exactly the half-truth this project keeps paying for,
so they get their own live check.

The oracle for the open is the guest: a NEW Finder window whose name is the
folder we opened, read back from the Finder.
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
MIRROR = HERE.parent
sys.path.insert(0, str(HERE))
from h2probe import ports                                  # noqa: E402
from h2calib import sc                                     # noqa: E402

APP = MIRROR / "host/MirrorKit/.build/debug/MirrorApp"
SOCK = "/tmp/claude-501/h2-mirror-serve.sock"


def call(method, params=None):
    """One request per connection, 4-byte big-endian length prefix, then a
    half-close — the framing `Serve.readFrame` expects."""
    body = json.dumps({"method": method, "params": params or {}}).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall(len(body).to_bytes(4, "big") + body)
    s.shutdown(socket.SHUT_WR)

    def readn(n):
        out = b""
        while len(out) < n:
            chunk = s.recv(n - len(out))
            if not chunk:
                raise RuntimeError("short read")
            out += chunk
        return out

    n = int.from_bytes(readn(4), "big")
    reply = readn(n)
    s.close()
    return json.loads(reply.decode("utf-8", "replace"))


def scroll_to_top(clicks=12):
    from h2probe import agent_call                          # noqa: PLC0415
    tree = agent_call("axtree", {"scope": "all"})["result"]
    for app in tree.get("apps", []):
        for w in app.get("windows", []):
            for c in w.get("controls", []):
                r = c.get("rect")
                if (r and c.get("visible")
                        and (r[3] - r[1]) > (r[2] - r[0])
                        and w.get("title") == "TimBotTu"):
                    x, y = (r[0] + r[2]) // 2, r[1] + 8   # the UP arrow
                    for _ in range(clicks):
                        agent_call("click", {"x": x, "y": y, "count": 1})
                        time.sleep(0.25)
                    time.sleep(1.0)
                    return


def main():
    Path(SOCK).unlink(missing_ok=True)
    sc('tell application "Finder"\nclose every window\nend tell')
    time.sleep(1)
    sc('tell application "Finder"\nopen folder "Macintosh HD:TimBotTu"\n'
       'end tell')
    time.sleep(2)
    # The Finder remembers a folder's scroll position across close/open, so
    # reopening is NOT a reset. Walk the scrollbar back to the top with the up
    # arrow so the folders at the head of the layout are on screen.
    scroll_to_top()

    _, agent_port = ports()
    srv = subprocess.Popen(
        [str(APP), "--host", "127.0.0.1", "--port", str(agent_port),
         "--machine", "mac99", "--scope", "all",
         "--qmp", str(MIRROR / "run/qmp.sock"), "--serve", SOCK],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(40):
            if Path(SOCK).exists():
                break
            time.sleep(0.5)
        # From here on, NOTHING else may talk to the guest: MirrorApp owns the
        # agent's single connection.
        att = call("mirror.attach",
                   {"planes": ["semantic", "tracking"]})
        session = att["result"]["session"]
        print("attach:", att["result"].get("irVersion"), "planes granted")

        found = call("mirror.find",
                     {"session": session, "kind": "windowItem"})["result"]
        items = found["matches"]
        print(f"find windowItem: {len(items)} matches, "
              f"{sum(m['actionable'] for m in items)} actionable")
        for m in items[:4]:
            print("   ", json.dumps(m))

        target = next((m for m in items
                       if m["actionable"] and m["itemKind"] == "folder"), None)
        if target is None:
            print("no actionable FOLDER item — open test skipped")
            return
        name = target["name"]

        # A folder is the target on purpose: opening one makes a new Finder
        # window whose NAME is the oracle.
        #
        # The oracle is read through `mirror.find {kind:"window"}`, NOT through
        # a second AppleScript connection to the guest: the agent serves ONE
        # connection serially, and opening a second client while MirrorApp
        # holds its own resets the first. (This harness did exactly that and
        # spent a round wrongly blaming the act path.) The window list comes
        # from AXPeek's WindowList — guest state, and not act.open's own report.
        # `mirror.scene` with maxAgeMs 0, NOT `mirror.find`: find answers from
        # the last scene it happens to hold, so it cheerfully reported the
        # pre-open window list and made a successful open look like a failure.
        def window_titles():
            got = call("mirror.scene", {"session": session, "maxAgeMs": 0})
            return sorted(w["title"] for w in got["result"]["scene"]["windows"])

        before = window_titles()
        r = call("mirror.act.open", {"session": session, "windowItem": name})
        print("act.open:", json.dumps(r.get("result", r)))
        time.sleep(3)
        after = window_titles()
        print(f"windows before={before} after={after}")
        print("OPENED THE RIGHT FOLDER:", name in after and name not in before)

        # And the refusal path: a name in no window must not be best-efforted.
        bad = call("mirror.act.open",
                   {"session": session, "windowItem": "no-such-file-xyz"})
        print("bogus name ->", json.dumps(bad.get("error", bad)))
    finally:
        srv.terminate()
        try:
            out = srv.stdout.read()
            if out:
                print("--- MirrorApp said ---")
                print(out[-2000:])
        except Exception:                                   # noqa: BLE001
            pass
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()


if __name__ == "__main__":
    main()
