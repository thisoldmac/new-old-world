#!/usr/bin/env python3
"""Protocol-layer conformance for the agent-facing mirror service.

Where mirror-service-e2e.py drives a real task through the fifteen methods,
this exercises the WIRE CONTRACT edges (mirror-service-ipc.toml) that a task
flow never hits: framing limits, one-request-per-connection, malformed frames,
session gating, and the error-code vocabulary. It needs the same running
service but touches the guest only incidentally (one attach), so it is cheap
and deterministic.

    python3 mirror-service-protocol-test.py <path-to-mirror.sock>
"""
import json
import os
import socket
import struct
import sys


class Conn:
    """One connection = one request, per the contract. Exposes the raw frame
    so tests can send malformed bytes the JSON client would never produce."""
    def __init__(self, sock_path):
        self.dir, self.base = os.path.split(sock_path)

    def _connect(self):
        cwd = os.getcwd()
        try:
            os.chdir(self.dir)                       # sun_path length workaround
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(self.base)
        finally:
            os.chdir(cwd)
        return s

    def _recv_reply(self, s):
        hdr = b""
        while len(hdr) < 4:
            c = s.recv(4 - len(hdr))
            if not c:
                return None
            hdr += c
        n = struct.unpack(">I", hdr)[0]
        body = b""
        while len(body) < n:
            c = s.recv(min(65536, n - len(body)))
            if not c:
                return None
            body += c
        return json.loads(body)

    def raw(self, framed, half_close=True, trailer=b""):
        """Send an already-framed payload (+ optional trailer bytes), return
        the decoded reply or None on EOF-without-reply."""
        s = self._connect()
        s.sendall(framed + trailer)
        if half_close:
            s.shutdown(socket.SHUT_WR)
        try:
            return self._recv_reply(s)
        finally:
            s.close()

    def call(self, method, **params):
        body = json.dumps({"method": method, "params": params},
                          separators=(",", ":"), sort_keys=True).encode()
        return self.raw(struct.pack(">I", len(body)) + body)


def main(sock):
    c = Conn(sock)
    P, F = [], []

    def check(name, cond, detail=""):
        (P if cond else F).append(name)
        print(f"  {'PASS' if cond else 'FAIL'}  {name}"
              + (f"  — {detail}" if detail else ""))

    def ecode(reply):
        return (reply or {}).get("error", {}).get("code")

    # ---- framing -------------------------------------------------------
    # length header claims more than the max frame -> bad_request, and the
    # oversized length is refused on the HEADER (before the body is read), so
    # a hostile length never drives a giant allocation.
    r = c.raw(struct.pack(">I", 1_048_577) + b"x")
    check("oversized length header -> bad_request (refused pre-alloc)",
          ecode(r) == "bad_request", f"code={ecode(r)}")

    # zero-length frame -> bad_request.
    r = c.raw(struct.pack(">I", 0))
    check("zero-length frame -> bad_request", ecode(r) == "bad_request",
          f"code={ecode(r)}")

    # well-framed but not JSON -> bad_request.
    junk = b"not json at all"
    r = c.raw(struct.pack(">I", len(junk)) + junk)
    check("non-JSON frame -> bad_request", ecode(r) == "bad_request",
          f"code={ecode(r)}")

    # valid JSON but no `method` key -> bad_request.
    body = json.dumps({"params": {}}).encode()
    r = c.raw(struct.pack(">I", len(body)) + body)
    check("frame missing `method` -> bad_request", ecode(r) == "bad_request")

    # one request per connection: trailing bytes past the frame -> bad_request.
    body = json.dumps({"method": "mirror.status", "params": {}}).encode()
    r = c.raw(struct.pack(">I", len(body)) + body, trailer=b"EXTRA")
    check("trailing bytes past the frame -> bad_request",
          ecode(r) == "bad_request", f"code={ecode(r)}")

    # a clean status frame still works from the same server (control).
    r = c.call("mirror.status")
    check("clean mirror.status after malformed frames still ok",
          (r or {}).get("ok") is True,
          f"worker healthy={r['result']['worker']['healthy']}" if r and r.get("ok") else "")

    # ---- method + session vocabulary -----------------------------------
    r = c.call("mirror.status")     # no session needed
    check("status needs no session", (r or {}).get("ok") is True)

    r = c.call("mirror.scene", session="bogus")
    check("perceive with a bogus session -> no_session",
          ecode(r) == "no_session", f"code={ecode(r)}")

    r = c.call("mirror.act.key", key="escape")   # no session at all
    check("act with no session -> no_session", ecode(r) == "no_session")

    r = c.call("mirror.nope", session="bogus")
    # unknown method behind the session gate reports no_session first (the
    # session check precedes the method switch) — documents dispatch order.
    check("unknown method w/o session -> no_session (gate precedes switch)",
          ecode(r) == "no_session", f"code={ecode(r)}")

    # ---- a real session, then unknown-method + plane vocabulary --------
    a = c.call("mirror.attach", target="default", planes=["semantic"])
    ok = a and a.get("ok")
    sess = a["result"]["session"] if ok else None
    check("attach (semantic only) grants exactly semantic",
          ok and a["result"]["granted"] == ["semantic"],
          f"irVersion={a['result']['irVersion']}" if ok else str(a))

    if sess:
        r = c.call("mirror.nope", session=sess)
        check("unknown method WITH a session -> unknown_method",
              ecode(r) == "unknown_method", f"code={ecode(r)}")

        r = c.call("mirror.act.window", session=sess, window="x", op="close")
        check("tracking act on a semantic-only session -> plane_not_granted",
              ecode(r) == "plane_not_granted", f"code={ecode(r)}")

        # attach reply pins the IR version the consumer must gate on.
        check("attach reply carries irVersion for the compat gate",
              isinstance(a["result"].get("irVersion"), int))

        c.call("mirror.detach", session=sess)
        # detach releases: a follow-up act on the released session -> no_session.
        r = c.call("mirror.act.key", session=sess, key="escape")
        check("act after detach -> no_session", ecode(r) == "no_session")

    print(f"\n===== mirror service protocol: {len(P)} passed, {len(F)} failed =====")
    if F:
        print("  FAILURES:", F)
    return 0 if not F else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "mirror.sock"))
