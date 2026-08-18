#!/usr/bin/env python3
"""The promise drag's Toolbox rules, which no native test can reach.

``now_continuity_drag_test.c`` runs the whole state machine on the host cc.
What it cannot run is the half that needs a Macintosh, and that half carries
three rules this project has already paid for once each:

  1. **The promise streams inside somebody else's nested loop.**  The
     send-data callback fires while the receiving Finder sits in its own
     drop handling, so our main event loop -- and with it ``conn_service``,
     and with it the transfer the callback is waiting on -- is not running.
     The streaming loop must pump the wire by hand every pass or it waits
     forever for bytes it is itself preventing from arriving.  This is
     pump.h's rule in the one place where the loop being nested inside
     belongs to another application.

  2. **A UPP is not a cast on this runtime.**  ``TARGET_RT_MAC_CFM`` makes a
     UPP a routine descriptor; handing the Drag Manager a bare function
     pointer is a Type 3 the first time it calls back.  Finding
     ``carbon-upp-is-not-a-cast-on-cfm``.

  3. **A drag that never ends wedges the classic Finder.**  Every exit from
     the start path, including the failures, disposes the DragRef.

And one cross-artifact check.  The acts the contract declares for the
``offer`` verb, the acts ``commands.c`` actually handles, and the acts the
console's own help table documents are asserted EQUAL as three sets read
from three different files.  A verb that grew an act in the code and not in
the contract is the defect class this repository names
``two-halves-never-met-in-a-test``; a verb that grew one in the code and not
in ``help`` fails ``CommandParityTests`` -- but only for verbs, not for the
acts inside one, which is the gap this closes.
"""

import re
import sys
from pathlib import Path


def uncommented(text: str) -> str:
    """Source with block comments blanked, newlines kept.

    The same tool ``continuity_nested_pump_source_test.py`` had to invent,
    and for the same reason: that guard once passed the very mutation it was
    written for, because deleting a call left behind the comment explaining
    why the call was there, and the substring search matched the prose.
    """

    return re.sub(
        r"/\*.*?\*/",
        lambda m: re.sub(r"[^\n]", " ", m.group(0)),
        text,
        flags=re.S,
    )


ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "now-guest-ppc" / "src"
DRAGMGR = uncommented((SRC / "input" / "continuity_dragmgr.c").read_text())
COMMANDS = uncommented((SRC / "commands" / "commands.c").read_text())
HELP = (SRC / "commands" / "cmd_help.c").read_text()
CONTRACT = (ROOT / "contract" / "asyncapi.yaml").read_text()

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body_of(source: str, signature: str) -> str:
    """The braced body of the function whose definition starts at `signature`."""

    start = source.index(signature)
    open_brace = source.index("{", start)
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace : i + 1]
    raise AssertionError("unbalanced braces after " + signature)


# --- 1. the streaming promise pumps ------------------------------------------
stream = body_of(DRAGMGR, "static Boolean stream_promise(")
loop_at = stream.index("for (;;)")
loop = stream[loop_at:]

check(
    "now_wire_pump()" in loop,
    "stream_promise's loop must call now_wire_pump(): the Finder's drop "
    "handling has suspended our event loop, so nothing else is servicing "
    "the connection the promised bytes arrive on.",
)
check(
    "now_continuity_pump()" in loop,
    "stream_promise's loop must call now_continuity_pump(): the cursor "
    "plane's lease renews on a different path from the wire's, and a drag "
    "whose pointer froze mid-drop is its own kind of broken.",
)
# The pump must come before the loop can decide to leave, or a pass that
# exits early is a pass that serviced nothing.
#
# GUARDED, because the first mutation run against this file crashed here
# instead of reporting: removing the pump made the check above fail AND made
# this .index() raise, so the run ended in a traceback with no FAIL line. A
# guard that dies instead of naming the defect is a guard that has to be
# read to be understood, which is the opposite of the point.
if "now_wire_pump()" in loop and "now_wire_get_active(" in loop:
    check(
        loop.index("now_wire_pump()") < loop.index("now_wire_get_active("),
        "stream_promise must pump BEFORE testing whether the transfer is "
        "still active, or the pass that ends the loop is a pass that "
        "serviced nothing.",
    )
