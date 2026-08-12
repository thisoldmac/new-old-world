#!/usr/bin/env python3
"""Pin the passive ADB observer's register ABI and interrupt boundary."""

import os
from pathlib import Path


ROOT = Path(os.environ.get("NOW_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
C_SOURCE = (ROOT / "ext/src/now_ext_adb_observer.c").read_text()
ASM = (ROOT / "ext/src/now_ext_adb_observer.S").read_text()
CONTINUITY = (ROOT / "ext/src/now_ext_continuity.c").read_text()
CMAKE = (ROOT / "ext/CMakeLists.txt").read_text()
CONTRACT = (ROOT / "contract/peek_table.h").read_text()


def body(source: str, name: str) -> str:
    start = source.index(name)
    opening = source.index("{", start)
    depth = 0
    for offset, character in enumerate(source[opening:], opening):
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:offset + 1]
    raise ValueError(f"unterminated function: {name}")


begin = body(C_SOURCE, "void now_ext_adb_observer_begin(")
end = body(C_SOURCE, "void now_ext_adb_observer_end(")
install = body(C_SOURCE, "static int install_observer(")
start = body(C_SOURCE, "void now_ext_adb_observer_start(")
stop = body(C_SOURCE, "void now_ext_adb_observer_stop(")
finish = body(CONTINUITY, "static void finish_locked(")
epoch = body(CONTINUITY, "static void start_epoch_locked(")
failures = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


check("kNowPeekContinuityFormatV7" in CONTRACT
      and "kNowPeekContinuityFormatV7" in CONTINUITY,
      "the active observer tail is no longer gated by one V7 format")
check("now_ext_adb_observer.c" in CMAKE
      and "now_ext_adb_observer.S" in CMAKE,
      "the observer and its register shim are not linked together")
check("movem.l %d0-%d7/%a0-%a6,-(%sp)" in ASM
      and ASM.count("movem.l (%sp)+,%d0-%d7/%a0-%a6") == 2,
      "the ADB wrapper no longer preserves the incoming and incumbent frames")
check("move.l %d0,-(%sp)" in ASM and "move.l %a0,-(%sp)" in ASM,
      "the wrapper no longer passes the original command and packet to C")
check("movea.l gNowADBObserverOriginalHandler,%a1" in ASM
      and "jsr (%a1)" in ASM,
      "the wrapper no longer invokes the incumbent under its A1 identity")
check("replacement.siDataAreaAddr = gOriginalDataArea" in install,
      "installation no longer preserves the incumbent A2 data area")
check("found.dbServiceRtPtr" in install
      and "gNowADBObserverOriginalHandler = found.dbServiceRtPtr" in install,
      "installation no longer captures the exact incumbent handler")
check("candidate.origADBAddr != 3" in install,
      "the observer no longer identifies relative devices by original address")
check("matches != 1" in install,
      "ambiguous relative devices no longer fail closed")
check("gNowADBObserverOriginalHandler = NULL" not in install,
      "an uncertain SetADBInfo result can discard the live incumbent")
check("current_handler_is(gNowADBObserverOriginalHandler)" in install,
      "an install retry can wrap an unexpected competing handler")
check("entry->seq = 0" in begin,
      "a ring entry is not invalidated before interrupt-time overwrite")
check("entry->seq = gTraceSeq" in end
      and end.index("entry->seq = gTraceSeq")
          > end.index("snapshot_after(entry)"),
      "the observer no longer commits a complete after-snapshot last")
check("gRecording = false" in stop,
      "disarm no longer withdraws observer recording authority")
check("SetADBInfo" not in stop,
      "disarm attempts to unlink a potentially extended ADB chain")
check("now_ext_adb_observer_start(" in epoch
      and "kNowPeekContinuityTrackingVirtualADB" in epoch,
      "a Continuity epoch no longer starts passive ADB observation")
check("now_ext_adb_observer_stop()" in finish,
      "Continuity authority exit no longer stops ADB recording")
check("now_adb_injection_rewrite" in begin,
      "the active ADB experiment bypasses the bounded packet transform")
check("kNowPeekContinuityTrackingVirtualADB" in epoch,
      "virtual ADB no longer requires an explicit epoch option")
check("gPhysicalSeq++" in begin,
      "physical ADB packets no longer publish an exact takeover sequence")
check("now_ext_adb_observer_physical_seq" in CONTINUITY,
      "virtual ADB takeover fell back to downstream RawMouse guessing")
check(epoch.index("gNativeInputBaseline = gNativeInputSeq")
      < epoch.index("now_ext_adb_observer_start("),
      "ADB recording can begin before the physical-packet baseline exists")
check("kNowPeekContinuityTrackingVirtualADB" in CONTINUITY
      and "cell->request_position_seq = position_seq" in CONTINUITY,
      "virtual ADB no longer has an explicit Cursor Device bypass")

for forbidden in ("SetADBInfo", "GetADBInfo", "CountADBs", "GetIndADB",
                  "NewPtr", "DisposePtr", "malloc", "now_log", "FlushVol",
                  "WaitNextEvent", "PPostEvent", "PostEvent", "ADBOp"):
    check(forbidden not in begin and forbidden not in end,
          f"the interrupt callback reaches forbidden work: {forbidden}")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("ADB observer safety source guard: ok")
