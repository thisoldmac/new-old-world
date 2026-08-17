#!/usr/bin/env python3
"""The liveness channel's wedge deadline, guarded at the source.

The resident reaps its MacTCP calls by polling `ioResult`, and until
2026-08-17 nothing ever decided a poll had gone on too long. One call the
driver never completed left the pump returning at its one-call-at-a-time
guard for the rest of the boot: no ping, no redial, no drag-begin frame,
and no way back without rebooting the machine. An attended metal session
produced zero resident frames because of it (F2 defect A).

Every property below is a property of the SOURCE rather than of any run,
because the failure it prevents is invisible in a healthy run by
construction: a channel with no deadline behaves exactly like a channel
with one until the day a driver stops answering.

Each check names the mutation it catches.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = (ROOT / "contract/peek_table.h").read_text()
NET = (ROOT / "ext/src/now_liveness_net.c").read_text()

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def strip_comments(source: str) -> str:
    return re.sub(r"/\*.*?\*/", "", source, flags=re.S)


def body(source: str, start_name: str, end_name: str) -> str:
    start = source.index(start_name)
    end = source.index(end_name, start)
    return source[start:end]


CODE = strip_comments(NET)

# THERE IS A DEADLINE AT ALL. The whole defect in one check.
check("wedge_watch" in CODE, "the wedge watch is gone: an in-flight "
      "MacTCP call has no deadline again, which is the defect that cost "
      "a whole attended metal session")

# EVERY ISSUE PATH RESTARTS THE CLOCK. A path that queues a call without
# resetting the tick count inherits its predecessor's age and either
# convicts a healthy call or, if the count is never reset anywhere, only
# ever fires once.
for issuer in ("issue_send", "issue_open", "issue_abort"):
    fragment = body(CODE, "static void " + issuer, "\n}\n")
    check("gInFlightTicks = 0;" in fragment,
          f"{issuer} queues a call without restarting the deadline clock")

# THE WATCH RUNS BEFORE THE GUARD IT EXISTS TO BREAK. Placed after the
# one-call-at-a-time return, it would be unreachable in exactly the state
# it is for.
pump = body(CODE, "void now_liveness_net_pump", "\n}\n")
watch_at = pump.index("wedge_watch(table);")
guard_at = pump.index("if (gInFlight != kInFlightNone)")
check(watch_at < guard_at,
      "the wedge watch runs after the one-call-at-a-time guard, so it "
      "can never run while a call is stuck - which is its only job")

# THE RECOVERY DOES NOT WRITE THE PARAM BLOCK THE DRIVER STILL OWNS.
# A wedge is by definition a call MacTCP has not finished with; filling
# in gCtlPB to abort it is a corruption rather than a race to argue
# about, and it is the same reason gDragPB exists.
wedge_abort = body(CODE, "static void issue_wedge_abort", "\n}\n")
check("gWedgeAbortPB" in wedge_abort and "gCtlPB" not in wedge_abort,
      "the wedge recovery writes gCtlPB, the very block the driver is "
      "still holding")
check("gConnected = false;" in wedge_abort
      and "gHelloSent = false;" in wedge_abort,
      "the wedge recovery leaves the channel claiming a connection, so "
      "the drag path would hand frames to a stream nobody can use")

# NO TEARDOWN FROM THE TICK. TCPRelease/TCPCreate need a context this
# component only has at boot, and the teardown class has cost this
# project real machines. The pump must never reach for either.
for pump_fn in ("void now_liveness_net_pump", "static void wedge_watch"):
    fragment = body(CODE, pump_fn, "\n}\n")
    check("TCPRelease" not in fragment and "TCPCreate" not in fragment,
          f"{pump_fn.split()[-1]} releases or creates a stream at "
          f"interrupt time")
check("PBControlSync" not in body(CODE, "static void wedge_watch", "\n}\n"),
      "the wedge watch blocks on a synchronous call at interrupt time")

# A RECEIVE THAT OUTLIVED ITS CONNECTION BLOCKS THE RE-OPEN. MacTCP
# refuses an ActiveOpen while one is pending, so dialling anyway is an
# endless retry loop that can never connect - the shape the defect took
# whenever it did not present as silence.
open_fn = body(CODE, "static void issue_open", "\n}\n")
check("if (gRcvInFlight)" in open_fn,
      "issue_open dials over a pending receive, which MacTCP refuses - "
      "an infinite failing-redial loop")

# THE DEADLINES SIT OUTSIDE THE TRANSPORT'S OWN TIMEOUT. Every call
# carries ulpTimeoutValue = 30, so a deadline at or under 30 s starts
# aborting calls the driver was still honestly working on, and healthy
# calls are what carry liveness. The tick is 5 s.
for name, floor in (("kInFlightWedgeTicks", 7), ("kAbortWedgeTicks", 3),
                    ("kRcvSettleTicks", 3)):
    match = re.search(name + r"\s*=\s*(\d+)", CODE)
    check(match is not None, f"{name} is gone")
    if match:
        check(int(match.group(1)) >= floor,
              f"{name} is tighter than the transport timeout it is "
              f"supposed to sit outside, so healthy calls will be aborted")

# THE ACCOUNT. The resident does not log, so a number here is the only
# story it can tell. One counter cannot separate "we noticed a wedge"
# from "we got the machine back" from "it dialled again", and those are
# the three facts a drill has to read apart.
for counter in ("channel_wedge_format", "channel_wedges",
                "channel_wedge_reaps", "channel_redials",
                "channel_wedge_op", "channel_wedge_ticks"):
    check(f"NowPeekU32 {counter};" in CONTRACT and counter in CODE,
          f"the channel lost the counter that names one of its wedge "
          f"outcomes: {counter}")
check("kNowPeekChannelWedged" in CODE,
      "a wedged channel reports itself as failed, which is a call that "
      "COMPLETED with an error - the opposite of a call still held")

# THE DRAG FRAME IS REAPED WHEN THE CONNECTION GOES, AND ONLY THEN. The
# read is safe because send_drag returns before touching anything while
# gConnected is false, so there is no task-time writer to race.
check(re.search(r"if \(!gConnected\) \{\s*(?:/\*.*?\*/\s*)?drag_reap\(\);",
                NET, flags=re.S) is not None,
      "the pump reaps the task-time drag param block outside the "
      "!gConnected guard that makes the read race-free")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)
print("liveness net deadline source guard: ok")
