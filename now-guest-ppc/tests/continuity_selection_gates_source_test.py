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

Check 6 gained a half on 2026-08-15: the grab must settle the epoch
transition too, not just the poll. Watched failing against exactly that
mutation - settle_to_epoch removed from now_continuity_selection_grab,
and separately the settle removed from now_continuity_grab_resolve.
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
# The state machine itself lives in now-guest-shared, compiled into both
# guests. The wiring question this file asks spans the two files.
SHARED = uncommented(
    (SRC.parents[1] / "now-guest-shared" / "src"
     / "now_continuity_selection.c").read_text()
)


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
    "static OSErr ask_finder_for_selection(FSSpec *spec, Boolean *found,",
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

# ...WITH EXACTLY ONE PROBE'S EXCEPTION, AND IT MUST BE BOUNDED AND ONE-SHOT.
#
# The gate above is also what made the wrong-file transfer possible: the
# press that selects the thing it drags is the same button-down that closes
# it, so that selection can never be published. The exception is one Apple
# Event per press. Two properties keep it from being the starvation the gate
# exists to prevent, and neither is checkable by a host cc:
#
#   - it is TAKEN, not tested. press_probe_take clears the flags whatever
#     the Finder says, so a Finder that never answers costs one bounded
#     wait per press rather than one per service pass.
#   - it waits on its OWN timeout. The ordinary poll's two seconds inside a
#     live drag is the gate's own failure mode wearing the exception's hat.
if "press_probe_take" not in poll:
    raise SystemExit(
        "the selection poll's held-button exception is gone, so the one "
        "selection a single-gesture select-and-drag creates is the one "
        "selection that can never be published - metal 2026-08-15 17:19, "
        "where the host bound the generation before it."
    )

probe_take = function_body(
    POLL_C, "static int press_probe_take(void)", "continuity_selection.c"
)
if "g_press_probe_armed = 0" not in probe_take:
    raise SystemExit(
        "press_probe_take no longer consumes the probe, so a Finder that "
        "does not answer is asked again every service pass for the length "
        "of a drag. That is the starvation the button gate exists to "
        "prevent, arriving one door further in."
    )

if "kNowSelectionPressProbeTimeout" not in poll:
    raise SystemExit(
        "the press probe no longer bounds its own wait. It runs with the "
        "Finder inside the Drag Manager's nested loop - the ordinary "
        "poll's timeout there is the gate's failure mode with permission."
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

# --- 6. the grant outlives the epoch, and only the epoch ----------------
#
# The arithmetic is watched by now_continuity_selection_test.c on the host
# cc. What cannot be watched there is the WIRING: which of the poll's exits
# hands the grant to the hold, and which of them drops it. Both epoch exits
# must hold; the disconnect must not.
grab = function_body(
    POLL_C,
    "int now_continuity_selection_grab(unsigned long live_epoch,",
    "continuity_selection.c",
)
forget = function_body(
    POLL_C, "void now_continuity_selection_forget(void)",
    "continuity_selection.c",
)

if "settle_to_epoch" not in poll:
    raise SystemExit(
        "the selection poll no longer settles the epoch transition, so "
        "nothing hands the ending epoch's grant to the hold for the "
        "endings no frame announces - lease expiry, a resident reset, the "
        "host walking away. Crossing back ends the epoch by design, so the "
        "exit nobody covers is a held drag refused bad-epoch."
    )

# AND THE GRAB SETTLES TOO, which is the half that cost a metal round.
# The poll runs AFTER the guest dispatches the frames it read in the same
# pass, and a host that stands down for a drag it is still holding sends
# continuity.disarm and continuity.grab together - so the grab is the first
# code to notice the epoch ended. It noticed by answering bad-epoch.
if "settle_to_epoch" not in grab:
    raise SystemExit(
        "the grab no longer settles the epoch transition before deciding. "
        "continuity.disarm and continuity.grab arrive in the same pass and "
        "are dispatched before the poll runs, so a grab that reads the "
        "hold without settling reads an EMPTY hold and refuses bad-epoch - "
        "measured on metal 2026-08-15 01:04, three seconds into a "
        "thirty-second window."
    )

if "now_continuity_selection_settle" not in function_body(
    SHARED,
    "int now_continuity_grab_resolve(NowContinuityStubTable *table,",
    "now_continuity_selection.c",
):
    raise SystemExit(
        "now_continuity_grab_resolve no longer settles before it decides. "
        "The glue calling settle first is not enough on its own: this is "
        "the one decision that can outrun the poll, so there must be no "
        "version of it that a caller can make against a table nobody has "
        "moved yet."
    )

if "now_continuity_grant_release" not in forget:
    raise SystemExit(
        "now_continuity_selection_forget no longer releases the grant. It "
        "is called when the LINK drops, and consent is given to one host "
        "over one connection - a grant surviving a reconnect would let "
        "the next session collect a drag the previous one set up."
    )

if "release_grant_for_new_epoch" not in poll:
    raise SystemExit(
        "nothing releases the held grant when a new epoch publishes its "
        "own selection, so the clock is the only backstop and a grant "
        "outlives the gesture it was held for."
    )

if "now_continuity_grab_resolve" not in grab:
    raise SystemExit(
        "the grab no longer consults the held grant, so a drag released "
        "after the crossing that ended its epoch is refused bad-epoch - "
        "the round-2 metal symptom this rule exists to answer."
    )

# --- 7. and the serve is confirmed against the machine ------------------
#
# THE ONLY CHECK THAT ASKS THE FINDER. Every other check in this file and in
# now_continuity_selection.c reasons over a table this side wrote earlier;
# none of them can notice it stopped describing what the person is holding.
# Metal 2026-08-15 17:19: main.c was dragged, hello.txt was transferred, and
# every consent rule was satisfied throughout.
#
# The arithmetic is watched in now_continuity_selection_test.c. What cannot
# be watched there is that the grab actually CALLS it, and calls it before
# the stub becomes a real FSSpec.
if "confirm_serve_against_finder" not in grab:
    raise SystemExit(
        "the grab no longer confirms its serve against the Finder. Every "
        "consent check it makes reads a table this side wrote earlier, so "
        "a grab naming a generation the guest still holds can still name a "
        "file the person stopped holding - which is how hello.txt crossed "
        "the edge on 2026-08-15 while main.c was being dragged."
    )

if grab.index("confirm_serve_against_finder") > grab.index("FSMakeFSSpec"):
    raise SystemExit(
        "the grab resolves the FSSpec before confirming the serve. The "
        "confirmation has to stand between the stub and the disk, not "
        "beside it."
    )

confirm = function_body(
    POLL_C,
    "static int confirm_serve_against_finder(const NowContinuityStubItem *serve)",
    "continuity_selection.c",
)
if "ask_finder_for_selection" not in confirm:
    raise SystemExit(
        "the grab confirmation no longer asks the Finder. Confirming a "
        "cache against itself is not a confirmation."
    )
if "now_continuity_grab_confirm" not in confirm:
    raise SystemExit(
        "the grab confirmation no longer runs the shared verdict, so the "
        "case the host cc watches - an unreadable Finder refuses too - is "
        "not the case this path takes."
    )

if "grant honored after epoch" not in POLL_C or "grant expired" not in POLL_C:
    raise SystemExit(
        "the two grant outcomes are no longer named in the log. A grab "
        "served after its epoch ended and one refused for arriving late "
        "are the only evidence this rule is working or not."
    )

print("continuity selection gates ok")
