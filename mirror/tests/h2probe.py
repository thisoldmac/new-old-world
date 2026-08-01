"""Lane H2 probe client: talk to the mirror agent and to the lab anchor worker.

Two sockets, deliberately:

- the **agent** (mirror's own guest app) speaks the mirror wire and is the
  thing we are building; it serves ONE connection serially, so every request
  reconnects and retries (its contract — see tools/spin-up.sh).
- the **anchor** is the lab's baked worker. It already has a `script` verb,
  which is how this lane learned what the Finder reports *before* the mirror
  agent grew its own. It is an instrument, never a shipped dependency
  (AGENTS.md > "TimBotTu is the lab, not a dependency").

Guest JSON carries raw MacRoman bytes that are not valid UTF-8 — every decode
here is repair-decoding, or JSONSerialization/json refuses the line.
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

RUN = Path(__file__).resolve().parent.parent / "run"


def ports():
    anchor, agent = RUN.joinpath("ports").read_text().split()
    return int(anchor), int(agent)


def qmp_path():
    return str(RUN / "qmp.sock")


def agent_call(verb, args=None, port=None, timeout=40, tries=6):
    """One request to the mirror agent. Reconnect-and-retry is the contract."""
    if port is None:
        port = ports()[1]
    req = {"proto": 1, "id": 1, "verb": verb}
    if args:
        req.update(args)
    last = None
    for _ in range(tries):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
            try:
                s.sendall((json.dumps(req) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
            finally:
                s.close()
            if not buf:
                raise RuntimeError("closed without data")
            return json.loads(buf.decode("utf-8", "replace"))
        except Exception as e:      # noqa: BLE001 - transport, retried
            last = e
            time.sleep(1.0)
    raise last


def anchor():
    """The lab harness client, bound to this session's anchor port."""
    lab = str(Path.home() / "Lab/Code/timbottu/mcp-classic")
    if lab not in sys.path:
        sys.path.insert(0, lab)
    from timbottu_mcp_classic.harness import Harness   # noqa: PLC0415
    return Harness(host="127.0.0.1", port=ports()[0], expect_backing={"worker"})


def script(src, timeout_ms=20000, h=None):
    """Run AppleScript through the ANCHOR (the instrument) and return its text.

    The standing hazard: a whole-disk Finder search wedged a real machine for
    ~12 minutes (lab finding, 2026-07-05). Every script this lane sends is
    scoped to a NAMED window or a NAMED item — never a search.
    """
    h = h or anchor()
    r = h.request("script", {"source": src, "timeoutMs": timeout_ms})
    return r


def qmp(*args):
    lab = str(Path.home() / "Lab/Code/timbottu")
    return subprocess.run([f"{lab}/tools/qmp", qmp_path(), *args],
                          capture_output=True, text=True)
