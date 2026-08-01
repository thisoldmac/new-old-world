#!/usr/bin/env python3
"""Structural regression for capture.region's wiring and refusal order.

wire.c is Toolbox-bound (GetMainDevice, CopyBits, the static transfer
globals) and does not compile on the host — see capture_region_args_test.c
for the one part of this verb that does. What is checked here is the same
shape get_cancel_source_test.py and key_refusal_source_test.py already
check for their own verbs: that the refusal comes BEFORE any Toolbox call
runs, in the right order, and that the dispatch table actually reaches the
function whose body this reads.

What is NOT claimed: that any of this runs. A source assertion says the
code still says what it was made to say. Behaviour needs a machine.

Run with: python3 capture_region_source_test.py
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def source(name: str) -> str:
    hits = sorted((ROOT / "src").rglob(name))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one {name} under {ROOT}/src, "
                         f"found {[str(h) for h in hits]}")
    return strip_comments(hits[0].read_text())


WIRE = source("wire.c")


def body(text: str, signature: str, next_signature: str) -> str:
    start = text.index(signature)
    end = text.index(next_signature, start)
    return text[start:end]


def assert_in_order(text: str, *needles: str) -> None:
    positions = [text.index(needle) for needle in needles]
    assert positions == sorted(positions), (needles, positions)


# --- the dispatch reaches it -----------------------------------------------
# Without this the message decodes and nothing happens — the exact bug
# shape testMessagesThisCannotCheckAreKnown's sibling suite exists to
# catch on the host side, from the guest side this is the whole check.
assert (
    'now_json_type_is(reply, "capture.region")' in WIRE
), "capture.region is not in wire.c's dispatch — the message decodes and nothing serves it"
dispatch = body(WIRE, 'now_json_type_is(reply, "capture.region")', "}")
assert "serve_capture_region(reply);" in dispatch


# --- the refusal order -----------------------------------------------------
serve = body(WIRE, "static void serve_capture_region(const char *request)\n{",
            "\nstatic void shot_drop(void)")

# ONE transfer at a time, checked BEFORE the (Toolbox-free) argument parse
# — a busy guest must refuse fast, not spend a parse on a request it was
# always going to reject. Named explicitly rather than "any refusal" so a
# fourth lane (a scene transfer, say) sharing g_xfer is not silently
# missed the way a partial busy-check would be.
assert "g_stream.active || g_xfer.active || g_shot.active" in serve

# No SetFrontProcess, no deferred g_shot arm, and no repaint wait —
# the entire reason this verb exists over process.shot. A capture that
# fronted anything here would be indistinguishable, from the machine's
# point of view, from what process.shot already does.
assert "SetFrontProcess" not in serve
assert "g_shot.active = true" not in serve
assert "TickCount() + 45" not in serve

# The parse happens before any capture is attempted, and BOTH refusal
# paths answer capture.end ok:false rather than leaving the host to time
# out — the same contract process.shot's own refusals keep.
assert_in_order(
    serve,
    "g_stream.active || g_xfer.active || g_shot.active",
    "now_capture_region_parse(",
    "gather_shot_rect(",
)
assert serve.count('\\"type\\":\\"capture.end\\"') >= 1
assert '\\"ok\\":false' in serve

# depth 0 means "no preference" (capture.request and process.shot's own
# convention) — the caller's own default fills it, never a literal.
assert "args.depth ? args.depth : prefs.shot_depth" in serve


# --- the reply carries where it was captured from --------------------------
# Without this the pixel-island producer has pixels with no way to place
# them back onto guest coordinates — the whole reason this field exists.
arm = body(WIRE, "static int arm_transfer(long id, unsigned short xfer,",
          "\nstatic void serve_capture(const char *request)")
assert '\\"originX\\":%d,\\"originY\\":%d' in arm
assert "(int)meta->origin_x, (int)meta->origin_y" in arm

print("capture_region_source_test: all assertions passed")
