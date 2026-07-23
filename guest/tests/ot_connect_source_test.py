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
WIRE = (ROOT / "src" / "wire.c").read_text()
MAIN = (ROOT / "src" / "main.c").read_text()
PREFS = (ROOT / "src" / "prefs.c").read_text()
NOWLOG = (ROOT / "src" / "nowlog.c").read_text()


def function_body(source: str, signature: str, next_signature: str) -> str:
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
