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

THE OPTIONAL MIRROR BUNDLE.

    NOW_STAGE_MIRROR=1 NOW_ANCHOR_PORT=1702 tools/stage-ext.py

    AXPeek/QDPeek/Portal -> Macintosh HD:System Folder:Extensions
    mirror-agent         -> Macintosh HD:TimBotTu:mirror-dev:mirror-agent
    mirror.port          -> beside it, naming 1420

Off unless asked for, because Mirror is a SEPARATE application that
happens to run on the same Macintosh and most NOW guests do not want it:
three resident 68K INITs is not a thing to install on a machine by
default. What it enables is NOW's own Mirror page having anything to
report - it reads the three Gestalt selectors and walks for that agent -
and a host Mirror instance having a guest to dial through the 1420
forward `scripts/spin-up-ppc` already opens.

`mirror.port` IS PART OF THE BUNDLE AND NOT A DETAIL. Mirror's agent
reads it once at launch to learn which port to bind; on 2026-08-02 a
guest whose file carried a stale port from the base image ran an agent
that answered nobody, while NOW's page said "Running" about it. So the
file is WRITTEN, with `overwrite`, rather than left to whatever the base
image had - Mirror's own tools/stage-agent.py records that a missing
overwrite made every fresh clone fail on that one line AFTER all pushes
had succeeded, which reads like a deploy failure and is not one.

`scripts/spin-up-ppc` needs no flag: it invokes this script with an
environment prefix, so NOW_STAGE_MIRROR and NOW_MIRROR_DIR pass straight
through, and its cold reboot is the same reboot the Mirror INITs need.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = os.path.abspath(os.path.join(HERE, ".."))
# The lab checkout that owns the emulator and the anchor client. Two roots,
# and they are not the same: NOW owns the artifacts, the lab owns the
# instruments. Nothing under now-guest-*/ or now-host/ imports this.
# Normally NOW's parent — but not from a git worktree, which sits several
# levels deeper and whose parent has no tools/ in it at all. Walk up to the
# checkout that has the instruments.
LAB = os.environ.get("NOW_LAB_ROOT")
if not LAB:
    LAB = NOW
    while LAB != "/" and not os.path.isdir(os.path.join(LAB, "mcp-classic")):
        LAB = os.path.dirname(LAB)
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

EXTENSIONS = "Macintosh HD:System Folder:Extensions"
DEV = os.environ.get("NOW_GUEST_DIR", "Macintosh HD:TimBotTu:now-dev")
EXT_NAME = os.environ.get("NOW_EXT_NAME", "NOW Extension")
APP_NAME = os.environ.get("NOW_APP_NAME", "New Old World")

ANCHOR_PORT = int(os.environ.get("NOW_ANCHOR_PORT", "1700"))
EXT_BIN = os.environ.get("NOW_EXT_BIN")          # required
APP_BIN = os.environ.get("NOW_APP_BIN")          # optional

# The Mirror bundle. Off unless asked for - see the header. NOW_MIRROR_DIR
# defaults to the vendored checkout because that is where Mirror lives in
# this tree, but it is overridable: a Mirror built somewhere else is still
# a Mirror, and guessing a path is how a stage goes to the wrong build.
STAGE_MIRROR = os.environ.get("NOW_STAGE_MIRROR", "") == "1"
MIRROR_DIR = os.environ.get("NOW_MIRROR_DIR", os.path.join(NOW, "mirror"))
MIRROR_DEV = os.environ.get("NOW_MIRROR_GUEST_DIR",
                            "Macintosh HD:TimBotTu:mirror-dev")
# 1420 in three places already - mirror/guest/app/src/main.c's kDefaultPort,
# mirror/tools/stage-agent.py's GUEST_PORT, and the hostfwd in
# scripts/spin-up-ppc. This is the fourth, and it is the one that writes
# the number onto the guest, so it is the one the others must agree with.
MIRROR_PORT = int(os.environ.get("NOW_MIRROR_PORT", "1420"))

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


def write_verified(path, text, **want):
    """Write a small text file onto the guest and read it back.

    Not push_stream: this is a config line, not a MacBinary blob, and the
    anchor's `write` verb is what stamps it TEXT. `overwrite` is not
    optional for the same reason it is not optional above, and the
    measurement is Mirror's own (tools/stage-agent.py, 2026-07-31): the
    base image already carries a mirror.port, so without it every fresh
    clone dies on this one line AFTER every push has succeeded.

    `truncate` matters as much: a shorter number written over a longer
    one would otherwise leave the tail of the old port behind it, and
    "14200" is a port a person would read straight past."""
    h.request("write", {"path": path, "data": text, "offset": 0,
                        "truncate": True, "overwrite": True})
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

