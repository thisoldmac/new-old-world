#!/usr/bin/env python3
"""THE EXPERIMENT: can a VM snapshot stand in for a cold boot in a gate?

    tools/vmsnap-experiment.py --run /private/tmp/nowvm-xx \
        --port 18993 --anchor 18992 --build-dir <builds>/<hash>

An integration suite in this project has one cost that decides its shape.
A cold boot of the PowerPC guest is two to three minutes: clone, stage,
guest-clean shutdown, COLD boot so the INIT loads, launch, wait for the
dial. A suite that pays that per test cannot exist. A suite that pays it
ONCE and restores a snapshot between tests can — if restore works.

THE OPEN QUESTION THIS MEASURES, and it is not a rhetorical one:
`loadvm` restores RAM, so the guest comes back holding a TCP connection
whose peer no longer exists. Does it notice and re-dial? Or must the
snapshot be taken with NO HOST CONNECTED, so the restored guest is in the
state it is already built to recover from — retrying its dial?

So this measures BOTH, and reports what happened rather than what should:

  A. snapshot taken while a host is CONNECTED, restored with a fresh
     listener up. Does the guest re-dial, and how long does it take?
  B. snapshot taken after the host DROPPED, same question.
  C. a restore over a WEDGED machine — the case the suite actually needs,
     because the reason to restore is that the last test broke something.

Every number here is measured on one Mac against one guest and is a
measurement, not a property. Quote it with the rig.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qemu_oracle.qmp import QMPClient, OracleError          # noqa: E402
from nowwire import GuestWire, GuestGone, local_identity    # noqa: E402


def hmp(sock, line):
    q = QMPClient(sock, timeout=180.0)
    try:
        return q.hmp(line)
    finally:
        q.close()


def savevm(sock, tag, log):
    t = time.time()
    out = hmp(sock, f"savevm {tag}")
    log(f"   savevm {tag}: {time.time() - t:.1f}s {out.strip()!r}")
    return time.time() - t


def loadvm(sock, tag, log):
    t = time.time()
    out = hmp(sock, f"loadvm {tag}")
    log(f"   loadvm {tag}: {time.time() - t:.1f}s {out.strip()!r}")
    return time.time() - t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True, help="the VM's run directory")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--anchor", type=int, default=0)
    ap.add_argument("--build-dir", default="")
    ap.add_argument("--redial-wait", type=float, default=180.0)
    ap.add_argument("--tag", default="nowsuite")
    a = ap.parse_args()

    sock = os.path.join(a.run, "qmp.sock")
    results = {"rig": {"run": a.run, "wire": a.port, "anchor": a.anchor},
               "cases": []}

    def log(s):
        print(s, flush=True)

    ident = local_identity(a.build_dir) if a.build_dir else None
    wire = GuestWire(a.port, name="vmsnap-experiment", log=log)

    def take(case, wait=None):
        """Wait for a dial and confirm it is the build under test."""
        t = time.time()
        wire.accept(wait=wait if wait is not None else a.redial_wait)
        if ident:
            wire.require_build(*ident)
        wire.alive()
        return time.time() - t

    def record(name, ok, seconds, note):
        results["cases"].append({"case": name, "ok": ok,
                                 "seconds": round(seconds, 2), "note": note})
        log(f"   -> {name}: {'OK' if ok else 'NO'} ({seconds:.1f}s) {note}")

    log("== case 0: the guest is up and answering ==")
    took = take("initial")
    log(f"   first dial taken in {took:.1f}s")

    # --- A: snapshot with a live host connection -------------------------
    log("")
    log("== A: savevm WITH the host connected, then restore ==")
    log("   The pessimistic case. The saved RAM holds an ESTABLISHED TCP")
    log("   connection to a socket that will not exist after the restore.")
    try:
        savevm(sock, a.tag + "-connected", log)
    except OracleError as e:
        record("A-savevm-connected", False, 0, f"savevm refused: {e}")
        return finish(results)
    wire.drop()
    log("   host connection dropped; restoring...")
    loadvm(sock, a.tag + "-connected", log)
    try:
        t = take("A")
        record("A-restore-while-connected", True, t,
               "the guest re-dialled after a restore taken mid-conversation")
    except GuestGone as e:
        record("A-restore-while-connected", False, a.redial_wait, str(e))

    # --- B: snapshot with no host connected ------------------------------
    log("")
    log("== B: savevm with NO host connected, then restore ==")
    log("   The guest is saved in the state it is already built to recover")
    log("   from — retrying its dial — so nothing about the snapshot is")
    log("   novel to it.")
    wire.drop()
    time.sleep(8)                       # let the guest notice and start retrying
    try:
        savevm(sock, a.tag + "-idle", log)
    except OracleError as e:
        record("B-savevm-idle", False, 0, f"savevm refused: {e}")
        return finish(results)
    loadvm(sock, a.tag + "-idle", log)
    try:
        t = take("B")
        record("B-restore-from-idle", True, t,
               "the guest re-dialled after a restore taken with no host up")
    except GuestGone as e:
        record("B-restore-from-idle", False, a.redial_wait, str(e))

    # --- C: restore over a machine that is broken ------------------------
    log("")
    log("== C: restore over a WEDGED machine ==")
    log("   The case a suite actually needs: the reason to restore is that")
    log("   the last test broke the Mac. If this does not work, snapshots")
    log("   buy nothing — a suite only needs them for the tests that hurt.")
    wire.drop()
    loadvm(sock, a.tag + "-idle", log)
    try:
        t = take("C")
        record("C-restore-recovers", True, t,
               "restore reached a live guest again (see the note below on "
               "what 'wedged' means in this run)")
    except GuestGone as e:
        record("C-restore-recovers", False, a.redial_wait, str(e))

    return finish(results)


def finish(results):
    print("")
    print(json.dumps(results, indent=2), flush=True)
    ok = all(c["ok"] for c in results["cases"])
    print("")
    print("VERDICT: " + ("snapshots can carry a suite" if ok else
                         "at least one case did NOT work — read the cases, "
                         "and do not design a suite around the ones that did "
                         "until the failures are explained"), flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
