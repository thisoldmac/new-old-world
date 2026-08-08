#!/usr/bin/env python3
"""THE GATE: run the whole hardware census against a real guest and require
that the Workshop is still alive afterwards.

    tools/census-survives.py --port 18993 --wait 240 \
        --build-dir "$TMPDIR/now-guest-builds/<hash>" \
        --qmp /private/tmp/nowvm-xx/qmp.sock

Exit 0 = the guest walked every probe and answered afterwards.
Exit 1 = a check failed; the failing probe and cursor are named.
Exit 2 = the gate could not run (no guest dialled, wrong build).

WHY THIS EXISTS, AND WHY IT CANNOT BE A NATIVE TEST
---------------------------------------------------
On 2026-08-07 a human clicked Run Census in the Workshop and the guest
died — the whole application, because the Workshop is the guest's only
window and every module is a page inside it. A screendump afterwards
showed the desktop with NOW gone and one orphaned window left drawn on
it. Then the Finder crashed too.

1,902 tests were green at the time, and none of them could have caught
it: `scripts/test-native` compiles the guest's logic with the host `cc`
and runs it HERE, so the probe that killed the machine — a Mixed Mode
dispatch to a 68K trap that does not exist on that Mac — is not even
reachable from a native test. It is not a logic defect. It is what
happens when this code meets a real Mac OS.

So the gate boots nothing of its own: it attaches to a guest that is
already up (`scripts/bake-ext-image` has one, `scripts/spin-up-ppc`
leaves one) and drives it.

WHAT IT ASSERTS, AND WHY EACH ONE IS NOT THE OBVIOUS CHECK
----------------------------------------------------------
* IT PAGES. The `census` COMMAND is declared single-page and always
  gathers cursor 0; the Workshop's Hardware module walks every page of
  every probe. A gate built on the command would stop at page one and
  call a machine safe that is not, so this drives `census.request` with
  cursors — the same paginated route the module runs, the same gatherers
  underneath (contract: censusExchange).

* LIVENESS IS AN ANSWER. Not "the process exists": when this defect fired
  the application was dead with its window still on screen and the anchor
  worker still holding its TCP port. Every process-shaped check would
  have passed. The wire is pumped by the application's own event loop, so
  a reply is proof that loop is turning.

* THE MACHINE, NOT ONLY THE APPLICATION. `census pccard` did not merely
  kill NOW: afterwards the ANCHOR WORKER — a separate process that
  survives NOW dying, every other time — stopped answering too, and the
  Finder crashed under the human's hands. So the gate checks the anchor
  after the sweep. A defect that escapes the process that caused it is a
  different and worse thing than a crash, and a gate that only watched
  NOW would have called this half-fixed.

* NO ORPHANED WINDOW. The crash left a window drawn on the desktop with
  no application behind it. `ps` before and after is the honest, cheap
  half of that: it catches the process disappearing. The window half is
  checked by the screendump this writes on failure, which is evidence for
  a person rather than an assertion — said plainly rather than claimed.

WHAT IT DOES NOT COVER, SAID OUT LOUD
-------------------------------------
The App Switcher. The second half of the human's report was that
selecting the App Switcher crashed the Finder. The App Switcher is a
faceless background process and "selecting" it means pulling down the
Application menu, which needs the act plane armed against the Finder and
a menu route this gate does not drive. It is NOT covered here, and the
anchor check above is the nearest thing to it: both are "did the damage
escape NOW's own process?". Do not read a green run as evidence about
the Finder's menus.
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nowwire import GuestWire, GuestGone, WrongGuest, local_identity  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT = os.path.join(HERE, "contract", "asyncapi.yaml")

# A probe may legitimately need several pages (drivers, selectors, scsi).
# The cap is a runaway guard, not a limit anybody should hit: a probe that
# never clears `more` is itself a defect and gets named as one.
MAX_PAGES = 64


def probes_from_contract(path=CONTRACT):
    """The probe registry, DERIVED from the contract rather than typed here.

    contract/asyncapi.yaml's x-census is where both halves read the list,
    so a probe added there and served by the guest is swept by this gate
    without anybody remembering to edit it — and a probe added to the
    guest and NOT declared is a contract violation the coverage gates
    already catch. Hand-listing them here would have been a second place
    to be wrong (AGENTS.md > Enumerated lists rot at merges)."""
    with open(path) as f:
        text = f.read()
    start = text.find("x-census:")
    if start < 0:
        raise RuntimeError("no x-census registry in the contract")
    block = text[start:]
    after = block.find("\n    x-probes:")
    if after < 0:
        raise RuntimeError(
            "no x-probes under x-census — the registry moved, and this gate "
            "must not silently sweep a shorter list than the guest serves")
    block = block[after + 1:]
    # Stop at the next key shallower than the probe names. The registry
    # sits inside a document whose NEXT section (x-cloud) has keys at the
    # same six-space indent, and a regex that ran to a fixed byte count
    # swept `drive`, `photos` and `contacts` — three cloud services — as
    # though they were hardware probes. A gate that asks a guest for a
    # probe it does not serve gets `refused` and reads green, so that
    # error was invisible in the result and only visible in the list.
    end = re.search(r"^ {0,4}\S", block[len("    x-probes:"):], re.M)
    if end:
        block = block[:len("    x-probes:") + end.start()]
    return re.findall(r"^      ([a-z][\w-]*):", block, re.M)


def screendump(qmp_sock, out_ppm, log):
    if not qmp_sock or not os.path.exists(qmp_sock):
        return None
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from qemu_oracle.qmp import QMPClient
        q = QMPClient(qmp_sock)
        q.execute("screendump", {"filename": out_ppm})
        q.close()
        log(f"  screendump written: {out_ppm}")
        return out_ppm
    except Exception as e:                      # evidence is best-effort
        log(f"  (no screendump: {e})")
        return None


def find_lab():
    lab = os.environ.get("NOW_LAB_ROOT")
    if lab and os.path.isdir(os.path.join(lab, "mcp-classic")):
        return lab
    # A worktree sits several levels under the lab checkout; walk up to the
    # one that has the anchor client, the same way scripts/spin-up-ppc does.
    d = HERE
    while d != "/":
        if os.path.isdir(os.path.join(d, "mcp-classic")):
            return d
        d = os.path.dirname(d)
    return None


def anchor_answers(port, timeout=25.0, tries=3, gap=5.0):
    """Does the anchor worker still answer? A separate process from NOW, so
    this is the question "did the damage stay inside the application?".

    Asked more than once on purpose, and this is a judgement rather than a
    reflex: a single dropped connection to this worker is ordinary — it is
    reconnected per request and a lane's other tools talk to it too, and
    one such drop went red here against a machine that was demonstrably
    fine. The defect it exists for did not look like that. It timed out,
    twice in a row, minutes apart, with both graceful shutdown routes shut.
    Three tries tells those apart; one try does not."""
    lab = find_lab()
    if lab is None:
        return None, "no lab checkout found for the anchor client"
    sys.path.insert(0, os.path.join(lab, "mcp-classic"))
    try:
        from timbottu_mcp_classic.harness import Harness
    except Exception as e:
        return None, f"the anchor client will not import: {e}"
    why = "never attempted"
    for attempt in range(tries):
        try:
            h = Harness(host="127.0.0.1", port=port, expect_backing={"worker"},
                        timeout=timeout)
            h.request("hello", {})
            return True, ("the anchor worker answered" if attempt == 0 else
                          f"the anchor worker answered on try {attempt + 1}")
        except Exception as e:
            why = f"{type(e).__name__}: {e}"
            if attempt + 1 < tries:
                time.sleep(gap)
    return False, f"{tries} tries, last: {why}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True, help="NOW's wire port")
    ap.add_argument("--anchor", type=int, default=0,
                    help="the anchor worker's forwarded port; checked after "
                         "the sweep, because this defect escaped NOW's process")
    ap.add_argument("--wait", type=float, default=240.0)
    ap.add_argument("--reply-timeout", type=float, default=45.0)
    ap.add_argument("--qmp", default="", help="qmp.sock, for a screendump on failure")
    ap.add_argument("--build-dir", default="",
                    help="the guest build directory, so the gate can assert "
                         "WHICH guest answered")
    ap.add_argument("--probes", default="",
                    help="comma-separated subset (default: the whole registry)")
    ap.add_argument("--evidence-dir", default="",
                    help="where a failure screendump goes (default: beside --qmp)")
    a = ap.parse_args()

    def log(s):
        print(s, flush=True)

    probes = ([p.strip() for p in a.probes.split(",") if p.strip()]
              if a.probes else probes_from_contract())
    log("== census-survives: the whole census, against a real guest ==")
    log(f"   probes ({len(probes)}, from contract/asyncapi.yaml x-census): "
        + ", ".join(probes))

    evidence = a.evidence_dir or (os.path.dirname(a.qmp) if a.qmp else ".")
    wire = GuestWire(a.port, reply_timeout=a.reply_timeout, name="census-gate",
                     log=log)

    def fail(msg, code=1):
        log("")
        log("CENSUS GATE FAILED")
        log(f"  {msg}")
        screendump(a.qmp, os.path.join(evidence, "census-gate-failure.ppm"), log)
        log("")
        log("  Nothing after the failing probe was run. Those checks are")
        log("  UNRUN, not passed and not skipped: a suite that walks past a")
        log("  dead machine and reports greens is the defect class this gate")
        log("  exists for.")
        return code

    try:
        wire.accept(wait=a.wait)
    except GuestGone as e:
        return fail(str(e), 2)

    try:
        if a.build_dir:
            src, build = local_identity(a.build_dir)
            ext = wire.require_build(src, build)
            log(f"   build under test CONFIRMED: resident {build[:12]}, "
                f"lifecycle {ext.get('lifecycle')}, "
                f"capabilities {ext.get('capabilities')}")
        else:
            log("   [warn] no --build-dir: this run does NOT know which guest "
                "answered.")

        # THE LIST THIS GATE SWEEPS, CHECKED AGAINST THE GUEST'S OWN.
        # The probe names live in THREE places: the guest's dispatch table,
        # the contract's x-census (which this gate derives from), and the
        # hand-typed `help census` text a person reads at the console. This
        # gate's first derivation was silently wrong — it ran past x-census
        # and swept three cloud services as hardware probes — and the RESULT
        # could not show it, because a probe a guest does not serve answers
        # `refused`, which reads green. So the two lists are compared out
        # loud. A hand-maintained enumeration wants a test that reads it
        # (AGENTS.md > Enumerated lists rot at merges).
        try:
            ok, text = wire.exec_line("help census")
            named = set(re.findall(r"\b([a-z][a-z0-9-]{2,})\b", text))
            claimed = named & set(probes)
            missing = [p for p in probes if p not in named]
            if ok and claimed and missing:
                return fail(
                    "the contract declares census probes the guest's own "
                    f"`help census` does not name: {', '.join(missing)}. One "
                    "of the two lists is wrong, and a gate that swept the "
                    "contract's list would have called a probe nobody serves "
                    "'refused' and read green.", 2)
            log(f"   `help census` on the guest names all {len(probes)} "
                "declared probes")
        except GuestGone:
            raise
        except Exception as e:
            log(f"   [warn] could not cross-check `help census`: {e}")

        before = wire.command("ps")
        procs_before = [r[0] for r in before.get("output", {}).get("ps", [])]
        log(f"   before: {len(procs_before)} processes — "
            + ", ".join(procs_before))
    except WrongGuest as e:
        return fail(str(e), 2)
    except GuestGone as e:
        return fail(f"the guest died before the census even started: {e}")

    log("")
    log("== the sweep: every probe, every page, the way the module pages ==")
    t0 = time.time()
    swept = 0
    for probe in probes:
        cursor = 0
        for page in range(MAX_PAGES):
            try:
                rep = wire.census(probe, cursor)
            except GuestGone as e:
                return fail(
                    f"THE GUEST DIED during `census.request` probe={probe!r} "
                    f"cursor={cursor} (page {page + 1}): {e}\n"
                    f"  {swept} probes completed before it: "
                    + ", ".join(probes[:probes.index(probe)]))
            if rep.get("type") != "census.report":
                return fail(f"probe {probe!r} answered {rep.get('type')!r} "
                            "rather than a census.report")
            rows = rep.get("rows", [])
            outcome = rep.get("outcome")
            if not rep.get("more"):
                log(f"   {probe:<10} {outcome:<8} {len(rows)} rows"
                    + (f" (+{page} more pages)" if page else ""))
                break
            cursor = rep.get("cursor", rep.get("nextCursor", cursor + 1))
        else:
            return fail(f"probe {probe!r} never cleared `more` in "
                        f"{MAX_PAGES} pages — the pagination does not terminate")
        swept += 1
    log(f"   all {swept} probes swept in {time.time() - t0:.1f}s")

    log("")
    log("== after the sweep: is the machine still there? ==")
    try:
        wire.alive(" after the census sweep")
        log("   the Workshop ANSWERED — the event loop is still turning")
    except GuestGone as e:
        return fail(f"the census completed and then the Workshop stopped "
                    f"answering: {e}")

    try:
        after = wire.command("ps")
        procs_after = [r[0] for r in after.get("output", {}).get("ps", [])]
    except GuestGone as e:
        return fail(f"the guest died answering `ps` after the sweep: {e}")

    # THE FURNITURE, not every process. The first version of this check
    # asked that NO process present before the sweep was missing after it,
    # and went red on `tbt-runner` — a rig instrument that legitimately
    # comes and goes while a lane works. A gate that cries at ordinary
    # churn gets its result explained away, which is the failure mode that
    # costs most: the next red is read as the same noise.
    #
    # So it names what MUST survive. NOW itself, because that is the
    # symptom. The Finder, because the human's second report was that the
    # Finder crashed. And the Application Switcher, because "I tried
    # selecting the app switcher and it crashed Finder" is the sentence
    # this arc is answering — it IS a process, it IS in `ps`, and its
    # disappearance is therefore checkable here rather than only by a
    # person clicking. (Selecting it from the Application menu is still
    # NOT covered; see this file's header. Present is not the same as
    # usable.)
    must_survive = ["New Old World", "Finder", "Application Switcher"]
    lost = [p for p in must_survive
            if p in procs_before and p not in procs_after]
    if lost:
        return fail(f"gone after the census: {', '.join(lost)}. These are the "
                    "machine's own furniture, not rig instruments — the "
                    "census took them down with it.")
    absent = [p for p in must_survive if p not in procs_before]
    if absent:
        log(f"   [warn] not running before the sweep either, so not checked: "
            + ", ".join(absent))
    churn = [p for p in procs_before if p not in procs_after and p not in lost]
    log(f"   after:  {len(procs_after)} processes; "
        + ", ".join(p for p in must_survive if p in procs_after)
        + " all still there"
        + (f" (rig churn, not checked: {', '.join(churn)})" if churn else ""))

    if a.anchor:
        ok, why = anchor_answers(a.anchor)
        if ok is None:
            log(f"   [warn] the anchor could not be checked: {why}")
        elif not ok:
            return fail(
                f"NOW survived and the ANCHOR WORKER did not: {why}. The "
                "anchor is a separate process; when it stops answering, the "
                "damage escaped the application that caused it — which is "
                "how the Finder came to crash under a human's hands.")
        else:
            log(f"   {why} — the damage did not escape NOW's process")

    log("")
    log("CENSUS GATE PASSED: every probe, every page, and the machine is "
        "still answering.")
    log("  Not covered, and this is not a caveat but a hole: the App "
        "Switcher / Application-menu path. See this file's header.")
    wire.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
