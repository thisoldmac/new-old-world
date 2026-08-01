#!/usr/bin/env python3
"""Install the NOW Extension (and, optionally, the PowerPC guest) onto a
booted emulator guest, through the lab's baked anchor worker.

    NOW_ANCHOR_PORT=1702 tools/stage-ext.py

    NowExt.bin  -> Macintosh HD:System Folder:Extensions:NOW Extension
    the app     -> Macintosh HD:TimBotTu:now-dev:New Old World

THE GAP THIS CLOSES. `scripts/build-guests` builds `ext/` and, until this
file, nothing in the repository deployed it. Three of NOW's four planes
(P1 anchors, P3 content, P4 act) live in that INIT, so `qdtrace` answered
content-plane-absent on every machine that has ever existed and
`actselftest` — the act plane's ONLY ABI oracle, and a hard precondition
because a wrong trap ABI does not crash, it lies — could not be run at
all.

WHAT IT IS AND IS NOT. This is an EMULATOR instrument, and the anchor
worker it drives is a lab tool from the parent TimBotTu checkout that NOW
neither ships nor imports from any of its own sources. It is the
counterpart to `scripts/deploy-68k`, which puts an application on a real
Macintosh over FTP; nothing here has run on physical hardware and this
file is not a path to doing so.

THE FIVE THINGS THAT GO WRONG, each of which the mirror repository's
tools/stage-agent.py already paid for and this inherits:

  * AN INIT LOADS AT BOOT ONLY, and OS 9 ignores a soft power-down. This
    script stages; it does NOT reboot. `scripts/spin-up-ppc` performs the
    hard QMP quit and relaunch, and re-verifies afterwards. A stage
    without that cold reboot leaves the OLD extension resident and every
    result attributed to the new one.

  * BELIEVING A PUSH. Verification is by FORK SIZE and Finder type, read
    back off the guest — never the exit code of the push. An INIT's code
    is in the RESOURCE fork, so `min_rsrc` is the assertion that matters:
    a file with the right name and an empty resource fork boot-loads
    nothing whatever.

  * `catalog dates err -43` DURING A PUSH IS A KNOWN ANCHOR QUIRK, not a
    failed deploy. Measured 2026-07-29 on mac99/os91-runner (mirror
    repo): every byte arrives and the timestamps do update. So exactly
    that error is tolerated — and the fork-size verify is then REQUIRED
    to pass anyway. Tolerating it blindly would make a real failure look
    identical to a success right up until the guest reports the plane
    absent.

  * `mkdir` IS FSpDirCreate: one level, no intermediate parents, and -48
    when the leaf already exists. Walk the chain, and treat only
    "already exists" as success.

  * OVERWRITE IS NOT OPTIONAL. A clone of a base image that already
    carries a previous NOW build dies on `exists: file exists` after
    every earlier push succeeded, which reads exactly like a deploy
    failure and is not one.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = os.path.abspath(os.path.join(HERE, ".."))
# The lab checkout that owns the emulator and the anchor client. Two roots,
# and they are not the same: NOW owns the artifacts, the lab owns the
# instruments. Nothing under now-guest-*/ or now-host/ imports this.
LAB = os.environ.get("NOW_LAB_ROOT", os.path.abspath(os.path.join(NOW, "..")))
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

EXTENSIONS = "Macintosh HD:System Folder:Extensions"
DEV = os.environ.get("NOW_GUEST_DIR", "Macintosh HD:TimBotTu:now-dev")
EXT_NAME = os.environ.get("NOW_EXT_NAME", "NOW Extension")
APP_NAME = os.environ.get("NOW_APP_NAME", "New Old World")

ANCHOR_PORT = int(os.environ.get("NOW_ANCHOR_PORT", "1700"))
EXT_BIN = os.environ.get("NOW_EXT_BIN")          # required
APP_BIN = os.environ.get("NOW_APP_BIN")          # optional

if not EXT_BIN or not os.path.isfile(EXT_BIN):
    raise SystemExit(
        "stage-ext: set NOW_EXT_BIN to the built NowExt.bin "
        "(scripts/build-guests 68k builds it)")

h = Harness(host="127.0.0.1", port=ANCHOR_PORT, expect_backing={"worker"})
hello = h.request("hello", {})
if not hello.get("policyDigest"):
    raise SystemExit(f"anchor did not answer a usable hello: {hello}")
print(f"anchor hello: machine {hello.get('machineId')}")


def ensure_dir(path):
    """Create every segment of an HFS path.

    `mkdir` is FSpDirCreate: ONE directory, no parents, -48 when the leaf
    exists. So walk the chain and treat only 'already exists' as success —
    a swallowed failure here leaves the app staged nowhere."""
    parts = path.split(":")
    for i in range(2, len(parts) + 1):
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


def verify(path, want_type=None, min_data=0, min_rsrc=0):
    """Read the file back off the guest and judge it by fork size.

    The guest is the oracle, not the push. `min_rsrc` is the load-bearing
    one for the INIT: its code lives in the resource fork."""
    st = h.request("stat", {"path": path})
    ok = (st.get("exists")
          and (st.get("dataSize") or 0) >= min_data
          and (st.get("rsrcSize") or 0) >= min_rsrc
          and (want_type is None or st.get("type") == want_type))
    print(f"  [{'OK ' if ok else 'BAD'}] {path.split(':')[-1]:18} "
          f"type={st.get('type')} creator={st.get('creator')} "
          f"data={st.get('dataSize')} rsrc={st.get('rsrcSize')}")
    if not ok:
        raise SystemExit(f"stage verify failed for {path}: {st}")
    return st


def push_verified(path, blob, **want):
    try:
        h.push_stream(path, blob, overwrite=True, pipeline=1)
    except HarnessError as e:
        # See the header: exactly this string, and nothing else, is the
        # measured anchor quirk. The verify below still has to pass.
        if "catalog dates" not in f"{e}":
            raise
        print(f"  [warn] {path.split(':')[-1]}: {e} "
              f"(known anchor quirk; proving the bytes landed instead)")
    return verify(path, **want)


# 1. The extension. Type INIT / creator 'NOWx' is the IDENTITY the guest's
#    own peek.c scans the Extensions folder for (it matches on type and
#    creator, never on filename), so both are asserted here.
print(f"== stage {EXT_NAME} ==")
st = push_verified(f"{EXTENSIONS}:{EXT_NAME}", open(EXT_BIN, "rb").read(),
                   want_type="INIT", min_rsrc=1024)
if st.get("creator") not in (None, "NOWx"):
    raise SystemExit(
        f"staged extension has creator {st.get('creator')!r}, not 'NOWx' — "
        f"the guest's peek.c would not see it in the Extensions folder")

# 2. The application, if one was given. It is what asks the extension
#    anything: the INIT publishes a table, and only a NOW process reads it.
if APP_BIN:
    if not os.path.isfile(APP_BIN):
        raise SystemExit(f"NOW_APP_BIN does not exist: {APP_BIN}")
    print(f"== stage {APP_NAME} ==")
    ensure_dir(DEV)
    push_verified(f"{DEV}:{APP_NAME}", open(APP_BIN, "rb").read(),
                  want_type="APPL", min_data=1024)

print("staged. COLD reboot required: an INIT loads at boot only, and this "
      "script has not rebooted anything.")