# 2b. The guest's dialling book, when the caller runs its OWN listener.
#
#    The compiled default is 10.0.2.2:5250 (prefs.c set_defaults), and the
#    base image's saved prefs say the same - which is correct for the
#    product and wrong for an instrumented clone on a desk where the
#    human's own host app already holds 5250. Measured 2026-08-02: that
#    app was live, serving a metal PowerBook, and a probe clone's guest
#    would have dialled INTO it and taken a registry slot the way the
#    prefs-suite spike (042f41f) records two instances already have.
#    So when NOW_WIRE_PORT names a port, the clone's book is WRITTEN to
#    dial it - same overwrite-not-inherit rule as mirror.port below. A
#    delivery run stages without NOW_WIRE_PORT and the book is whatever
#    the image saved, which dials the product's own 5250.
#
#    A minimal V1 record is deliberate: the loader takes host/port from
#    any format and leaves every other preference at its default
#    (prefs.c now_prefs_load, the "v1/v2: connection only" leg).
WIRE_PORT = os.environ.get("NOW_WIRE_PORT")
if WIRE_PORT and APP_BIN:
    import struct

    def macbinary(name, ftype, creator, data):
        """A MacBinary II wrapper: header, data fork, no resource fork.

        The anchor's put channel decodes MacBinary, so the type and
        creator here are what the staged file wears - the same reason
        the INIT pushes above are .bin files."""
        def crc16(raw):
            crc = 0
            for byte in raw:
                crc ^= byte << 8
                for _ in range(8):
                    crc = ((crc << 1) ^ 0x1021 if crc & 0x8000
                           else crc << 1) & 0xFFFF
            return crc
        hdr = bytearray(128)
        pname = name.encode("mac_roman")[:31]
        hdr[1] = len(pname)
        hdr[2:2 + len(pname)] = pname
        hdr[65:69] = ftype
        hdr[69:73] = creator
        struct.pack_into(">I", hdr, 83, len(data))
        hdr[122] = hdr[123] = 129
        struct.pack_into(">H", hdr, 124, crc16(bytes(hdr[:124])))
        pad = (-len(data)) % 128
        return bytes(hdr) + data + b"\0" * pad

    record = struct.pack(">4shH64s", b"NOWp", 1, int(WIRE_PORT),
                         b"10.0.2.2")
    prefs_name = f"{APP_NAME} Prefs"
    print(f"== stage {prefs_name} (guest dials 10.0.2.2:{WIRE_PORT}) ==")
    push_verified(f"Macintosh HD:System Folder:Preferences:{prefs_name}",
                  macbinary(prefs_name, b"pref", b"NOWo", record),
                  want_type="pref", min_data=len(record))

# 3. Mirror, if it was asked for. A SEPARATE application that happens to
#    run on the same Macintosh: NOW's Mirror page reads it and installs
#    nothing (now-guest-ppc/src/mirror/), so this is the only place in
#    this repository that puts it on a guest.
if STAGE_MIRROR:
    if not os.path.isdir(MIRROR_DIR):
        raise SystemExit(
            f"NOW_STAGE_MIRROR=1 but there is no Mirror checkout at "
            f"{MIRROR_DIR} — set NOW_MIRROR_DIR")

    inits = (("AXPeek", "guest/extensions/axpeek/build/AXPeek.bin"),
             ("QDPeek", "guest/extensions/qdpeek/build/QDPeek.bin"),
             ("Portal", "guest/extensions/portal/build/Portal.bin"))
    agent_bin = os.path.join(MIRROR_DIR, "guest/app/build/mirror-agent.bin")

    # Named all at once rather than one failure at a time: a bundle that
    # stages two INITs and then stops has left the guest in a state that
    # is neither before nor after, and the page reporting on it would
    # then be reporting a half-install nobody meant to make.
    wanted = [os.path.join(MIRROR_DIR, rel) for _, rel in inits] + [agent_bin]
    absent = [p for p in wanted if not os.path.isfile(p)]
    if absent:
        raise SystemExit(
            "NOW_STAGE_MIRROR=1 but these are not built:\n  "
            + "\n  ".join(absent)
            + f"\nbuild them in {MIRROR_DIR} first")

    # The three residents. Their code is in the RESOURCE fork, so data=0
    # is correct and `min_rsrc` is the assertion that means anything —
    # exactly as for the NOW Extension above. They load at BOOT ONLY, and
    # NOW's page reads them through Gestalt, so a machine staged without
    # the reboot below shows three "Not loaded" rows and is telling the
    # truth about a stage that has not finished.
    print("== stage Mirror's resident extensions ==")
    for name, rel in inits:
        push_verified(f"{EXTENSIONS}:{name}",
                      open(os.path.join(MIRROR_DIR, rel), "rb").read(),
                      want_type="INIT", min_rsrc=1024)

    # The agent, and the file that decides whether it can serve anybody.
    print("== stage Mirror's agent ==")
    ensure_dir(MIRROR_DEV)
    push_verified(f"{MIRROR_DEV}:mirror-agent", open(agent_bin, "rb").read(),
                  want_type="APPL", min_data=1024)

    # WRITTEN, never inherited. Mirror's agent reads this file once at
    # launch (mirror/guest/app/src/main.c :: read_port) and binds what it
    # names; a guest that kept the base image's copy on 2026-08-02 ran an
    # agent bound to a stale port, answered nothing, and reported
    # "Running" on NOW's own Mirror page the whole time. A few bytes of
    # data fork is the entire file, so min_data is what proves it landed.
    line = f"{MIRROR_PORT}\n"
    write_verified(f"{MIRROR_DEV}:mirror.port", line,
                   want_type="TEXT", min_data=len(line))
    print(f"  mirror.port names {MIRROR_PORT} — the host forward must "
          f"reach THAT port, or the agent answers nobody")

print("staged. COLD reboot required: an INIT loads at boot only, and this "
      "script has not rebooted anything.")
