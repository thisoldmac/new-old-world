#!/usr/bin/env python3
"""May this VM be power-cut? Ask before QMP `quit`, and fail closed.

    tools/shared-image-guard.py <qmp.sock>          # refuse or allow, exit 0/1
    tools/shared-image-guard.py --disk <image>      # the same, by path
    tools/shared-image-guard.py <qmp.sock> --json   # for a caller

A QMP `quit` is a power cut. It leaves the HFS volume with the "volume
unmounted" bit CLEAR, so the machine that next boots that image opens in
Disk First Aid — a modal sitting on the desktop until somebody dismisses
it. On a throwaway clone that costs nothing: the clone is deleted. On a
SHARED asset it is durable damage, inherited by every clone anybody makes
afterwards, and it has happened. Measured 2026-08-07 over the images
this project keeps:

    now-mirror-stage.qcow2.bak-20260806      CLEAN
    now-mirror-stage.qcow2.bak-20260806-2    DIRTY
    now-mirror-stage.qcow2.bak-20260806-3    DIRTY
    now-mirror-stage.qcow2.bak-20260806-4    DIRTY   (already named .dirty)
    now-mirror-stage.qcow2.bak-…-pre-transport   DIRTY
    os91-runner.qcow2                        DIRTY   (since 19 July)

Five of the seven preserved images on this Mac are dirty. Nothing in the
rig could refuse the act that made them so; `tools/volclean.py` and the
bake gate can only find out afterwards. This file is the refusal.

WHAT IT DECIDES, and why that line and not another. The question is not
"is this image important" — it is **will a power cut here reach a file
that outlives this session**:

  * The VM's TOP-LEVEL writable disk is what a power cut dirties. If that
    file is a shared asset, REFUSE.
  * A qcow2 BACKING file is opened read-only, so a power cut cannot mark
    its volume. Those are reported, never refused — a guard that refuses
    the safe case teaches people to pass --force.
  * Cannot reach QMP, cannot parse the reply, cannot find the disk: REFUSE.
    A guard whose failure mode is "allow" is a guard that stops guarding
    on exactly the day something is unusual.

WHAT IT IS NOT. It is not a substitute for shutting the guest down
properly (tools/shutdown-guest.py, whose Finder route is the only one
measured to leave a clean volume). It is the floor under the moment when
that has already failed and somebody is deciding what to do next.
"""
import argparse
import json
import os
import socket
import subprocess
import sys

# The shared asset store. Everything in it is somebody else's oracle
# tomorrow — including the .bak-* copies, which exist precisely so a bad
# bake can be undone and are therefore worth as much as the live file.
ASSETS = os.path.expanduser(
    os.environ.get("NOW_STAGE_ASSETS", "~/Lab/Assets/os91-qemu"))


def _under(path, directory):
    """Is `path` inside `directory`? Both resolved, so a symlinked run
    directory cannot smuggle a shared image past the check."""
    path = os.path.realpath(path)
    directory = os.path.realpath(directory)
    return path == directory or path.startswith(directory + os.sep)


def classify(path):
    """('shared'|'session', why) for one image path.

    Pure, and deliberately so: this is the sentence the whole tool turns
    on, and it should be provable from a string rather than from a VM."""
    if _under(path, ASSETS):
        return "shared", f"inside the shared asset store {ASSETS}"
    return "session", "not in the shared asset store"


def backing_chain(path):
    """[path, its backing file, …] — deepest last.

    qemu-img answers this; a missing qemu-img is not a reason to allow,
    so the caller treats an exception as a refusal."""
    out = subprocess.run(
        ["qemu-img", "info", "--backing-chain", "--output=json", path],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "qemu-img info failed")
    return [entry["filename"] for entry in json.loads(out.stdout)]


