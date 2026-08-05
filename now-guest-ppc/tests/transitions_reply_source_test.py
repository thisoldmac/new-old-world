#!/usr/bin/env python3
"""No `transitions` reply may state the same JSON key twice.

A duplicate key is LEGAL JSON and silently lossy: every conforming parser
keeps one of the two and drops the other, with no error anywhere. That is
the worst pair of properties a wire field can have, and this verb shipped
it.

MEASURED, not imagined. On this plane's first ever drain from a live
Power Mac G4 (2026-08-05) the reply carried 22 real records - 2853 bytes,
`seq` 1..22, ticks exactly 60 apart - as `"records":[...]`, and then its
tail added `"records":22`. Python, and every other conforming parser,
kept the integer. The records were on the wire and unreachable to any
client, and `transitions drain` looked like it returned a count and no
data. `qdtrace` names its array `ops` and never met this; this verb named
the array and its own count the same word.

It is the arg-key rule in the reply direction - see
contract_arg_key_source_test.py for the request half. Both are the same
lesson: a key stated twice is a key lost.

WHY SOURCE TEXT. run_drain assembles its reply across two snprintf calls
with the record loop between them, and it lives in transitions_cmd.c
above `#include <Carbon.h>`, so no host compiler can execute it - the
same reason GuestWireConformanceTests asks for a fixture when a message
is built across several snprintfs. The keys are literal text in those
format strings, so they can be read even though they cannot be run.

WHAT IS NOT CLAIMED: that any of it runs. A source assertion says the
code still says what it was made to say.

Run with: python3 transitions_reply_source_test.py
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "peek" / "transitions_cmd.c"

# Every reply this file emits, by the function that builds it. A reply
# assembled across several snprintf calls is ONE object, which is exactly
# how the duplicate got in: the two halves were written months apart and
# each was correct alone.
REPLY_FUNCS = ("run_status", "run_start", "run_stop", "run_drain",
               "error_json")


def strip_comments(text: str) -> str:
    """Code only.

    The prose beside the fix names `"records"` and `"count"` explicitly to
    explain the collision, so reading comments would make this test pass
    over the very code it guards - the failure mode get_cancel_source_test
    carries as a standing note.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def function_bodies(text: str):
    """{name: body} by brace matching from each definition."""
    out = {}
    for m in re.finditer(r"\b(\w+)\s*\([^;{]*\)\s*\{", text):
        name = m.group(1)
        if name not in REPLY_FUNCS:
            continue
        depth = 0
        start = m.end() - 1
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    out[name] = text[start:i + 1]
                    break
    return out


def keys_in(body: str):
    """Every JSON key literal the body emits, in order.

    A key is `\"word\":` inside a C string literal. Record-level keys
    (inside the drain's per-record snprintf) are a DIFFERENT object and
    are excluded by taking only the format strings that build the outer
    reply - identified as those containing `command.result` or beginning
    the tail with `],`.
    """
    return re.findall(r'\\"([A-Za-z][A-Za-z0-9_]*)\\"\s*:', body)


def main() -> int:
    if not SRC.exists():
        raise SystemExit(f"{SRC} is missing; this test has lost its subject")
    text = strip_comments(SRC.read_text())
    bodies = function_bodies(text)

    missing = [f for f in REPLY_FUNCS if f not in bodies]
    if missing:
        raise SystemExit(f"could not find {missing} in {SRC.name}; the "
                         f"walker is broken, not the source")

    failures = 0

    # ---- the defect itself: run_drain states one key twice -------------
    #
    # run_drain's outer object is built by two snprintfs (head and tail)
    # with a per-record loop between them. The record keys belong to the
    # inner objects; the outer ones are everything in the head and tail.
    drain = bodies["run_drain"]
    # The per-record format string, excluded: it is the one carrying
    # `kindName`, which no outer reply has.
    record_fmt = [s for s in re.findall(r'"((?:[^"\\]|\\.)*)"', drain)
                  if "kindName" in s]
    outer = drain
    for s in record_fmt:
        outer = outer.replace(s, "")
    outer_keys = keys_in(outer)

    seen = {}
    for k in outer_keys:
        seen[k] = seen.get(k, 0) + 1
    dupes = sorted(k for k, n in seen.items() if n > 1)
    if dupes:
        for k in dupes:
            print(f"FAIL: run_drain's reply states the key `{k}` "
                  f"{seen[k]} times in one object. A duplicate key is "
                  f"legal JSON and silently lossy - a conforming parser "
                  f"keeps one and drops the other, with no error. This is "
                  f"how 22 real records went out on the wire unreadable.",
                  file=sys.stderr)
            failures += 1

    # The specific pair, named, so the fix cannot be undone by renaming
    # the count back.
    if "records" in outer_keys and "count" not in outer_keys:
        print("FAIL: run_drain's tail no longer emits `count`. The array "
              "is `records`; the count must NOT also be `records`.",
              file=sys.stderr)
        failures += 1

    # ---- and no other reply in the file repeats a key ------------------
    for name in REPLY_FUNCS:
        if name == "run_drain":
            continue
        ks = keys_in(bodies[name])
        seen = {}
        for k in ks:
            seen[k] = seen.get(k, 0) + 1
        for k in sorted(k for k, n in seen.items() if n > 1):
            print(f"FAIL: {name} states the key `{k}` {seen[k]} times in "
                  f"one reply object.", file=sys.stderr)
            failures += 1

    if failures:
        return 1

    print(f"transitions_reply_source_test: ok "
          f"({len(REPLY_FUNCS)} replies, no key stated twice; "
          f"drain's array is `records` and its count is `count`)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
