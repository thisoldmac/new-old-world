#!/usr/bin/env python3
"""G1: the act pump must not be deployable-forgettable.

`act_session.c :: session_find_pump` finds the pump beside the
application by walking the app's own folder for creator `'NWpu'` — never
by name. Until this test's fix, `tools/stage-ext.py` staged the
extension and, optionally, the application, and stopped there: nothing
in the repository put the pump anywhere, so a stock spin-up (and a real
PowerBook deploy) produced a machine whose click plane could never work.
The acceptance pass that found this had to stage `now-pump.bin` in by
hand to measure anything at all (docs/open-issues.md, "The act pump
exists and has never run").

None of `tools/stage-ext.py` can run here — it drives a live anchor
worker over a socket the moment it is imported. What IS legible from
here is the source text, the same reasoning `act_bind_status_source_test.py`
gives for gating C source this way; a Python script is no different.

Four checks:

  1. `NOW_PUMP_BIN` exists as a name the script reads from the environment.
  2. Staging the application (`APP_BIN` truthy) REQUIRES the pump — there
     is no path that stages `APP_BIN` without first checking `PUMP_BIN`.
  3. The pump is actually pushed to the guest and verified as type
     'APPL' — the same fork-size verification the app and extension
     already get, not a bare copy.
  4. The pushed pump's creator is checked against 'NWpu' — the identity
     `session_find_pump` matches on. A file with the right name and the
     wrong creator is invisible to that walk.

MUTATION WATCH: delete the `if not PUMP_BIN or not os.path.isfile(PUMP_BIN):
raise SystemExit(...)` guard (or move it outside the `if APP_BIN:` block
so it no longer gates the app's own staging) and check 2 must fail, by
name, rather than some other check noticing indirectly.

Run with: python3 pump_staging_source_test.py
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "stage-ext.py"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


text = SRC.read_text()

# 1. NOW_PUMP_BIN is read from the environment, the same way NOW_APP_BIN
#    and NOW_EXT_BIN are.
check(re.search(r'PUMP_BIN\s*=\s*os\.environ\.get\(\s*"NOW_PUMP_BIN"',
                text) is not None,
      "stage-ext.py no longer reads NOW_PUMP_BIN from the environment")

# 2. Staging the app requires the pump: the `if APP_BIN:` block must
#    raise SystemExit when PUMP_BIN is missing, BEFORE it pushes the app.
#    Written as: find the `if APP_BIN:` block's body and check the guard
#    appears in it, ahead of the app's own push_verified call.
app_block = re.search(r"if APP_BIN:\n(.*?)(?=\n\S|\Z)", text, re.DOTALL)
check(app_block is not None, "stage-ext.py no longer has an `if APP_BIN:` "
      "block at all")
if app_block:
    body = app_block.group(1)
    guard = re.search(
        r"if\s+not\s+PUMP_BIN\s+or\s+not\s+os\.path\.isfile\(PUMP_BIN\)"
        r"\s*:\s*\n\s*raise SystemExit\(", body)
    check(guard is not None,
          "staging APP_BIN no longer requires PUMP_BIN - an app can be "
          "staged with no pump beside it again, which is the exact gap "
          "this test exists to close")
    if guard:
        # The guard's start offset must be BEFORE the app's own
        # push_verified call, not after - a check that runs once the app
        # is already on the guest is too late to prevent the half-deploy.
        push_idx = body.find("push_verified(f\"{DEV}:{APP_NAME}\"")
        check(push_idx == -1 or guard.start() < push_idx,
              "the PUMP_BIN guard runs AFTER the application is already "
              "pushed - a partial deploy would leave the app staged with "
              "no pump and no error")

# 3. The pump is pushed and verified as an application, not merely copied.
#    The distance-bounded DOTALL match (not `[^)]*`) is deliberate: the
#    call's own arguments contain closing parens of their own
#    (`open(...).read()`), so a class that stops at the first `)` would
#    never reach `want_type` at all and this check would be unfalsifiable.
check('push_verified(f"{DEV}:{PUMP_NAME}"' in text,
      "no push_verified(...) call stages the pump under PUMP_NAME")
pump_push = re.search(
    r'push_verified\(f"\{DEV\}:\{PUMP_NAME\}".{0,200}?want_type="APPL"',
    text, re.DOTALL)
check(pump_push is not None,
      "the pump's push_verified(...) call does not assert want_type="
      "\"APPL\" - the pump must be verified by fork size AND type like "
      "the app and extension, not pushed and trusted")

# 4. The staged pump's creator is checked against the pump's own identity,
#    'NWpu' - the value session_find_pump (act_session.c) matches on. A
#    pump landed under the wrong Finder identity would be invisible to
#    that walk, the same way a wrongly-tagged extension is invisible to
#    peek.c - checked the identical way, just below that check.
creator_check = re.search(
    r'st\.get\("creator"\)\s*not in\s*\(None,\s*"NWpu"\)', text)
check(creator_check is not None,
      "the pump's staged creator is not compared against 'NWpu' the same "
      "way the extension's creator is compared against 'NOWx' above it")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    raise SystemExit(f"{len(failures)} failure(s)")
print("pump_staging_source: ok")
