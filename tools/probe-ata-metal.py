#!/usr/bin/env python3
"""Ask a real Macintosh whether its ATA drive will introduce itself.

STANDALONE, read-only, one question. Not part of any gate or harness.

WHY THIS EXISTS
---------------
`census_ata_identify` built a parameter block matching Apple's `ataIdentify`
field for field, with `kAtaFnIdentify = 0x13` correct -- and left
`ataPBFlags` ZERO, so `mATAFlagIORead` was never set. Without that bit the
ATA Manager never drives the data-in phase: the call returns `noErr` with an
empty buffer and leaves the device mid-command. (It also cost every shutdown
its final "volume unmounted" write, which is how it was found.)

So `now-guest-ppc/src/census/census_probes.c` carries this, recorded from
metal on 2026-07-22:

    on the 1400c the manager answers noErr with an EMPTY IDENTIFY buffer
    - the device is present but yields no model/serial, so the row says
      exactly that.

That was never the drive having nothing to say. **Nobody had asked for the
data.** This script re-asks, with the flag set.

WHAT A RESULT MEANS
-------------------
  model/capacity/firmware present -> the 2026-07-22 note is WRONG and the
      source comment plus any finding quoting it should be corrected.
  still empty -> the note was right for a reason other than the flag, and
      that is worth knowing too. A refuted mechanism is a result.

It proves nothing about any other machine: `ata` is one of fourteen probes
and this asks it once, on one Mac.

USAGE
-----
    tools/probe-ata-metal.py --port <wire> [--host <addr>] [--out <dir>]

Requires a guest already running a build with the flag fix. Writes a
timestamped log; prints the path. Never writes to the guest.
"""

import argparse, datetime, json, os, pathlib, subprocess, sys

RECORDED_2026_07_22 = ("the manager answers noErr with an EMPTY IDENTIFY "
                       "buffer - present but no model/serial")

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True, help="the guest's wire port")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--out", default="./ata-probe-logs")
    ap.add_argument("--wait", type=float, default=180.0)
    a = ap.parse_args()

    here = pathlib.Path(__file__).resolve().parent
    askguest = here / "askguest.py"
    if not askguest.exists():
        print(f"no askguest.py beside me at {askguest}", file=sys.stderr)
        return 64

    outdir = pathlib.Path(a.out).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log = outdir / f"ata-{stamp}.log"

    def ask(*verbs):
        """One askguest call. Returns (rc, stdout, stderr) -- never raises."""
        cmd = [sys.executable, str(askguest), "--host", a.host,
               "--port", str(a.port), "--wait", str(a.wait), *verbs]
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    lines = [
        f"# ATA IDENTIFY re-read  {datetime.datetime.now().isoformat(timespec='seconds')}",
        f"# host={a.host} port={a.port}",
        f"# recorded 2026-07-22 (metal, 1400c): {RECORDED_2026_07_22}",
        f"# asking again with mATAFlagIORead set",
        "",
    ]

    # Provenance first: WHICH machine and WHICH build answered. A result
    # from an unidentified guest is not attributable, and on a shared Mac
    # any guest can answer a listener.
    rc, out, err = ask("hello")
    lines += ["## who answered", out.strip() or "(no reply)", err.strip(), ""]
    if rc != 0:
        lines.append(f"## FAILED to reach a guest (rc={rc}) - nothing was asked")
        log.write_text("\n".join(lines) + "\n")
        print(log)
        return 1

    # The question. Kept raw: the row's own text is the answer, and a
    # summariser here would be a second place to be wrong.
    rc, out, err = ask("census --probes ata")
    lines += ["## census --probes ata (raw)", out.rstrip() or "(no output)", ""]
    if err.strip():
        lines += ["## stderr", err.rstrip(), ""]

    # A verdict is offered, never substituted for the raw text above.
    blob = out.lower()
    if rc != 0:
        verdict = f"UNKNOWN - the ask failed (rc={rc}). Not a result about the drive."
    elif "empty" in blob or "no model" in blob:
        verdict = ("STILL EMPTY - the flag was not the reason. The 2026-07-22 "
                   "note stands and its cause is something else.")
    elif any(k in blob for k in ("model", "firmware", "capacity")):
        verdict = ("DRIVE ANSWERED - the 2026-07-22 note is WRONG. Correct the "
                   "comment in now-guest-ppc/src/census/census_probes.c and any "
                   "finding quoting it.")
    else:
        verdict = "UNCLEAR - read the raw text above and decide by hand."

    lines += ["## verdict", verdict, "",
              "## what this does NOT show",
              "one probe of fourteen, asked once, on one machine.",
              "Nothing here is a claim about any other Mac."]

    log.write_text("\n".join(lines) + "\n")
    print(f"{verdict}\n\nlog: {log}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
