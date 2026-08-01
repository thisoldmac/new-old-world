#!/usr/bin/env python3
"""Stage the mirror pieces onto a booted guest through the baked anchor worker.

AXPeek.bin      -> Macintosh HD:System Folder:Extensions:AXPeek   (loads at boot)
QDPeek.bin      -> Macintosh HD:System Folder:Extensions:QDPeek   (loads at boot)
mirror-agent.bin-> Macintosh HD:TimBotTu:mirror-dev:mirror-agent
mirror.port     -> beside the agent, so it binds the port the host forwarded

Run from spin-up.sh, which exports MIRROR_ANCHOR_PORT, MIRROR_EXT, MIRROR_AGENT.
Everything is verified after writing: a push that silently no-op'd, leaving a
config file unwritten, is exactly why the agent would bind nothing and look
wedged.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, ".."))       # this repo
LAB = os.path.abspath(os.path.join(MIRROR, ".."))        # the lab checkout
# The anchor harness client is a lab INSTRUMENT used to drive a deploy — it is
# not shipped and nothing under host/ or guest/ imports it (AGENTS.md).
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError

DEV = "Macintosh HD:TimBotTu:mirror-dev"
EXTENSIONS = "Macintosh HD:System Folder:Extensions"
GUEST_PORT = 1420          # must match mirror-agent's default + spin-up's hostfwd

ANCHOR_PORT = int(os.environ.get("MIRROR_ANCHOR_PORT", "1700"))
EXT = os.environ.get("MIRROR_EXT",
                     os.path.join(MIRROR, "guest/extensions/axpeek/build/AXPeek.bin"))
PTEXT = os.environ.get("MIRROR_PTEXT",
                       os.path.join(MIRROR, "guest/extensions/portal/build/Portal.bin"))
QDEXT = os.environ.get("MIRROR_QDEXT",
                       os.path.join(MIRROR, "guest/extensions/qdpeek/build/QDPeek.bin"))
AGENT = os.environ.get("MIRROR_AGENT",
                       os.path.join(MIRROR, "guest/app/build/mirror-agent.bin"))

h = Harness(host="127.0.0.1", port=ANCHOR_PORT, expect_backing={"worker"})
hello = h.request("hello", {})
assert hello["policyDigest"], hello
print("anchor hello: machine", hello["machineId"])


def ensure_dir(path):
    """Create every segment of an HFS path. The `mkdir` verb is FSpDirCreate,
    which makes ONE directory — no intermediate parents — and errors -48
    (dupFNErr) if the leaf already exists. So walk the chain, and treat only
    'already exists' as success. A swallowed failure here is exactly the bug
    that once left a config file unwritten."""
    parts = path.split(":")
    for i in range(2, len(parts) + 1):        # start at "Vol:first", grow down
        sub = ":".join(parts[:i])
        try:
            h.request("mkdir", {"path": sub})
        except HarnessError as e:
            msg = f"{e}".lower()
            if "-48" not in msg and "exist" not in msg and "dup" not in msg:
                raise
    st = h.request("stat", {"path": path})
    if not st.get("exists") or st.get("kind") != "folder":
        raise SystemExit(f"ensure_dir failed: {path} -> {st}")


def push_verified(path, blob, **want):
    """Push a MacBinary blob and prove it landed.

    The baked anchor worker's put channel finishes by stamping the file's
    catalog dates, and on this image that step fails with `catalog dates err
    -43` even though every byte arrived and the timestamps DID update
    (measured 2026-07-29 on mac99/os91-runner: rsrcSize and modified both
    correct afterwards). It is a lab-instrument quirk, not a failed deploy.

    So tolerate exactly that error — and then require the verify to pass
    anyway. Never tolerate it blindly: a swallowed push failure looks exactly
    like a successful one until the guest binds nothing."""
    try:
        h.push_stream(path, blob, overwrite=True, pipeline=1)
    except HarnessError as e:
        if "catalog dates" not in f"{e}":
            raise
        print(f"  [warn] {path.split(':')[-1]}: {e} "
              f"(known anchor quirk; proving the bytes landed instead)")
    verify(path, **want)


def verify(path, want_type=None, min_data=0, min_rsrc=0):
    st = h.request("stat", {"path": path})
    ok = (st.get("exists")
          and (st.get("dataSize") or 0) >= min_data
          and (st.get("rsrcSize") or 0) >= min_rsrc
          and (want_type is None or st.get("type") == want_type))
    tag = "OK " if ok else "BAD"
    print(f"  [{tag}] {path.split(':')[-1]:16} "
          f"type={st.get('type')} data={st.get('dataSize')} rsrc={st.get('rsrcSize')}")
    if not ok:
        raise SystemExit(f"stage verify failed for {path}: {st}")


# 1. Both INITs into Extensions. Their code lives in the RESOURCE fork, so a bad
#    push (wrong type, empty fork) would boot-load nothing at all.
#
#    AXPeek is the address oracle the AX plane cannot work without. QDPeek is the
#    QuickDraw op stream: without it the host has nothing telling it a window
#    repainted, so a captured interior freezes at its first image. Both are ours.
for _name, _path in (("AXPeek", EXT), ("QDPeek", QDEXT), ("Portal", PTEXT)):
    push_verified(f"{EXTENSIONS}:{_name}", open(_path, "rb").read(),
                  want_type="INIT", min_rsrc=1024)

# 2. The agent, plus its port file.
ensure_dir(DEV)
agent = open(AGENT, "rb").read()
push_verified(f"{DEV}:mirror-agent", agent, want_type="APPL", min_data=1024)

# The agent resolves mirror.port next to itself. Write it explicitly rather than
# leaning on the compiled-in default, so the file's absence can never be the
# silent reason a redeploy binds the wrong port.
line = f"{GUEST_PORT}\n"
h.request("write", {"path": f"{DEV}:mirror.port", "data": line,
                    "offset": 0, "truncate": True})
verify(f"{DEV}:mirror.port", want_type="TEXT", min_data=len(line))

print("staged OK — cold reboot to load AXPeek+QDPeek, then launch the agent")
