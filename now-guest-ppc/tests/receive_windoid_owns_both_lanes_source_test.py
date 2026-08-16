#!/usr/bin/env python3
"""The receive windoid is owned by the RX PROTOCOL, not by a page — and
that means BOTH inbound lanes.

WHY THIS EXISTS. `receive_progress.c` shipped reading one lane:
`now_wire_receive_active`, which answered only for `g_put` — the
file.offer push. The other inbound lane is `g_get`, the file.get pull,
and a **continuity grab** rides it: the person drags a file from the Mac
to the Macintosh, the guest sends continuity.grab, and the bytes come
back down the file lane. No page asked for that transfer, so no page
drew it. Measured on the emulator 2026-08-16 with `offer --take`
serving 600 KB: the framebuffer did not change by one pixel for the
whole transfer, while an identical-size push raised the windoid.

The rule this pins is the one that makes the design worth having:
ONE OWNER READS THE WIRE, and a new receive path shows up because the
lane says so, not because somebody remembered to wire a page.

Four facts, each of which was wrong at some point today:

  * `now_wire_receive_active` answers for the get lane too, gated on
    `g_get.unattended` — an ATTENDED pull is the Files/Cloud page's to
    draw and two windows over one transfer is worse than one;
  * `unattended` is set at the two ENTRY points, true for
    `now_wire_get_offer` (the grab) and false for `now_wire_get_host`
    (a page's pull), because which caller asked is the fact and the
    lane's state cannot recover it;
  * `get_note` feeds `rx_outcome` for an unattended pull, so the ending
    — especially a failure — reaches the windoid instead of a hook
    nobody installed;
  * the windoid's Stop sends the cancel for the lane it is showing.
    `now_wire_put_cancel` on a pull refuses, and a person would be told
    "nothing is being transferred" about the transfer in front of them.

What is NOT claimed: that any of it runs. wire.c is Toolbox-bound and
`g_get` is private to it, so this is a source assertion in the shape
put_cancel_source_test.py already uses. Behaviour needs a machine, and
the machine agreed on 2026-08-16.

Run with: python3 receive_windoid_owns_both_lanes_source_test.py
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def strip_comments(text: str) -> str:
    """Code only: every literal asserted below also appears in the prose
    beside it, and a test that reads its own documentation passes on a
    comment somebody forgot to delete."""
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


WIRE = source("wire.c")
WIRE_H = strip_comments((ROOT / "src" / "core" / "wire.h").read_text())
WINDOID = source("receive_progress.c")

# --- 1. the reader answers for both lanes ---------------------------------

active = body(
    WIRE,
    "Boolean now_wire_receive_active(long *received, long *expected,",
    "static unsigned long json_find_u32(const char *json, const char *key,")

assert "g_get.receiving" in active, (
    "now_wire_receive_active reads only the push lane. A continuity grab "
    "rides g_get and would land in silence — which is exactly how it "
    "shipped, and exactly what the emulator measured on 2026-08-16.")
assert "g_get.unattended" in active, (
    "the get lane is reported without asking whether a page is already "
    "drawing it. An attended pull would get a second window over one "
    "transfer, which receive_progress.h argues against for the Cloud page.")
assert "*is_pull = true;" in active and "*is_pull = false;" in active, (
    "the caller cannot tell which lane it is showing, so its Stop button "
    "cannot send the right cancel.")

# The signature is part of the contract between the two files.
assert ("Boolean now_wire_receive_active(long *received, long *expected,\n"
        "                                Boolean *cloud_get,\n"
        "                                char *name, long name_cap,\n"
        "                                Boolean *is_pull);") in WIRE_H, (
    "wire.h no longer declares the is_pull out-parameter.")

# --- 2. unattended is set at the entry points, not inferred ---------------

grab = body(WIRE,
            "int now_wire_get_offer(long *id_out, char *err, long cap)",
            "static void get_begin(")
assert "g_get.unattended = true;" in grab, (
    "the continuity grab does not mark its pull unattended, so the "
    "windoid will not show it. This is the whole defect.")

page_pull = body(WIRE,
                 "int now_wire_get_host(const char *path, const char *name, "
                 "char *err, long cap)",
                 "int now_wire_get_offer(")
assert "g_get.unattended = false;" in page_pull, (
    "a page's own pull does not clear the flag, so a grab followed by a "
    "Files pull would raise a second window over a transfer the page is "
    "already drawing.")

# --- 3. an unattended ending reaches the windoid --------------------------

note = body(WIRE, "static void get_note(const char *line)",
            "Boolean now_wire_get_landed(long id, FSSpec *spec_out)")
assert "g_get.unattended" in note and "rx_outcome(line)" in note, (
    "get_note does not feed the receive outcome for an unattended pull. "
    "The bar would simply vanish on the last byte, and a FAILED grab "
    "would be reported to nobody at all.")

# --- 4. Stop sends the cancel for the lane on screen ----------------------

assert "now_wire_get_cancel(why, sizeof why)" in WINDOID, (
    "the windoid's Stop only knows how to cancel a push. Pressed during "
    "a grab it refuses, and tells a person nothing is being transferred "
    "while a progress bar in the same window moves.")
assert "now_wire_put_cancel(why, sizeof why)" in WINDOID, (
    "the push lane's cancel was lost.")
assert "g_is_pull" in WINDOID, (
    "the windoid does not remember which lane it opened for; re-reading "
    "at Stop time can answer about a different transfer.")

print("receive_windoid_owns_both_lanes_source_test: ok")