check(
    "now_continuity_drag_should_abort(" in loop,
    "stream_promise's loop must honour the abort flag: setting it is the "
    "only way into a nested Toolbox loop from outside it, so a cancel that "
    "is not read there is a cancel that does nothing.",
)
check(
    "now_wire_get_cancel(" in loop,
    "an aborted promise must cancel the pull as well as refuse the flavor; "
    "local-only teardown leaves the host pushing into a lane nobody reads.",
)

# --- 2. the UPP is made, not cast --------------------------------------------
check(
    "NewDragSendDataUPP(drag_send_data)" in DRAGMGR,
    "the send-data proc must be built with NewDragSendDataUPP: this build is "
    "TARGET_RT_MAC_CFM, where a UPP is a routine descriptor and a cast "
    "function pointer is a Type 3 the first time the Toolbox calls back "
    "(finding carbon-upp-is-not-a-cast-on-cfm).",
)
check(
    not re.search(r"\(\s*DragSendDataUPP\s*\)\s*[A-Za-z_]", DRAGMGR),
    "a DragSendDataUPP must never be produced by a cast on this runtime.",
)
check(
    "DisposeDragSendDataUPP(" in DRAGMGR,
    "the send-data UPP must be disposed at quit, like every other UPP this "
    "application owns (pump.h's shutdown is the pattern).",
)
check(
    re.search(r"static\s+pascal\s+OSErr\s+drag_send_data\s*\(", DRAGMGR)
    is not None,
    "drag_send_data must be declared pascal: it is called by the Toolbox.",
)

# --- 3. no drag is ever left un-disposed -------------------------------------
start = body_of(DRAGMGR, "static void start_drag(")
# Anchored AFTER the NewDrag-failed branch, not at NewDrag itself: that
# branch returns because there is no drag, and demanding a DisposeDrag of
# it would be demanding a dispose of nothing. SetDragSendProc is the first
# statement on the path where `drag` is known good, which makes it the
# honest boundary -- and this distinction is why the check is anchored on a
# named call rather than on a line offset somebody will later move.
after_valid = start[start.index("if (SetDragSendProc(") :]
for match in re.finditer(r"\breturn\s*;", after_valid):
    window = after_valid[max(0, match.start() - 240) : match.start()]
    check(
        "DisposeDrag(drag)" in window,
        "every return from start_drag once NewDrag has SUCCEEDED must "
        "DisposeDrag first -- classic Finder is unforgiving of a drag that "
        "never ends, and a leaked DragRef is one. Offending return near: "
        + " ".join(after_valid[max(0, match.start() - 90) : match.start()].split()),
    )

check(
    "now_continuity_drag_ended(" in start,
    "start_drag must tell the state machine the drag ended, or the next "
    "request is refused `busy` forever.",
)

# --- 3b. the two buttons are sampled separately, at TrackDrag -----------------
# The first live run of this slice could not say WHY TrackDrag returned -128,
# because only one of the two buttons was ever asked about.  They are
# different questions: `now_continuity_button_is_down` is the resident's
# applied cell (what the arm ripens on) and `Button()` is this Macintosh's
# own (what TrackDrag actually tracks).  Neither substitutes for the other.
track_at = start.index("TrackDrag(")
before_track = start[:track_at]
check(
    "Button()" in before_track,
    "start_drag must sample Button() -- this Macintosh's OWN view -- before "
    "TrackDrag. Without it a drag that ended because there was never a real "
    "button is indistinguishable from a person letting go, which is exactly "
    "the ambiguity the first live run of this slice produced.",
)
check(
    "now_continuity_button_is_down()" in before_track,
    "start_drag must also sample the resident's applied button beside "
    "Button(). One artifact answering a two-artifact question is how the "
    "button hypothesis stayed a hypothesis.",
)
ended_call = start[start.index("now_continuity_drag_ended(") :]
ended_args = ended_call[: ended_call.index(")")]
check(
    "toolbox" in ended_args,
    "the toolbox button must be PASSED to now_continuity_drag_ended, not "
    "merely logged: the verdict is what a test and a person read, and a "
    "fact that only reaches the log cannot name a failure. Args were: "
    + " ".join(ended_args.split()),
)

