#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = (ROOT / "contract/peek_table.h").read_text()
CORE = (ROOT / "ext/src/now_ext.c").read_text()
KEYBOARD = (ROOT / "ext/src/now_ext_continuity_keyboard.c").read_text()
SERVICE = (ROOT / "ext/src/now_ext_continuity.c").read_text()
INTAKE = (ROOT / "now-guest-ppc/src/input/continuity_intake.c").read_text()
LOGIC = (ROOT / "now-guest-shared/src/now_continuity_keyboard_logic.c").read_text()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


check("kNowPeekContinuityFormatV8" in CONTRACT,
      "keyboard queue must have an explicit resident format")
check("NowPeekContinuityKeyEntry" in CONTRACT
      and "kNowPeekContinuityKeyQueueCapacity = 16" in CONTRACT,
      "keyboard queue must stay bounded in the shared contract")
check("now_ext_continuity_keyboard_gne(table);" in CORE,
      "the global target-context jGNE pass must drain keyboard input")
check("PPostEvent" in KEYBOARD and "evtQModifiers" in KEYBOARD,
      "resident delivery must use PPostEvent and stamp modifiers")
check("kNowContinuityKeyDrainPerPass = 4" in KEYBOARD,
      "one target event pass must have a bounded drain")
check("GetFrontProcess(&front)" in KEYBOARD
      and "event.target_psn_high" in KEYBOARD
      and "event.target_psn_low" in KEYBOARD
      and "now_ext_continuity_keyboard_flush(cell);" in KEYBOARD,
      "a process switch must flush input before PPostEvent")
# The confined interrupt press (deliver_deferred_press_interrupt, pinned in
# continuity_event_safety_source_test.py with its full justification) posts
# MOUSE events from this unit; keys stay banned here in any form.
check("PPostEvent(keyDown" not in SERVICE
      and "PPostEvent(keyUp" not in SERVICE
      and "PPostEvent(autoKey" not in SERVICE
      and "PPostEvent(event_kind" not in SERVICE,
      "the synchronous service and timer translation unit must not post keys")
check("now_continuity_keyboard_flush(shared);" in INTAKE,
      "PPC disarm and disconnect must flush pending keyboard input")
check("slot->queue_seq = next" in LOGIC
      and "cell->key_write_seq = next" in LOGIC,
      "an entry and then queue availability must commit last")
check("cell->key_floor_seq = cell->key_write_seq" in LOGIC,
      "process switch and control release must abandon older entries")

print("continuity_keyboard_safety_source_test: ok")
