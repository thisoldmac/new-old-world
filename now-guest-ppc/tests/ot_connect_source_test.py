#!/usr/bin/env python3
"""Structural regression for the PB1400 Open Transport launch freeze.

The emulator accepts synchronous + nonblocking OTConnect; the physical
PowerBook can block forever inside the call, wedging the app before its
first update event. This pins the metal-required setup sequence and the
lifetime rules that make the asynchronous call safe. It exists because
the fix was lost once already (the codex branch carried it; the Workshop
rewrite did not).

Run with: python3 ot_connect_source_test.py
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(name):
    """Read a guest source by BARE NAME, wherever its domain directory is.

    src/ is split by domain (core/, commands/, files/, ...), and this test
    cares about what four files SAY, not where they are filed. Searching by
    name means a later re-filing does not break the test - but a missing
    file still raises, because a source check that quietly reads nothing is
    worse than one that fails.
    """
    hits = sorted((ROOT / "src").rglob(name))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one {name} under {ROOT}/src, "
                         f"found {[str(h) for h in hits]}")
    return hits[0].read_text()


WIRE = source("wire.c")
MAIN = source("main.c")
PREFS = source("prefs.c")
NOWLOG = source("nowlog.c")


def function_body(source: str, signature: str, next_signature: str) -> str:
    """The text between two signatures - which is NOT quite a function body.

    Both indexes are FIRST occurrences. wire.c carries forward declarations
    for several of its statics, and the day one is added for start_connect
    this window becomes the declaration plus everything up to the next
    mention of service_connecting - which may be its own forward
    declaration on the following line, leaving a two-line "body" that every
    positive assertion below fails on and every `not in` assertion passes
    on. Neither function is forward-declared today (checked 2026-07-31);
    this is a note about what would happen, not a defect.

    Nor are comments stripped, so an identifier named in the prose beside
    the code satisfies a check the code no longer supports. That has now
    happened three times in the host suite; the reason it is only a note
    here is that these assertions read as a SEQUENCE, and a comment would
    have to sit in exactly the deleted line's position to hide it.
    """
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def assert_in_order(source: str, *needles: str) -> None:
    positions = [source.index(needle) for needle in needles]
    assert positions == sorted(positions), (needles, positions)


connect = function_body(
    WIRE, "static void start_connect(void)", "static void service_connecting(void)"
)
state = WIRE[WIRE.index("typedef struct {") : WIRE.index("} ConnState;")]

assert_in_order(
    connect,
    "installNotifier",
    "bind",
    "setAsynchronous",
    "setNonBlocking",
    "Connecting to %s:%u",
    "gNowOT.connect",
)

# The async call's address and call structures must outlive start_connect:
# stack copies handed to an asynchronous OTConnect are a use-after-return.
assert "InetAddress connect_address;" in state
assert "TCall connect_call;" in state
assert "InetAddress inet;" not in connect
assert "TCall call;" not in connect

# The notifier publishes one flag; the main loop does everything else.
assert "static pascal void connect_notifier" in WIRE
assert "volatile OSStatus connect_result;" in state
assert "volatile Boolean connect_done;" in state

# Both completion paths reach the same synchronous handoff.
assert "if (err == noErr)" in connect
assert "finish_connect();" in connect
assert "else if (err == kOTNoDataErr)" in connect

# A blocked or failed dial must still leave a launch log, and the log must
# identify the endpoint rather than report only a generic failure. The eager
# now_log_open() became prefs-governed with the Logs page; the guarantee now
# rests on three links, each pinned: the disk switch is applied before
# conn_init, it defaults on (including for pre-v12 prefs files), and turning
# it on actually opens the file.
assert_in_order(
    MAIN,
    "now_prefs_load(&log_prefs);",
    "now_log_set_disk(log_prefs.log_to_disk);",
    "conn_init();",
)
assert "prefs->log_to_disk = true;" in PREFS
set_disk = function_body(
    NOWLOG, "void now_log_set_disk(Boolean on)", "Boolean now_log_disk_on(void)"
)
assert "now_log_open();" in set_disk
assert '"disconnected from %s:%u: %.60s"' in WIRE

print("ot_connect_source_test: all assertions passed")