# --- 3c. the drag image's pixels stay locked for the drag's whole life --------
# The Drag Manager holds the PixMap and reads it on every tracking pass.  An
# unlocked GWorld's baseAddr is the Memory Manager's to move or purge, so the
# lock has to outlive the drawing -- the span every other GWorld in this tree
# (screenshots/pixels.c, screenshots/capture.c) holds its own lock across.
image = body_of(DRAGMGR, "static GWorldPtr build_drag_image(")
check(
    "UnlockPixels" not in image,
    "build_drag_image must NOT unlock its pixels: it returns the PixMap to "
    "a caller that hands it to SetDragImage, and the Drag Manager reads it "
    "for the whole life of the drag. Unlocking here is a wild baseAddr the "
    "moment the Memory Manager compacts.",
)
check(
    "LockPixels" in image,
    "build_drag_image must lock the pixels it draws into and returns.",
)
unlock_at = start.find("UnlockPixels")
dispose_at = start.find("DisposeGWorld")
check(
    unlock_at != -1 and dispose_at != -1 and unlock_at < dispose_at,
    "start_drag must UnlockPixels before DisposeGWorld, and only after "
    "TrackDrag has returned -- the lock build_drag_image deliberately leaves "
    "held is this function's to release.",
)
check(
    dispose_at > track_at,
    "the drag image must outlive TrackDrag; disposing it earlier hands the "
    "Drag Manager a PixMap in freed memory.",
)

# --- 4. cross-artifact: three files, one set of acts -------------------------
# The contract's own words for this verb, from the x-commands entry.
offer_at = CONTRACT.index("\n    offer:\n")
next_verb = re.search(r"\n  [a-zA-Z#]", CONTRACT[offer_at + 1 :])
offer_block = CONTRACT[offer_at : offer_at + 1 + next_verb.start()]
contract_acts = set(re.findall(r'"(--[a-z]+)"', offer_block))

# What run_offer actually dispatches on.
run_offer = body_of(COMMANDS, "static void run_offer(")
code_acts = set(re.findall(r'strcmp\(action,\s*"(--[a-z]+)"\)', run_offer))

# What the console tells a person they may type.
help_block = HELP[HELP.index("static const char *const d_offer[]") :]
help_block = help_block[: help_block.index("NULL")]
help_acts = set(re.findall(r"(--[a-z]+)", help_block))

check(
    contract_acts == code_acts,
    "the acts the contract declares for `offer` and the acts run_offer "
    "handles must be the same set. contract={0} code={1}".format(
        sorted(contract_acts), sorted(code_acts)
    ),
)
check(
    help_acts == code_acts,
    "the acts the console help documents and the acts run_offer handles "
    "must be the same set -- a person cannot be told about an act that does "
    "nothing, or left to guess one that works. help={0} code={1}".format(
        sorted(help_acts), sorted(code_acts)
    ),
)
check(
    "--drag" in code_acts and "--stop" in code_acts,
    "this slice's whole point is that `offer --drag` exists and that "
    "`offer --stop` can end it; a cancel path is a deliverable here, not "
    "an afterthought.",
)

if failures:
    for line in failures:
        print("FAIL: " + line, file=sys.stderr)
    sys.exit(1)
print("ok")
