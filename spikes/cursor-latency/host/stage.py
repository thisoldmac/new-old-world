#!/usr/bin/env python3
"""Put the three CursorRig pieces on a booted emulator guest.

    RIG_ANCHOR_PORT=1407 host/stage.py

    CursorRig.bin           -> System Folder:Extensions:CursorRig MEASUREMENT RIG
    CursorRigIntake.bin     -> TimBotTu:cursor-rig:CursorRig Intake
    CursorRigStarver.bin    -> TimBotTu:cursor-rig:CursorRig Starver

This is an EMULATOR instrument. It drives the lab's baked anchor worker,
which belongs to the parent checkout and which this spike neither ships
nor imports from its own sources - the same borrowing rule the rest of
the rig follows.

Four things go wrong here and each one is somebody's afternoon:

  * AN INIT LOADS AT BOOT ONLY, and OS 9 ignores a soft power-down. This
    script stages and does NOT reboot; run/spin-up does the cold cycle
    and re-verifies afterwards. A stage without it leaves the previous
    extension resident and every number attributed to the new one.
  * BELIEVING A PUSH. The guest is the oracle: fork sizes and Finder
    type read back off the machine, never the exit code. An INIT's code
    lives in the RESOURCE fork, so a non-empty rsrc is the assertion
    that matters - a file with the right name and an empty resource fork
    boot-loads nothing at all.
  * `catalog dates err -43` is a measured anchor quirk, not a failure.
    Exactly that string is tolerated, and the fork-size verify still has
    to pass; tolerating it blindly would make a real failure look like a
    success until the guest reported the rig absent.
  * `mkdir` is FSpDirCreate: one level, no parents, -48 when the leaf
    exists. Walk the chain.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPIKE = os.path.abspath(os.path.join(HERE, ".."))

LAB = os.environ.get("NOW_LAB_ROOT")
if not LAB:
    LAB = SPIKE
    while LAB != "/" and not os.path.isdir(os.path.join(LAB, "mcp-classic")):
        LAB = os.path.dirname(LAB)
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402

EXTENSIONS = "Macintosh HD:System Folder:Extensions"
RIGDIR = os.environ.get("RIG_GUEST_DIR", "Macintosh HD:TimBotTu:cursor-rig")

# The name is loud on purpose. It is what a person sees in the Extensions
# folder, in the startup parade and in any conflict report, and a rig that
# looks like a product in those places is how an instrument gets quoted as
# a result.
EXT_NAME = "CursorRig MEASUREMENT RIG"
APP_NAME = "CursorRig Intake"
LOAD_NAME = "CursorRig Starver"
RESTART_NAME = "CursorRig Restart"

PORT = int(os.environ.get("RIG_ANCHOR_PORT", "1407"))
INIT_BIN = os.environ["RIG_INIT_BIN"]
APP_BIN = os.environ["RIG_APP_BIN"]
LOAD_BIN = os.environ["RIG_LOAD_BIN"]
RESTART_BIN = os.environ.get("RIG_RESTART_BIN")

h = Harness(host="127.0.0.1", port=PORT, expect_backing={"worker"})
hello = h.request("hello", {})
if not hello.get("policyDigest"):
    raise SystemExit(f"anchor did not answer a usable hello: {hello}")
print(f"anchor hello: machine {hello.get('machineId')}")


def ensure_dir(path):
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


def verify(path, want_type=None, want_creator=None, min_data=0, min_rsrc=0):
    st = h.request("stat", {"path": path})
    ok = (st.get("exists")
          and (st.get("dataSize") or 0) >= min_data
          and (st.get("rsrcSize") or 0) >= min_rsrc
          and (want_type is None or st.get("type") == want_type)
          and (want_creator is None or st.get("creator") == want_creator))
    print(f"  [{'OK ' if ok else 'BAD'}] {path.split(':')[-1]:26} "
          f"type={st.get('type')} creator={st.get('creator')} "
          f"data={st.get('dataSize')} rsrc={st.get('rsrcSize')}")
    if not ok:
        raise SystemExit(f"stage verify failed for {path}: {st}")
    return st


def push_verified(path, blob, **want):
    try:
        h.push_stream(path, blob, overwrite=True, pipeline=1)
    except HarnessError as e:
        if "catalog dates" not in f"{e}":
            raise
        print(f"  [warn] {path.split(':')[-1]}: {e} "
              f"(known anchor quirk; proving the bytes landed instead)")
    return verify(path, **want)


QUARANTINE = "Macintosh HD:TimBotTu:cursor-rig-quarantine"

# Residents that must not be in the Extensions folder while this rig is.
# CursorRig REFUSES to install beside them (it checks their Gestalt
# selector at boot), so leaving one in place does not produce a
# conflict - it produces a rig that is silently not there, which is the
# single most expensive failure shape on this bench.
CONFLICTING_CREATORS = {"NOWx"}


def disable_conflicts():
    """Move conflicting residents out of the System Folder.

    Renaming inside Extensions is not enough and neither is a leading
    space: the Extensions folder is scanned by TYPE, not by name. The
    only reliable disable is to move the file out of the System Folder
    altogether.
    """
    listing = h.request("list", {"path": EXTENSIONS})
    entries = listing.get("items") or listing.get("entries") or []
    truncated = bool(listing.get("truncated"))
    moved = []
    for e in entries:
        # The listing already carries type and creator, so no per-file
        # stat: one of the 128 names in this folder makes FSMakeFSSpec
        # answer -37 (bdNamErr), and a conflict check that dies on an
        # unrelated filename checks nothing.
        name = e.get("name")
        if not name or e.get("creator") not in CONFLICTING_CREATORS:
            continue
        ensure_dir(QUARANTINE)
        h.request("move", {"from": f"{EXTENSIONS}:{name}",
                           "to": f"{QUARANTINE}:{name}"})
        moved.append(f"{name} (creator {e.get('creator')})")
    if moved:
        print("  quarantined, because CursorRig refuses to install beside "
              "them:")
        for m in moved:
            print(f"    {m}")
    elif truncated:
        # `list` caps at 128 entries with no paging, and this folder has
        # more, so a clean scan is a HINT and not a guarantee. The
        # authority is the resident itself: on a conflict CursorRig
        # publishes its table with refused=conflict and installs no
        # hooks, and rigdrive reports that in as many words.
        print("  nothing conflicting in the first "
              f"{len(entries)} entries - but the listing is TRUNCATED, so "
              "this is a hint. The resident's own `refused` field is the "
              "authority; rigdrive status reads it.")
    else:
        print("  no conflicting resident in the Extensions folder")
    return moved


print("== check the Extensions folder for conflicts ==")
disable_conflicts()

print("== stage the resident ==")
push_verified(f"{EXTENSIONS}:{EXT_NAME}", open(INIT_BIN, "rb").read(),
              want_type="INIT", want_creator="CRig", min_rsrc=1024)

print("== stage the applications ==")
ensure_dir(RIGDIR)
push_verified(f"{RIGDIR}:{APP_NAME}", open(APP_BIN, "rb").read(),
              want_type="APPL", min_data=1024)
push_verified(f"{RIGDIR}:{LOAD_NAME}", open(LOAD_BIN, "rb").read(),
              want_type="APPL", min_data=1024)
if RESTART_BIN:
    # min_RSRC, not min_data: the restarter is a 68K application and a
    # 68K application's code is in CODE resources, so its data fork is
    # legitimately empty. The PowerPC applications above are the other
    # way round - their PEF is the data fork. Asserting the wrong fork
    # here failed a perfectly good binary, which is the verify doing its
    # job and is worth keeping in the shape of the assertion.
    push_verified(f"{RIGDIR}:{RESTART_NAME}", open(RESTART_BIN, "rb").read(),
                  want_type="APPL", min_rsrc=1024)


def sidecar(binary):
    """The build identity written beside the binary at build time."""
    path = os.path.splitext(binary)[0] + ".buildid"
    if os.path.isfile(path):
        return open(path).read().strip()
    return None


print("\nstaged these identities - the host will demand them back off the "
      "guest before believing any measurement:")
print(f"  resident build_id     {sidecar(INIT_BIN)}")
print(f"  intake   app_build_id {sidecar(APP_BIN)}")
print("\nA COLD reboot is required: an INIT loads at boot only, and nothing "
      "here has rebooted anything.")
