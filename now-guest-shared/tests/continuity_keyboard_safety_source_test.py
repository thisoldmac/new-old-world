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

# V13 KeyMap co-write: a co-write, never ownership. Only the four modifier
# bits move, only bits WE set are cleared (the remembered word scopes the
# clear), and the flush path clears through the same word so no epoch can
# leak a held modifier into the machine's real keyboard state.
check(KEYBOARD.count("gKeyMapLM") == 5
      and "gKeyMapLM" not in SERVICE,
      "the KeyMap co-write escaped its unit or grew writers")
check("(gKeyMapLM[6] & ~prev6) | now6" in KEYBOARD
      and "(gKeyMapLM[7] & ~prev7) | now7" in KEYBOARD,
      "the co-write clears bits it did not set")
check("keymap_costamp(0);" in KEYBOARD
      and KEYBOARD.index("now_continuity_keyboard_resident_flush(cell);")
          < KEYBOARD.index("keymap_costamp(0);"),
      "an epoch end no longer clears the stamped modifier bits")
check("0x0080 | (cell->host_modifiers" in SERVICE,
      "the synthetic mouse-up lost live modifiers or its btnState bit")

print("continuity_keyboard_safety_source_test: ok")
