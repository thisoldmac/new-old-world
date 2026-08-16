#!/usr/bin/env python3
"""Structural regression for stopping a RECEIVE, and for its two faces.

The sibling of get_cancel_source_test.py, one lane over: that one covers
the pull this Mac asked for, this one the push the host offered. Same
reason for being a source test - wire.c is Toolbox-bound, `g_put` is
private to it and `send_control` needs an endpoint, so nothing here
compiles on a host cc.

The three facts worth losing sleep over, and therefore worth pinning:

  * the frame says `transfer`, not `id` (FileCancel is {type, transfer}
    with additionalProperties false, so an `id` field is a frame the host
    must reject);
  * both halves happen and in this order - tell the other Mac, then end
    it here - because wire-only leaves this side writing a temp nobody
    finishes and local-only leaves the host pushing into a lane that is
    one transfer wide;
  * the teardown is put_abort, the SAME one an inbound file.cancel runs,
    so the host hears file.done ok:false rather than inferring the end
    from the bytes stopping.

What is NOT claimed: that any of it runs. A source assertion says the
code still says what it was made to say. Behaviour needs a machine.

Run with: python3 put_cancel_source_test.py
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def strip_comments(text: str) -> str:
    """Code only - get_cancel_source_test.py's reason, unchanged: every
    literal asserted below also appears in the prose next to it."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def source(name: str) -> str:
    hits = sorted((ROOT / "src").rglob(name))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one {name} under {ROOT}/src, "
                         f"found {[str(h) for h in hits]}")
    return strip_comments(hits[0].read_text())


def body(text: str, signature: str, next_signature: str) -> str:
    start = text.index(signature)
    end = text.index(next_signature, start)
    return text[start:end]


def assert_in_order(text: str, *needles: str) -> None:
    positions = [text.index(needle) for needle in needles]
    assert positions == sorted(positions), (needles, positions)


WIRE = source("wire.c")
WIRE_H = source("wire.h")
CONSOLE = source("console_model.c")


# --- the primitive --------------------------------------------------------
cancel = body(WIRE, "int now_wire_put_cancel(char *err, long cap)\n{",
              "static void take_bulk_in(")

# Nothing landing is a refusal with a reason, not a silent success.
assert "if (!g_put.active) {" in cancel
assert "return -1;" in cancel

# Both halves, in this order.
assert_in_order(
    cancel,
    '\\"type\\":\\"file.cancel\\"',
    "send_control(json)",
    'put_abort("cancelled"',
)

assert '\\"transfer\\":%ld' in cancel
assert '\\"id\\"' not in cancel

# Best effort on the wire: a stop pressed on a dead wire still has to end
# the receive here, so the send's result must not gate the teardown.
assert "(void)send_control(json);" in cancel
assert "if (!send_control" not in cancel

# The id is the receive's own, not the pull's - the two lanes have
# separate ids and cancelling the wrong one stops nothing.
assert "g_put.id" in cancel
assert "g_get.id" not in cancel

assert "int now_wire_put_cancel(char *err, long cap);" in WIRE_H


# --- the console face -----------------------------------------------------
# docs/command-parity.md: a capability reachable from one face only is
# unavailable in whichever half of the pair you are living in. The console
# verb calls the SAME two functions the Workshop's buttons do - a second
# implementation is how two faces learn to disagree.
verb = body(CONSOLE, 'if (strcmp(name, "cancel") == 0) {',
            "run_shared_verb(name, raw_args);")
assert_in_order(
    verb,
    "now_wire_put_cancel(why, sizeof why)",
    "now_wire_get_cancel(why, sizeof why)",
)
# An outbound send has no guest-originated stop yet, and reporting a
# machine as quiet while a file is leaving it is the one answer here
# worse than a refusal.
assert "now_wire_send_state(NULL, NULL, NULL, 0) != kSendNothing" in verb

print("put_cancel_source_test: all assertions passed")
