#!/usr/bin/env python3
"""Pin initialization of the self-window reader's output structure.

The foreign-window entrypoint clears its result before dispatching, but the
window-count entrypoint calls ``read_own_windows`` with a fresh stack object.
The helper must therefore establish its own output state before reading the
count or indexing the window array.  This source-order guard covers the Carbon
path that cannot be linked into a host-native test.
"""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1] / "src" / "peek" / "peek_read.c"
).read_text()


def function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise SystemExit(f"unterminated function: {signature}")


body = function_body(
    SOURCE, "static NowPeekReadStatus read_own_windows(NowPeekWindowList *out)"
)
initialization = "memset(out, 0, sizeof *out);"
first_count_read = body.index("out->count")

if initialization not in body or body.index(initialization) > first_count_read:
    raise SystemExit(
        "read_own_windows reads an uninitialized count when called by "
        "now_peek_window_count; clear the result before the first count read"
    )

print("ok")
