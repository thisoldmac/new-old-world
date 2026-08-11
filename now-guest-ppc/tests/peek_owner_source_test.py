#!/usr/bin/env python3
"""Keep plane ownership in cooperative lifecycle paths, never repaint paths.

The Processes page once renewed its resident-plane lease from ``draw()``.
That looks live while the window is changing, but a quiet valid window may not
draw again before the lease expires.  The Workshop's ``idle()`` callback is the
guaranteed cooperative pump and therefore owns renewal.

This source guard also prevents the removed direct arm/disarm API from growing
back beside the named-owner aggregator.  End-state unit tests cannot expose
either defect: both implementations can produce the same ``arm_request`` word
on the pass in which the test observes them.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
PROCESSES = (SRC / "processes" / "processes_module.c").read_text()


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
                return text[brace + 1:index]
    raise SystemExit(f"unterminated function: {signature}")


def main() -> None:
    idle = function_body(PROCESSES, "static void procs_idle(void)")
    draw = function_body(PROCESSES, "static void procs_draw(void)")
    claim = "now_peek_claim(kNowPeekOwnerProcesses, kNowPeekCapAnchors)"

    if claim not in idle:
        raise SystemExit(
            "Processes does not renew its P1 owner lease from procs_idle; "
            "a quiet visible page will expire even though its consumer is live")
    if claim in draw:
        raise SystemExit(
            "Processes renews its P1 owner lease from procs_draw; repaint is "
            "not a lifecycle pump and cannot keep a quiet consumer alive")

    legacy = []
    for path in sorted(SRC.rglob("*.c")):
        text = path.read_text()
        for symbol in ("now_peek_arm(", "now_peek_disarm("):
            if symbol in text:
                legacy.append(f"{path.relative_to(ROOT)}: {symbol[:-1]}")
    if legacy:
        raise SystemExit(
            "direct plane mutation bypasses the named-owner aggregator:\n  "
            + "\n  ".join(legacy))

    print("ok")


if __name__ == "__main__":
    main()
