#!/usr/bin/env python3
"""Pin the three gates on the Finder-selection poll, and where it is called.

The poll sends an Apple Event to another process. Three properties keep
that from being a problem, and none of them can be checked by a host cc:
they are about the Toolbox, the caller, and an ordering.

  1. NO EPOCH, NO POLL. Without a live Continuity epoch this is a
     background process asking the Finder what a person is looking at.
     Continuity is the consent, so the gate is the first thing the poll
     does and it reads the LIVE epoch rather than a local copy - an epoch
     ends by disarm, lease expiry, guest input, resident reset and
     disconnect, and a second notion of live would be wrong in whichever
     of those nobody remembered.

  2. NOT DURING A HELD BUTTON. The Finder answers Apple Events from its
     event loop, and a drag puts it inside the Drag Manager's nested one
     instead - so a poll started mid-gesture waits out the whole gesture.
     That is exactly the starvation the selection stub exists to avoid,
     arriving through the back door.

  3. THE CALLER IS conn_service, NOT THE PUMP. now_wire_pump bounces
     every nested entry, so being reached only from conn_service is what
     guarantees no Apple Event is ever sent from inside a Toolbox loop.
     A call added to now_wire_pump, or to a nested-loop idle proc, would
     put one wait inside another.

Watched failing (2026-08-14) against the mutation each check names, one
at a time and each restored before the next: `if (live_epoch == 0)`
neutered, `if (now_continuity_button_is_down())` neutered, the poll
added to now_wire_pump's bounce path, and the AESend's idle proc
replaced with NULL. Four checks, four distinct failure texts - a guard
watched failing against ONE mutation has only been watched against that
one, and this file makes four claims.
"""

import re
from pathlib import Path


def uncommented(text: str) -> str:
    """Source with comments blanked, newlines kept.

    The lesson is inherited from continuity_nested_pump_source_test.py,
    which passed the very mutation it was written for because the comment
    explaining a call named the call. Every sentence above names an
    identifier the checks below look for, so reading raw text here would
    be that same defect with better prose.
    """

    text = re.sub(
        r"/\*.*?\*/",
        lambda m: re.sub(r"[^\n]", " ", m.group(0)),
        text,
        flags=re.S,
    )
    return re.sub(r"//[^\n]*", "", text)


SRC = Path(__file__).resolve().parents[1] / "src"
POLL_C = uncommented((SRC / "input" / "continuity_selection.c").read_text())
POLL_H = uncommented((SRC / "input" / "continuity_selection.h").read_text())
WIRE = uncommented((SRC / "core" / "wire.c").read_text())


def function_body(text: str, signature: str, where: str) -> str:
    try:
        start = text.index(signature)
    except ValueError:
        raise SystemExit(f"{where}: no function {signature!r}")
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise SystemExit(f"{where}: unterminated function {signature!r}")


poll = function_body(
    POLL_C,
    "int now_continuity_selection_poll(unsigned long live_epoch)",
    "continuity_selection.c",
)

send = function_body(
    POLL_C,
    "static OSErr ask_finder_for_selection(FSSpec *spec, Boolean *found)",
    "continuity_selection.c",
)

# --- 1. no epoch, no poll ------------------------------------------------
if "live_epoch == 0" not in poll:
    raise SystemExit(
        "the selection poll no longer refuses a zero epoch. Without one "
        "this is a background process asking the Finder what a person has "
        "selected, with no consent behind it."
    )

gate = poll.index("live_epoch == 0")
asked = poll.index("ask_finder_for_selection")
if gate > asked:
    raise SystemExit(
        "the selection poll asks the Finder before checking the epoch. "
        "The gate has to come first; an event already sent is not "
        "ungated by a later return."
    )

# The epoch must come from the intake's live value, not a copy kept here.
if "now_continuity_live_epoch" not in uncommented(
    (SRC / "core" / "wire.c").read_text()
):
    raise SystemExit(
        "nothing reads now_continuity_live_epoch, so whatever the poll is "
        "gated on is a second notion of 'an epoch is live' - and an epoch "
        "ends five ways, only some of which call a handler."
    )

# --- 2. not during a held button ----------------------------------------
if "now_continuity_button_is_down" not in poll:
    raise SystemExit(
        "the selection poll no longer checks the held button. The Finder "
        "answers Apple Events from its event loop and a drag puts it in "
        "the Drag Manager's nested one, so a poll mid-gesture waits out "
        "the gesture - the starvation this whole design avoids."
    )

button = poll.index("now_continuity_button_is_down")
if button > asked:
    raise SystemExit(
        "the selection poll asks the Finder before checking the button."
    )

# --- 3. and it is bounded ------------------------------------------------
if "kNowSelectionPollTicks" not in poll or "kNowSelectionPollTicks" not in POLL_H:
    raise SystemExit(
        "the selection poll has no declared cadence. An AESend to another "
        "process is a context switch each way; at the pump's rate that is "
        "thousands a minute for an answer that changes when a human clicks."
    )

# --- 4. the caller ------------------------------------------------------
if "service_continuity_selection();" not in function_body(
    WIRE, "void conn_service(void)", "wire.c"
):
    raise SystemExit(
        "conn_service no longer runs the selection poll, so the stub "
        "stops arriving and a drag has nothing to name."
    )

if "service_continuity_selection" in function_body(
    WIRE, "void now_wire_pump(void)", "wire.c"
):
    raise SystemExit(
        "the selection poll is called from now_wire_pump. That is the "
        "NESTED entry point - the bounce path exists precisely because a "
        "Toolbox loop is already running there - so this would send an "
        "Apple Event and wait for the Finder underneath a machine that is "
        "already waiting for something else."
    )

# --- 5. the send itself never interacts ---------------------------------
if "kAENeverInteract" not in send:
    raise SystemExit(
        "the selection AESend may interact. A Finder that put up a dialog "
        "on our behalf would be a modal nested inside whatever the guest "
        "is doing, which pump.h says wire code must never cause."
    )

if "now_pump_ae_idle()" not in send:
    raise SystemExit(
        "the selection AESend has no idle proc, so the wire stops for the "
        "whole bounded wait. pump.h's rule: any new nested loop pumps."
    )

print("continuity selection gates ok")
