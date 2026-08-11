#!/usr/bin/env python3
"""Structural regression for stopping a pull, and for the link teardown.

wire.c is Toolbox-bound: `g_get` is private to it, `send_control` needs an
endpoint, and none of it compiles on the host. So the parts of the fix that
a host test can reach are the ones written down here - the same shape
ot_connect_source_test.py uses for the OT launch sequence, and for the same
reason: these facts were established once and are cheap to lose.

What is NOT claimed: that any of this runs. A source assertion says the
code still says what it was made to say. Behaviour needs a machine.

Run with: python3 get_cancel_source_test.py
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def strip_comments(text: str) -> str:
    """Code only.

    Every assertion below is an identifier or a literal that also appears
    in the prose beside it - the comments explain the cancel frame by
    naming `file.cancel`, `get_cleanup(false)` and `send_control`. Reading
    the comments would make this test pass over deleted code, which is the
    failure mode the OT source test carries as a known note and which has
    already bitten the host suite three times. Cheaper to remove the prose
    than to write assertions that avoid it.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def source(name: str) -> str:
    hits = sorted((ROOT / "src").rglob(name))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one {name} under {ROOT}/src, "
                         f"found {[str(h) for h in hits]}")
    return strip_comments(hits[0].read_text())


WIRE = source("wire.c")
WIRE_H = source("wire.h")
FILES_MODULE = source("files_module.c")


def body(text: str, signature: str, next_signature: str) -> str:
    start = text.index(signature)
    end = text.index(next_signature, start)
    return text[start:end]


def assert_in_order(text: str, *needles: str) -> None:
    positions = [text.index(needle) for needle in needles]
    assert positions == sorted(positions), (needles, positions)


# --- the primitive --------------------------------------------------------
cancel = body(WIRE, "int now_wire_get_cancel(char *err, long cap)\n{",
              "Boolean now_wire_get_active(")

# Nothing in flight is a refusal with a reason, not a silent success.
assert "if (!g_get.pending && !g_get.receiving) {" in cancel
assert "return -1;" in cancel

# Both halves, in this order: tell the other Mac, then free this side.
assert_in_order(
    cancel,
    '\\"type\\":\\"file.cancel\\"',
    "send_control(json)",
    "get_cleanup(false);",
)

# The frame carries `transfer`, not `id`: contract/asyncapi.yaml FileCancel
# is {type, transfer} with additionalProperties false, so an `id` field is
# a frame the host must reject.
assert '\\"transfer\\":%ld' in cancel
assert '\\"id\\"' not in cancel

# Best effort on the wire. A stop pressed on a dead wire still has to free
# this side, so the send's result must not gate the teardown.
assert "(void)send_control(json);" in cancel
assert "if (!send_control" not in cancel

# And it is declared, or the Files pane cannot reach it.
assert "int now_wire_get_cancel(char *err, long cap);" in WIRE_H

# The registration is the whole difference between a Stop button that
# appears and one that does not: now_pull_can_stop() is false without it.
assert "now_pull_set_canceller(now_wire_get_cancel);" in FILES_MODULE


# --- one teardown for a leaving link --------------------------------------
# There were two lists and they drifted: enter_backoff() dropped five things
# and conn_disconnect() dropped none, so disconnecting mid-pull left an open
# temp fork. The list lives in one place now, and the pull is in it.
drop = body(WIRE, "static void link_drop_transfers(void)\n{",
            "static void enter_backoff(void)")
for call in ("xfer_cleanup();", "offer_cleanup();", "stream_drop();",
             "shot_drop();", "put_drop();", "get_cleanup(false);",
             "ctlq_clear();"):
    assert call in drop, call

backoff = body(WIRE, "static void enter_backoff(void)\n{",
               "static void fail(const char *reason)")
assert "link_drop_transfers();" in backoff
assert "put_drop();" not in backoff          # not a second copy of the list

disconnect = body(WIRE, "void conn_disconnect(void)\n{",
                  "void conn_connect_now(void)")
# After the bye is flushed, not before: the queue drain is the last thing
# this link is asked to carry.
assert_in_order(disconnect, "sndOrderlyDisconnect", "link_drop_transfers();",
                "close_endpoint();")


# --- asked is not receiving -----------------------------------------------
# One boolean could not tell a question nobody answered from an open file
# with no bytes in it yet, so the pane inferred from the counts. The wire
# knows which it is.
active = body(WIRE, "Boolean now_wire_get_active(long *received, long *expected,",
              "int now_wire_get_host(")
assert "*phase = g_get.receiving ? kWireGetReceiving : kWireGetAsked;" in active
assert "*phase = kWireGetNone;" in active
for name in ("kWireGetNone", "kWireGetAsked", "kWireGetReceiving"):
    assert name in WIRE_H, name

print("get_cancel_source_test: all assertions passed")
