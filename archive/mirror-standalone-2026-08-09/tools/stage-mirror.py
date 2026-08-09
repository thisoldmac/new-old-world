"""Stage the live-mirror guest stack via the anchor (host 1700).

AXPeek.bin + QDPeek.bin -> System Folder:Extensions (INITs; load at cold boot).
tbt-worker.bin (toolkit) + worker.session -> TimBotTu:mirror-dev, launched on
guest 1410 (host 1710) after the cold reboot. Worker scope = the mirror's needs:
axtree (windows/menus), list (desktop icons), video (resolution), script
(finder folder/disk resolution), key/type/click + mouseloc (input), qdtrace
(content plane), capture/screenshot/observe/launch/activate.

Run standalone or via spin-up.sh. Paths derive from this file's location.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, ".."))       # this repo
LAB = os.environ.get("MIRROR_LAB_ROOT") or ""
if not LAB:
    # Walk up for the checkout that actually carries the instruments: the
    # parent stopped being the lab when Mirror was vendored under NOW.
    _p = os.path.abspath(os.path.join(MIRROR, ".."))
    while _p != "/" and not os.path.isdir(os.path.join(_p, "mcp-classic")):
        _p = os.path.dirname(_p)
    LAB = _p        # the lab checkout
# The anchor harness client is a lab INSTRUMENT, used to drive a deploy — it is
# not shipped and not imported by anything under host/ or guest/ (AGENTS.md).
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError

DEV = "Macintosh HD:TimBotTu:mirror-dev"
# spin-up.sh picks a free anchor port and exports it; default 1700 standalone.
ANCHOR_PORT = int(os.environ.get("MIRROR_ANCHOR_PORT", "1700"))
h = Harness(host="127.0.0.1", port=ANCHOR_PORT, expect_backing={"worker"})
hello = h.request("hello", {})
assert hello["policyDigest"], hello
print("anchor hello: machine", hello["machineId"])


def ensure_dir(path):
    """Create every segment of an HFS path. The `mkdir` verb is FSpDirCreate,
    which makes ONE directory — no intermediate parents — and errors -48
    (dupFNErr) if the leaf already exists. So walk the chain, and treat only
    'already exists' as success. A swallowed failure here is exactly the bug
    that left worker.session unwritten."""
    parts = path.split(":")
    for i in range(2, len(parts) + 1):        # start at "Vol:first", grow down
        sub = ":".join(parts[:i])
        try:
            h.request("mkdir", {"path": sub})
        except HarnessError as e:
            # -48 / dupFNErr / "exists" == already there == fine; else re-raise.
            msg = f"{e}".lower()
            if "-48" not in msg and "exist" not in msg and "dup" not in msg:
                raise
    # Verify the leaf is actually a directory now.
    st = h.request("stat", {"path": path})
    if not st.get("exists") or st.get("kind") != "folder":
        raise SystemExit(f"ensure_dir failed: {path} -> {st}")


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


# 1. INITs into Extensions (code lives in the resource fork). Verify each lands
#    as a real INIT — a bad push (wrong type/empty fork) would boot-load nothing.
#    AXPeek is ours; QDPeek (the content plane) is still the lab's.
INIT_SOURCES = {
    "AXPeek": os.path.join(MIRROR, "guest", "extension", "build", "AXPeek.bin"),
    "QDPeek": os.path.join(LAB, "qdpeek", "build", "QDPeek.bin"),
}
for name, path in INIT_SOURCES.items():
    blob = open(path, "rb").read()
    ext = f"Macintosh HD:System Folder:Extensions:{name}"
    h.push_stream(ext, blob, overwrite=True, pipeline=1)
    verify(ext, want_type="INIT", min_rsrc=1024)

# 2. toolkit worker + session. Create the full folder chain first (mkdir makes
#    no intermediates), then push + verify.
ensure_dir(DEV)
worker = open(os.path.join(LAB, "worker", "build-ppc-toolkit",
                           "tbt-worker.bin"), "rb").read()
h.push_stream(f"{DEV}:tbt-worker", worker, overwrite=True, pipeline=1)
verify(f"{DEV}:tbt-worker", want_type="APPL", min_data=1024)

# The scope the mirror actually exercises. A missing verb reads back as
# `denied: verb not in this session's scope` — which looks nothing like the
# feature it breaks, so keep this in sync with what MirrorKit calls:
#   perceive:  axtree list video observe gestalt
#   read:      read script stat  (script resolves Finder folder paths)
#   input:     key type click mouseloc activate launch apple-event
#   actuate:   axdo                (control clicks — the symmetry verb)
#   content:   qdtrace capture screenshot
#   pager:     fetch close         (REQUIRED by capture/islands and any download)
#   lifecycle: shutdown            (restart the worker without a guest reboot)
# Historical bite (2026-07-17): axdo/fetch/close were omitted, so a fresh
# spin-up could neither click a control nor drain a pixel-island capture.
MIRROR_TOOLS = (
    "axtree,axdo,list,video,observe,gestalt,read,script,"
    "key,type,click,mouseloc,activate,launch,apple-event,"
    "qdtrace,capture,screenshot,fetch,close,shutdown"
)
session = {
    "id": "mac99-mirror",
    "machineId": hello["machineId"],
    "generation": 1,
    "port": 1410,
    "created": 0,
    "deadline": 2000000000,
    "build": "toolkit",
    "owner": "claude-mirror",
    "purpose": "live-mirror",
    "tools": MIRROR_TOOLS,
    "policyId": hello["policyId"],
    "policyRevision": hello["policyRevision"],
    "policyDigest": hello["policyDigest"],
}
line = json.dumps(session, separators=(",", ":")) + "\n"
h.request("write", {"path": f"{DEV}:worker.session", "data": line,
                    "overwrite": True})
# Verify the session actually landed with the expected byte count — the write
# that silently no-op'd is the whole reason the worker never bound its port.
want = len(line.encode("mac-roman", "replace"))
verify(f"{DEV}:worker.session", want_type="TEXT", min_data=want)
print("staged OK — cold reboot to load AXPeek+QDPeek, then launch the worker")
