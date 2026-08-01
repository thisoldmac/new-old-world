#!/usr/bin/env python3
"""G1: a stock spin-up must not be able to produce a silent half-machine.

Staging the pump (`pump_staging_source_test.py`) closes half the gap;
this closes the other half. `scripts/spin-up-ppc` already asks the wire
for `actselftest` after every boot - a staged file surviving a reboot is
not proof the pump LAUNCHED, and until this fix nothing read the one
verb that says so (`actstate`, `now-guest-ppc/src/machine/mach_actstate.c`).
A pump that was staged wrong, or never staged, would leave `Pump` reading
`never attached` and the spin-up would still exit 0.

`scripts/spin-up-ppc` cannot be RUN here - it drives QEMU and a lab
anchor worker this checkout does not own, and the ground rules for this
change forbid touching a VM or emulator to verify it. What IS legible is
its source text, the same reasoning the C source-gate tests already give
for the code they read rather than execute.

Five checks:

  1. The script requires an act-pump build artifact (`PUMP_BIN` or
     `NOW_PUMP_BIN`) to exist before it boots anything, the same way it
     already requires `EXT_BIN` and `APP_BIN`.
  2. It passes that artifact to `tools/stage-ext.py` (`NOW_PUMP_BIN=`),
     so staging without a pump - the exact bug this whole lane exists to
     fix - cannot happen through this path either.
  3. The wire check asks the guest for `actstate` (not only `actselftest`),
     so the pump's own row is actually on the wire to be judged.
  4. Something in the script FAILS (raises the process's exit code) when
     the actstate reply shows no `"Pump"` row at all - the pump-region-
     absent case, an extension built before the handshake.
  5. Something in the script ALSO fails when the `Pump` row itself reads
     `never attached` - staged wrong, or never staged, or never launched.
     Distinct from (4): an extension can be current while the pump
     itself is missing or never started, and collapsing the two would
     hide which half of the machine is broken.

Each failure path must NAME THE PUMP: a bare "gate failed" is exactly the
opaque-sentence problem `actstate` itself was written to get away from.

MUTATION WATCH: replace `if "Pump" not in rows:` with `if False:` (or
delete the block) and check 4 must fail, by name. Same for the
`rows["Pump"] == "never attached"` branch and check 5.

Run with: python3 spinup_pump_assert_source_test.py
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "scripts" / "spin-up-ppc"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


text = SRC.read_text()

# 1. A pump artifact is required before boot, like EXT_BIN and APP_BIN.
check(re.search(r'PUMP_BIN="\$\{NOW_PUMP_BIN:-', text) is not None,
      "spin-up-ppc no longer resolves a PUMP_BIN the way it resolves "
      "EXT_BIN and APP_BIN")
check(re.search(r'\[\s*-f\s*"\$PUMP_BIN"\s*\]\s*\|\|', text) is not None,
      "spin-up-ppc no longer checks that the act pump artifact exists "
      "before booting anything - a missing build would only be noticed "
      "much later, if at all")

# 2. It is threaded through to tools/stage-ext.py, not just checked and
#    dropped.
check(re.search(r'NOW_PUMP_BIN="\$PUMP_BIN"', text) is not None,
      "spin-up-ppc resolves PUMP_BIN but never passes NOW_PUMP_BIN to "
      "tools/stage-ext.py - the app would still be staged without its "
      "pump")

# 3. actstate is actually asked over the wire, alongside actselftest.
wire_call = re.search(r"askguest\.py.*?actselftest\s+actstate", text,
                       re.DOTALL)
check(wire_call is not None,
      "the wire check no longer asks the guest for 'actstate' - the "
      "pump's own row (Pump / Pump region) would never be on the wire "
      "to judge")

# 4 & 5. Something fails, naming the pump, for BOTH the absent-region and
# never-attached cases. Grepped as text rather than executed: the check
# lives inside an embedded python heredoc that calls sys.exit(...) with a
# message, which is this script's own way of failing loudly with a name
# (see how every other guard clause in this file, and in
# tools/stage-ext.py, already does it).
region_absent = re.search(
    r'if\s+"Pump"\s+not in\s+rows\s*:\s*\n\s*sys\.exit\(', text)
check(region_absent is not None,
      "no branch fails when the actstate reply has no 'Pump' row at all "
      "- an extension built before the pump handshake would read as a "
      "clean spin-up")
if region_absent:
    check("pump" in text[region_absent.start():region_absent.start() + 400]
          .lower(),
          "the pump-region-absent failure does not name the pump in its "
          "message - a bare gate failure here is the same opaque-"
          "sentence problem actstate exists to get away from")

never_attached = re.search(
    r'if\s+rows\["Pump"\]\s*==\s*"never attached"\s*:\s*\n\s*sys\.exit\(',
    text)
check(never_attached is not None,
      "no branch fails when actstate's Pump row reads 'never attached' - "
      "a pump that is staged wrong, or never staged, or never launched "
      "would read as a clean spin-up")
if never_attached:
    check("pump" in
          text[never_attached.start():never_attached.start() + 400].lower(),
          "the pump-never-attached failure does not name the pump in "
          "its message")

# The pump check's exit code must actually be able to turn the script's
# own exit code non-zero - a check that runs but is discarded is not a
# gate.
check(re.search(r"pump_rc=\$\?", text) is not None
      and re.search(r'\[\s*"\$pump_rc"\s*-eq\s*0\s*\]\s*\|\|\s*rc=1',
                    text) is not None,
      "the pump check's own exit status is never folded back into the "
      "script's exit code - a failing pump check could still leave the "
      "spin-up exiting 0")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    raise SystemExit(f"{len(failures)} failure(s)")
print("spinup_pump_assert_source: ok")