def _qmp(sock_path, commands):
    """Run QMP commands on a fresh connection and return the replies."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    try:
        s.connect(sock_path)
        f = s.makefile("rwb")
        f.readline()                                   # the greeting
        f.write(b'{"execute":"qmp_capabilities"}\n')
        f.flush()
        f.readline()
        replies = []
        for command in commands:
            f.write(json.dumps({"execute": command}).encode() + b"\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("QMP hung up")
                msg = json.loads(line)
                if "return" in msg or "error" in msg:
                    replies.append(msg)
                    break
                # events (STOP, RESET, …) interleave; they are not replies
        return replies
    finally:
        s.close()


def writable_disks(sock_path):
    """The VM's top-level WRITABLE images, as absolute paths.

    Read-only devices are dropped rather than reported: a CD-ROM cannot
    be dirtied and naming it here would make the verdict harder to read
    on the one occasion somebody actually stops to read it."""
    reply = _qmp(sock_path, ["query-block"])[0]
    if "error" in reply:
        raise RuntimeError(reply["error"].get("desc", "query-block failed"))
    disks = []
    for device in reply.get("return", []):
        inserted = device.get("inserted") or {}
        name = inserted.get("file")
        if not name:
            continue
        if inserted.get("ro"):
            continue
        disks.append(name)
    if not disks:
        raise RuntimeError("QMP reported no writable disk on this machine")
    return disks


def verdict(sock_path=None, disk=None):
    """The whole answer, as data. `allowed` False means: do not quit."""
    result = {"allowed": None, "reason": "", "top": [], "backing": []}
    try:
        tops = [disk] if disk else writable_disks(sock_path)
    except (OSError, ValueError, RuntimeError) as exc:
        # FAIL CLOSED. "I could not tell" and "it is safe" are different
        # answers and only one of them is honest.
        result["allowed"] = False
        result["reason"] = (
            f"could not establish which image this machine writes to "
            f"({exc}). Refusing rather than guessing: a power cut against "
            f"an unknown disk is the case this guard exists for.")
        return result

    shared = []
    for top in tops:
        kind, why = classify(top)
        result["top"].append({"path": top, "kind": kind, "why": why})
        if kind == "shared":
            shared.append(top)
        try:
            for member in backing_chain(top)[1:]:
                result["backing"].append(
                    {"path": member, "kind": classify(member)[0],
                     "readOnly": True})
        except (OSError, ValueError, RuntimeError):
            # A backing file we cannot resolve is not a refusal: QEMU has
            # it open read-only either way, and the writable disk above
            # is the one this decision turns on.
            pass

    if shared:
        result["allowed"] = False
        result["reason"] = (
            "this machine is writing DIRECTLY to a shared image: "
            + ", ".join(shared)
            + ". A QMP quit would leave that volume marked mounted, and "
              "every clone anybody makes of it afterwards opens in Disk "
              "First Aid. Shut the guest down instead "
              "(tools/shutdown-guest.py <qmp.sock> --port <anchor> "
              "--wire <wire>), or leave the VM up and say so.")
        return result

    result["allowed"] = True
    result["reason"] = (
        "every writable disk is session-private, so a power cut damages "
        "only this session's clone — which is throwaway. It is still a "
        "dirty volume: do NOT preserve or install this image, and delete "
        "the run directory.")
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock", nargs="?", help="the VM's qmp.sock")
    ap.add_argument("--disk", help="ask about an image path instead")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not a.sock and not a.disk:
        ap.error("give a qmp.sock or --disk")

    v = verdict(sock_path=a.sock, disk=a.disk)
    if a.json:
        print(json.dumps(v, indent=2))
    else:
        for row in v["top"]:
            print(f"  writable  {row['kind']:8} {row['path']}")
        for row in v["backing"]:
            print(f"  backing   {row['kind']:8} {row['path']}  (read-only)")
        print(("ALLOWED: " if v["allowed"] else "REFUSED: ") + v["reason"])
    return 0 if v["allowed"] else 1


if __name__ == "__main__":
    sys.exit(main())
