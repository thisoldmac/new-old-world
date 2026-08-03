#!/usr/bin/env python3
"""No verb may read an argument whose name shadows an envelope key.

## The rule, and why it is worth a gate

The contract preamble states it: the classic guest scans a request FLAT
and the first occurrence wins. So a verb that reads an argument called
`name` does not get its caller's argument — it gets the envelope's own
`"name": "<the command>"`, every time, on every call.

`launch` shipped that defect to metal. `key` shipped it too and it went
unnoticed for longer, because the CONSOLE face parses a typed line and
calls the checker directly: typing `key space` at the machine worked
perfectly while every request over the wire was refused with "that is not
a key this verb names" — the guest reading its own command name and
correctly reporting that `key` is not a key. Measured 2026-08-02.

Both faces working differently is exactly the shape `command-parity.md`
exists for, and parity tests compare which VERBS exist, not which
arguments reach them. So this reads the source instead.

## What it checks

Every read of an argument out of a request, against the five names the
envelope itself uses. It is deliberately a source scan: the defect is
invisible at runtime unless a caller happens to send the argument, and
invisible in review unless the reader remembers this rule.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# The envelope's own keys — contract/asyncapi.yaml, `command.request`.
#
# `line` is deliberately NOT here. It is an envelope field a verb is
# MEANT to read: the console face sends its typed remainder there, and
# `cmd_line.c` reading it is the feature rather than the collision. The
# other four have no such reading, so any use of them is the flat scan
# biting.
FORBIDDEN = {"type", "id", "name", "args"}

# Every way a verb reads one argument out of the request JSON.
READERS = (
    "now_json_find_string",
    "now_json_find_text",
    "arg_str",
    "arg_int",
    "arg_bool",
    "arg_number",
)

# `request_json` is the whole frame; a reader pointed at a sub-object has
# already narrowed the scan and cannot collide with the envelope.
CALL = re.compile(
    r"\b(" + "|".join(READERS) + r")\s*\(\s*request_json\s*,\s*\"([^\"]+)\"")


def guest_sources():
    for tree in ("now-guest-ppc/src", "now-guest-68k/src",
                 "now-guest-shared/src"):
        base = ROOT / tree
        if base.is_dir():
            yield from sorted(base.rglob("*.c"))


def main():
    problems = []
    scanned = 0
    for path in guest_sources():
        scanned += 1
        text = path.read_text(errors="replace")
        for match in CALL.finditer(text):
            arg = match.group(2)
            if arg in FORBIDDEN:
                line = text[:match.start()].count("\n") + 1
                problems.append(
                    f"{path.relative_to(ROOT)}:{line}: {match.group(1)}"
                    f"(request_json, \"{arg}\") — the scan is FLAT, so this "
                    f"reads the envelope's own \"{arg}\" and never the "
                    f"caller's argument")

    if problems:
        print("argument names that shadow an envelope key:\n", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        print("\nRename the argument in contract/asyncapi.yaml first, then "
              "here. `key` used `name` and was refused on every wire call "
              "while the console face worked; it is now `named`.",
              file=sys.stderr)
        return 1

    if scanned == 0:
        print("no guest sources found — this asserted nothing", file=sys.stderr)
        return 1
    print(f"ok: {scanned} guest sources, no argument shadows an envelope key")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
