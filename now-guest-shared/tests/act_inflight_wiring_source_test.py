#!/usr/bin/env python3
"""The act wait pumps, and something guards the window it opened.

WHY A SOURCE TEST. `act_client.c` includes Carbon, so neither half of
this can be linked by a host cc: not the pump (`now_wire_pump` is the
whole connection state machine) and not the interlock's placement (it
lives between `now_act_cell` and the five verbs that call it). The latch
ITSELF is executed - now_act_inflight_test.c plays the interleaving
against it - but a latch nothing routes through is a latch that passes
its own test while the plane it guards is unprotected.

WHAT IT PINS, and each of these is a way the trade of 2026-08-06 could
be quietly undone:

  1. `act_yield` calls `now_wire_pump()`. Removing it restores the
     6.6 s / 6634 ms stall and the lapsed anchor lease. It is also the
     line that makes 2-4 necessary at all, so it is asserted first.
  2. `now_act_cell()` refuses while an act is in flight, and does so
     BEFORE handing the pointer out. A guard inside `now_act_submit`
     would fire after act_cmds.c had already written op, control_handle
     and arm_point_h/v into the armed cell.
  3. `now_act_submit` claims and `now_act_withdraw` releases. Without the
     release the plane answers `act-busy` for the rest of the launch;
     without the claim there is no interlock at all.
  4. Every act verb that takes the cell reports `now_act_why_no_cell()`
     rather than a hardcoded `kNowActNoExtension`. That is the
     difference between "this Mac has no NOW Extension - reinstall it
     and reboot" and "wait a moment" - opposite instructions, and the
     first one is expensive to follow.

WHAT IT CANNOT CHECK: that the refusal is the RIGHT policy, or that two
acts ever actually interleave on a Macintosh. Nothing here has run on
metal. docs/no-hijack-criterion.md carries what is unmeasured.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
CLIENT = os.path.join(ROOT, "now-guest-ppc", "src", "act", "act_client.c")
CMDS = os.path.join(ROOT, "now-guest-ppc", "src", "act", "act_cmds.c")
SELFTEST = os.path.join(ROOT, "now-guest-ppc", "src", "machine",
                        "mach_selftest.c")

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def body_of(text, signature):
    """The braced body that follows `signature`, comments and all."""
    start = text.find(signature)
    if start == -1:
        failures.append("%s is not in the source at all" % signature)
        return ""
    open_brace = text.find("{", start)
    if open_brace == -1:
        failures.append("%s has no body" % signature)
        return ""
    depth = 0
    for i in range(open_brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace:i + 1]
    failures.append("%s's body never closes" % signature)
    return ""


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


client = read(CLIENT)
cmds = read(CMDS)
selftest = read(SELFTEST)

# 1 - the pump itself.
yield_body = strip_comments(body_of(client, "static void act_yield(void)"))
check("now_wire_pump()" in yield_body,
      "act_yield no longer pumps the wire - an act that is not taken is "
      "back to holding conn_service off for its whole deadline, and to "
      "lapsing the anchor plane's ten-second owner lease")
check('#include "wire.h"' in client,
      "act_client.c does not include wire.h, so now_wire_pump is not "
      "declared where it is called")

# 2 - the refusal, and its position.
cell_body = strip_comments(body_of(client, "NowPeekActCell *now_act_cell(void)"))
check("now_act_inflight_busy" in cell_body,
      "now_act_cell() does not consult the in-flight latch, so a second "
      "act command dispatched from inside the first one's pump gets the "
      "cell and overwrites an armed request's identity")
check("return NULL" in cell_body,
      "now_act_cell() consults the latch and does not refuse on it")
check('#include "now_act_inflight.h"' in client,
      "act_client.c does not include now_act_inflight.h")

# The internal accessor must exist and must NOT be the guarded one, or
# the act that holds the latch is refused by the latch it is holding.
check("static NowPeekActCell *act_cell_raw(void)" in client,
      "act_client.c has no unguarded accessor, so submit/await/withdraw "
      "would be refused by their own latch")
for owner in ("NowActStatus now_act_submit(",
              "NowActStatus now_act_await_fired(",
              "void now_act_withdraw(void)"):
    body = strip_comments(body_of(client, owner))
    check("act_cell_raw()" in body and "now_act_cell()" not in body,
          "%s reaches the cell through the GUARDED accessor - it holds "
          "the latch, so it would refuse itself" % owner.strip())

# 3 - claim and release.
submit_body = strip_comments(body_of(client, "NowActStatus now_act_submit("))
check("now_act_inflight_claim" in submit_body,
      "now_act_submit does not claim the latch, so nothing is ever in "
      "flight and now_act_cell()'s refusal can never fire")
check("kNowActBusy" in submit_body,
      "now_act_submit does not answer kNowActBusy when the claim fails")
withdraw_body = strip_comments(body_of(client, "void now_act_withdraw(void)"))
check("now_act_inflight_release" in withdraw_body,
      "now_act_withdraw does not release the latch - one act would leave "
      "every later act answering act-busy for the rest of the launch")

# The two-phase gap: if the plane vanishes between submit and await, the
# latch must still come back.
await_body = strip_comments(body_of(client, "NowActStatus now_act_await_fired("))
check("now_act_inflight_release" in await_body,
      "now_act_await_fired can return without releasing the latch when "
      "the plane disappears between the two phases")

# kNowActBusy must have a word and a sentence, like every other status.
code_body = strip_comments(body_of(client, "const char *now_act_status_code("))
msg_body = strip_comments(body_of(client, "const char *now_act_status_message("))
check("kNowActBusy" in code_body and "act-busy" in code_body,
      "kNowActBusy has no case in now_act_status_code - it would answer "
      "the default, `act-refused`, which is a different failure")
check("kNowActBusy" in msg_body,
      "kNowActBusy has no case in now_act_status_message")

# 4 - every verb reports the right reason for a NULL cell.
for name, raw in (("act_cmds.c", cmds), ("mach_selftest.c", selftest)):
    # Comments stripped first: both names appear in the comments that
    # explain them, and counting those would make the check pass on
    # prose rather than on calls.
    text = strip_comments(raw)
    takers = text.count("now_act_cell()")
    check(takers > 0, "%s no longer takes the cell at all" % name)
    whys = text.count("now_act_why_no_cell()")
    check(whys == takers,
          "%s takes the cell %d time(s) but asks why it was refused only "
          "%d time(s) - a busy plane would be reported as a missing NOW "
          "Extension, which sends someone to reinstall working software"
          % (name, takers, whys))

# Every act path must end at now_act_withdraw. ditemact's not-fired exit
# was the one that did not, which was harmless while nothing else could
# reach the cell and is a latch leak now.
ditem = strip_comments(body_of(cmds, "void now_act_run_ditemact("))
not_fired = ditem.find("!g_snap.fired")
check(not_fired != -1, "ditemact no longer checks g_snap.fired")
if not_fired != -1:
    # Between the test and its reply, and no further: a fixed-width
    # window reached past the if-block into the SUCCESS path's withdraw
    # and passed with the mutation in place. Watched, 2026-08-06.
    reply_at = ditem.find("reply_registered_error", not_fired)
    check(reply_at != -1, "ditemact's not-fired exit no longer replies")
    check(reply_at != -1 and "now_act_withdraw()" in ditem[not_fired:reply_at],
          "ditemact's not-fired exit does not withdraw before it replies, "
          "so the latch leaks and every later act answers act-busy")

if failures:
    for line in failures:
        print("FAIL: %s" % line)
    sys.exit(1)
print("ok")
