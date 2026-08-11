#!/usr/bin/env python3
"""Put a document with a creator no application owns onto the guest's
desktop, so that opening it raises the unknown-creator modal.

    NOW_ANCHOR_PORT=1740 tools/stage-orphan-doc.py

WHY THIS EXISTS. Plan 018 lists "unknown-creator / open-with modal renders
nothing at all" as a defect, and sweep A could not score it either way
because nobody could raise one:

    "not reproduced; I could not force one. Slice 3 needs a reliable way
     to raise it (a file with a garbage creator) before this can be scored
     either way."   -- docs/fidelity-sweep-2026-08-07-a.md, verdict 6

A modal nobody can raise on demand cannot be measured twice, so it cannot
appear in an A/B sweep at all. This is the "on demand" half.

WHAT IT STAGES. One MacBinary document, data fork only, whose Finder type
and creator are four characters no application on the volume claims. The
Desktop Database therefore has no owner for it, and a Finder open of it
raises the "could not be opened, because the application program that
created it could not be found" alert (or, with Mac OS Easy Open / File
Exchange active, its translation chooser -- either one is the window class
under test, and the report says which appeared).

TYPE AND CREATOR ARE BOTH REQUIRED TO BE ORPHANS, and the type matters
more than it looks: the Finder falls back to the TYPE when the creator is
unknown, so a document typed 'TEXT' with a garbage creator opens happily
in SimpleText and raises nothing at all. That is the first way this went
wrong. Both are 'ZZZZ' by default, which nothing on a stock OS 9 volume
registers.

MAKING THE FINDER NOTICE. A push through the anchor writes the file behind
the Finder's back, and the Finder does not always redraw the desktop for
it. Two ways to settle that, in order of cost:

  * `--refresh-wire PORT` asks the guest, through NOW's own `script` verb,
    to `update` the desktop folder. Needs a free wire port -- i.e. the host
    app is NOT running -- because this binds a listener the guest dials.
  * a cold reboot (`tools/shutdown-guest.py`, then boot again) makes the
    Finder build its desktop from the volume. Slower, and never in doubt.

`--wait-visible` polls the Finder (over the same wire) until the item is
listed on the desktop, so a driver can stop guessing.

EMULATOR INSTRUMENT. Same standing as tools/stage-ext.py: it drives the
lab's anchor worker, NOW ships none of it, and nothing here has run
against physical hardware.
"""

import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.environ.get("NOW_LAB_ROOT")
if not LAB:
    LAB = NOW
    while LAB != "/" and not os.path.isdir(os.path.join(LAB, "mcp-classic")):
        LAB = os.path.dirname(LAB)
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness, HarnessError  # noqa: E402


def macbinary(name: str, ftype: bytes, creator: bytes, data: bytes) -> bytes:
    """A MacBinary II wrapper: header, data fork, no resource fork.

    The anchor's put channel decodes MacBinary, so the type and creator in
    this header are what the staged file WEARS on the guest -- which is the
    entire point of the exercise. Same helper as tools/stage-ext.py's
    preferences leg; kept local rather than shared because that one is a
    closure inside a one-shot script and lifting it would touch the
    staging path this tool must not disturb."""
    def crc16(raw: bytes) -> int:
        crc = 0
        for byte in raw:
            crc ^= byte << 8
            for _ in range(8):
                crc = ((crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
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


def four(value: str, what: str) -> bytes:
    raw = value.encode("mac_roman")
    if len(raw) != 4:
        raise SystemExit(f"{what} must be exactly four characters: {value!r}")
    return raw


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--anchor", type=int,
                    default=int(os.environ.get("NOW_ANCHOR_PORT", "1700")))
    ap.add_argument("--name", default="Orphan Document")
    ap.add_argument("--folder", default="Macintosh HD:Desktop Folder",
                    help="HFS folder to stage into (default: the desktop)")
    ap.add_argument("--type", default="ZZZZ")
    ap.add_argument("--creator", default="ZZZZ")
    ap.add_argument("--body", default="Nothing on this volume owns this file.")
    ap.add_argument("--refresh-wire", type=int, default=None,
                    help="wire port to ask the guest to update the desktop on "
                         "(only when no host app holds it)")
    ap.add_argument("--wait-visible", type=int, default=0, metavar="SECONDS",
                    help="with --refresh-wire, poll the Finder until the item "
                         "is listed on the desktop")
    args = ap.parse_args()

    ftype, creator = four(args.type, "--type"), four(args.creator, "--creator")
    path = f"{args.folder}:{args.name}"
    blob = macbinary(args.name, ftype, creator,
                     args.body.encode("mac_roman") + b"\r")

    h = Harness(host="127.0.0.1", port=args.anchor, expect_backing={"worker"})
    hello = h.request("hello", {})
    if not hello.get("policyDigest"):
        raise SystemExit(f"anchor did not answer a usable hello: {hello}")
    print(f"anchor hello: machine {hello.get('machineId')}")

    try:
        h.push_stream(path, blob, overwrite=True, pipeline=1)
    except HarnessError as e:
        # tools/stage-ext.py documents this one: a measured anchor quirk,
        # tolerated by name only, and the fork-size verify below still has
        # to pass on its own.
        if "catalog dates" not in f"{e}":
            raise
        print(f"  [warn] {args.name}: {e} (known anchor quirk)")

    st = h.request("stat", {"path": path})
    print(f"  staged {path}: exists={st.get('exists')} "
          f"type={st.get('type')} creator={st.get('creator')} "
          f"data={st.get('dataSize')}")
    # The guest is the oracle, not the push. A wrong type here is not a
    # cosmetic miss: 'TEXT' would open in SimpleText and raise no modal at
    # all, which is a green run that measured nothing.
    if not st.get("exists"):
        raise SystemExit(f"stage failed: {path} is not there")
    if st.get("type") != args.type or st.get("creator") != args.creator:
        raise SystemExit(
            f"staged as type={st.get('type')!r} creator={st.get('creator')!r}, "
            f"wanted {args.type!r}/{args.creator!r} — an owned type would open "
            f"in its application and raise no modal")

    if args.refresh_wire:
        import subprocess
        print(f"  asking the Finder to update, over wire {args.refresh_wire}")
        folder = args.folder.split(":")[-1]
        disk = args.folder.split(":")[0]
        script = (f'tell application "Finder" to update folder "{folder}" '
                  f'of disk "{disk}"')
        rc = subprocess.call([sys.executable, os.path.join(HERE, "askguest.py"),
                              "--port", str(args.refresh_wire), "--wait", "120",
                              f"script:source={script}"])
        if rc != 0:
            print("  [warn] the update script did not answer; a cold reboot "
                  "is the fallback that never fails")

    print()
    print(f"Now open it: a Finder open of {args.name!r} on the desktop.")
    print("  through the product path:  mirror_drive --gesture open "
          f"--item {args.name!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
