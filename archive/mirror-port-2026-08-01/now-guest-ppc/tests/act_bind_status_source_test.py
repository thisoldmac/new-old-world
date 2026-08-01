#!/usr/bin/env python3
"""B5: a Finder bind failure must not read as `no-such-process`.

`now_act_open` binds a target through `now_ax_bind_process`
(src/axwalk/axprocess.c), which answers with one of five
`NowPeekReadStatus` verdicts on anything short of Ok - the same five
`observe.c:bind_status()` already turns into "no-plane" / "no-anchor" /
"ambiguous" / "mismatch" / "unreadable" on the read side. `now_act_open`
used to test only `!= kNowPeekReadOk` and answer `kNowActNoTarget` for
every one of them, so a Finder that had simply not pumped since the
plane armed (NoAnchor - not an error about the machine) read on the wire
exactly like a process that does not exist, and so did the two
recycled-slot verdicts (Ambiguous, Mismatch) a genuine trap-ABI defect
would also produce. Nothing distinguishes "no such process" from "this
looks like a stale extension patch" without running this test's checks.

None of this is reachable from a host cc: `now_act_open` calls
GetProcessInformation, GetFrontProcess and Carbon.h types throughout, so
the file cannot be compiled off a Macintosh. What IS legible from here is
the source text - the same reasoning key_refusal_source_test.py already
gives for gating `key`'s ordering as text rather than as a run.

Four checks, and the first is the one a regression would trip:

  1. `now_act_open`'s bind check no longer discards the verdict - it
     calls now_act_bind_status(bind_st), not a bare `return
     kNowActNoTarget`.
  2. `now_act_bind_status` maps each of the five NowPeekReadStatus cases
     to a DIFFERENT NowActStatus - collapsing any two back together is
     exactly the regression this file exists to catch.
  3. `now_act_status_code` gives each of the four new statuses its own
     wire word, none of them "no-such-process".
  4. `now_act_status_message` gives each of the four new statuses its own
     sentence, none of them the sentence `kNowActNoTarget` uses.

MUTATION WATCH: reintroduce the old line -
`if (now_ax_bind_process(&want, &out->ax) != kNowPeekReadOk) { return
kNowActNoTarget; }` in place of the now_act_bind_status call - and check
1 must fail, by name, rather than some other check noticing indirectly.

Run with: python3 act_bind_status_source_test.py
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "act" / "act_client.c"
HDR = ROOT / "src" / "act" / "act_client.h"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


src_text = SRC.read_text()
hdr_text = HDR.read_text()


def body(signature: str, text: str) -> str:
    start = text.index(signature)
    end = text.index("\n}\n", start)
    return text[start:end]


# 0. The four new statuses actually exist in the header.
NEW_STATUSES = ["kNowActNoPlane", "kNowActAmbiguous", "kNowActMismatch",
                "kNowActUnreadable"]
for name in NEW_STATUSES:
    check(re.search(rf"\b{name}\b\s*,", hdr_text) is not None
          or re.search(rf"\b{name}\b", hdr_text) is not None,
          f"act_client.h no longer declares {name}")

# 1. now_act_open keeps the verdict rather than discarding it.
opened = body("NowActStatus now_act_open(", src_text)
check("now_act_bind_status(" in opened,
      "now_act_open no longer routes a bind failure through "
      "now_act_bind_status - check for a reintroduced bare `return "
      "kNowActNoTarget` on the now_ax_bind_process result")
check(
    re.search(
        r"now_ax_bind_process\([^)]*\)\s*;\s*\n\s*if\s*\(\s*bind_st\s*!="
        r"\s*kNowPeekReadOk\s*\)\s*\{\s*\n\s*return\s+"
        r"now_act_bind_status\(\s*bind_st\s*\)\s*;",
        opened) is not None,
    "now_act_open's bind check must read the now_ax_bind_process result "
    "into a variable and hand it to now_act_bind_status - a direct "
    "`!= kNowPeekReadOk) { return kNowActNoTarget; }` is the exact "
    "regression this test exists to catch")

# 2. now_act_bind_status: five distinct NowPeekReadStatus cases, five
#    distinct NowActStatus results - no two of the five collapsed back
#    onto the same status.
mapper = body("static NowActStatus now_act_bind_status(", src_text)
pairs = re.findall(
    r"case\s+(kNowPeekReadNoPlane|kNowPeekReadNoAnchor|"
    r"kNowPeekReadAmbiguous|kNowPeekReadMismatch|kNowPeekReadUnreadable)"
    r"\s*:\s*return\s+(kNowAct\w+)\s*;",
    mapper)
seen = {verdict for verdict, _ in pairs}
check(seen == {
    "kNowPeekReadNoPlane", "kNowPeekReadNoAnchor", "kNowPeekReadAmbiguous",
    "kNowPeekReadMismatch", "kNowPeekReadUnreadable",
}, f"now_act_bind_status must give all five NowPeekReadStatus verdicts "
   f"their own `case ...: return ...;` line; found {sorted(seen)}")
results = [status for _, status in pairs]
check(len(set(results)) == len(results),
      f"now_act_bind_status maps two different verdicts to the same "
      f"NowActStatus, which is the collapse this test exists to catch: "
      f"{pairs}")

# 3. now_act_status_code: the four new statuses each get their own word,
#    and none of them is the old blanket code.
code_fn = body("const char *now_act_status_code(", src_text)
codes = {}
for name in NEW_STATUSES:
    m = re.search(rf'case\s+{name}\s*:\s*return\s+"([^"]+)"', code_fn)
    check(m is not None, f"now_act_status_code has no case for {name}")
    if m:
        codes[name] = m.group(1)
check("no-such-process" not in codes.values(),
      f"a new bind-failure status still reports the old blanket "
      f"no-such-process code: {codes}")
check(len(set(codes.values())) == len(codes),
      f"two of the four new statuses share one wire code: {codes}")

# 4. now_act_status_message: same shape, for the human sentence.
msg_fn = body("const char *now_act_status_message(", src_text)
no_target_msg = re.search(
    r'case\s+kNowActNoTarget\s*:\s*\n\s*return\s+((?:"[^"]*"\s*)+)',
    msg_fn)
check(no_target_msg is not None,
      "now_act_status_message has no case for kNowActNoTarget")
messages = {}
for name in NEW_STATUSES:
    m = re.search(rf'case\s+{name}\s*:\s*\n\s*return\s+((?:"[^"]*"\s*)+)',
                  msg_fn)
    check(m is not None, f"now_act_status_message has no case for {name}")
    if m:
        messages[name] = "".join(re.findall(r'"([^"]*)"', m.group(1)))
if no_target_msg:
    no_target_text = "".join(re.findall(r'"([^"]*)"', no_target_msg.group(1)))
    check(no_target_text not in messages.values(),
          "a new bind-failure status still uses kNowActNoTarget's own "
          f"sentence: {messages}")
check(len(set(messages.values())) == len(messages),
      f"two of the four new statuses share one message: {messages}")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    raise SystemExit(f"{len(failures)} failure(s)")
print("act_bind_status_source: ok")
