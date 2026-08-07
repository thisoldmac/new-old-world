#!/usr/bin/env python3
"""`ctlact` may not conclude "nothing happened" from a silent trap patch.

WHY A SOURCE TEST. `act_cmds.c` and `act_client.c` both include Carbon,
so neither can be linked by a host cc, and nothing else in this tree
reads the verdict a verb writes. The runtime alternative is a metal or
emulator drive per change, which is how this defect shipped for a day.

WHAT WENT WRONG, MEASURED. Fidelity sweep D, 2026-08-07, SEQ-A step 4:
the Appearance panel's help "?" button, pressed with `ctlact part: 11`,
answered

    act-not-taken / "armed, and the application never called
    TrackControl" / settlement: timed-out

and the guest's own screendumps show no Help Viewer before the press and
Mac Help frontmost, having run a search for "Appearance" with ten
results, after it. The press LANDED. A Carbon control actuated by any
route other than TrackControl - and a Help button on CarbonLib is a prime
candidate - lands while that arm reports a refusal.

WHY IT IS WORSE THAN A WRONG WORD. An agent that believes a refusal
presses again, and the second press lands too. A false negative in an act
plane produces duplicated actions, which is a correctness problem rather
than a reporting one; on a destructive verb it is worse than a crash.

WHAT IS PINNED HERE, and each of these is one edit away from coming back:

  1. `now_act_run_ctlact` does not reply `act-not-taken` anywhere. There
     is nothing left on that path that could positively establish the
     absence - a refusing plane, a request that never reached the machine
     and an unresolvable reference all return earlier with their own
     status - so the code is removed rather than narrowed.
  2. The `part != 0` wait is declared NON-terminal
     (`now_act_await_fired(&g_snap, 0)`), so the expiry records
     `dispatched-but-unconfirmed` rather than latching the terminal
     `timed-out` over evidence the control watch has not gathered yet.
  3. Every other `now_act_await_fired` call states its terminality
     explicitly. The parameter exists so a caller cannot behave like one
     kind and settle like the other, which is exactly what ctlact did.
  4. `act_client.c` actually branches on it, rather than taking the flag
     and writing `timed-out` regardless.

WHAT THIS CANNOT CHECK: whether the reply is TRUE on a machine. Only a
drive can say that, and one is recorded in docs/known-wrong.md's history
and docs/open-issues.md.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CMDS = os.path.join(HERE, "..", "src", "act", "act_cmds.c")
CLIENT = os.path.join(HERE, "..", "src", "act", "act_client.c")

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def function_body(text, signature, path):
    """From a function's signature to the closing brace in column 1."""
    start = text.find(signature)
    if start == -1:
        failures.append("%s is not in %s at all - this test is reading a "
                        "file that has moved, and would otherwise pass by "
                        "looking at nothing" % (signature, path))
        return ""
    end = text.find("\n}", start)
    return text[start:end if end != -1 else len(text)]


def strip_comments(text):
    """Block comments only - the arguments here are written in them."""
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.S)


def main():
    with open(CMDS, "r") as handle:
        cmds = handle.read()
    with open(CLIENT, "r") as handle:
        client = handle.read()

    ctlact = strip_comments(
        function_body(cmds, "void now_act_run_ctlact(", "act_cmds.c"))
    if not ctlact:
        return report()

    # 1. The verdict itself.
    check('"act-not-taken"' not in ctlact,
          "now_act_run_ctlact replies act-not-taken again. That verdict is "
          "an INFERENCE from one missing trap call phrased as a conclusion "
          "about the machine, and sweep D caught it over a press that "
          "opened Mac Help. Everything that could positively establish "
          "the absence returns earlier with its own status; where the "
          "silent patch is the only evidence, the verdict is "
          "dispatched-but-unconfirmed")
    check("TrackControl" not in ctlact
          or "never called TrackControl" not in ctlact,
          "the sentence \"never called TrackControl\" is back as a "
          "verdict. Naming the silent witness is right - it belongs in "
          "the Mechanism row as an ABSENCE - but not as the reason for a "
          "refusal")

    # 2. The wait that produced it is non-terminal.
    check(re.search(r"now_act_await_fired\(&g_snap,\s*0\)", ctlact)
          is not None,
          "now_act_run_ctlact no longer waits with timeout_is_terminal 0. "
          "It goes on to watch the control itself, so the patch's silence "
          "settles nothing - passing 1 latches `timed-out` over the very "
          "evidence the watch below exists to gather")

    # 3. No caller may leave it unsaid.
    calls = re.findall(r"now_act_await_fired\(([^;]*?)\)\s*;",
                       strip_comments(cmds))
    check(len(calls) >= 3,
          "only %d now_act_await_fired call(s) found in act_cmds.c - the "
          "pattern has stopped matching and this check would pass by "
          "looking at nothing" % len(calls))
    for call in calls:
        check("," in call,
              "now_act_await_fired(%s) states no terminality. The "
              "parameter exists because ctlact behaved like a "
              "non-terminal caller while settling like a terminal one; a "
              "default would put that choice back out of sight"
              % call.strip())

    # 4. And act_client.c honours it.
    await_body = strip_comments(
        function_body(client, "NowActStatus now_act_await_fired(",
                      "act_client.c"))
    if await_body:
        check("timeout_is_terminal" in await_body,
              "now_act_await_fired takes timeout_is_terminal and never "
              "reads it, so every caller's declared terminality is "
              "decoration and the terminal word is written regardless")
        check("kNowActSettleDispatchedUnconfirmed" in await_body,
              "now_act_await_fired can no longer record "
              "dispatched-but-unconfirmed on an expiry, so a non-terminal "
              "caller's wait still latches `timed-out`")

    return report()


def report():
    if failures:
        for line in failures:
            sys.stderr.write("FAIL: %s\n" % line)
        sys.stderr.write("%d failure(s)\n" % len(failures))
        return 1
    print("ctlact_verdict_source: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
