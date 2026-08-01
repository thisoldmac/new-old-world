#!/usr/bin/env python3
"""The arm commit ORDER, which no end-state test can see.

contract/content_table.h states the arm protocol as an ordering and not as
a set of values:

    arm_a5, arm_expiry and mode FIRST, arm_commit LAST; to disarm, clear
    arm_commit FIRST. A jGNE pass can land between any two stores, and
    that order is what stops a live commit word from ever pairing with the
    previous request's target.

A test that inspects the block afterwards sees the same four words no
matter which order they were written in, so the property is invisible to
one. The interleaving that would expose it needs a second thread of
control - resident code running inside another process at event-loop time
- which is exactly what a host cc does not have.

So it is gated where it IS legible: as text. This reads the two functions
that write the block and fails if the commit word moves. Crude, and
deliberately so - the alternative was no gate at all on the plane's own
stated safety ordering.

Run with: python3 qdtrace_arm_order_source_test.py
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(name: str) -> str:
    hits = sorted((ROOT / "src").rglob(name))
    if len(hits) != 1:
        raise SystemExit(f"expected exactly one {name} under {ROOT}/src, "
                         f"found {[str(h) for h in hits]}")
    return hits[0].read_text()


READ = source("qdtrace_read.c")


def body(text: str, signature: str) -> str:
    """The text from a signature to the closing brace at column zero.

    Comments are NOT stripped, which is the known weakness of every source
    gate in this tree: an assignment named in the prose beside the code
    satisfies a check the code no longer performs. It bites less here than
    usual because these assertions read as an ORDER - a comment would have
    to sit in exactly the deleted store's position, in the right sequence
    relative to three others, to hide the change.
    """
    start = text.index(signature)
    end = text.index("\n}\n", start)
    return text[start:end]


def store_index(fn: str, field: str) -> int:
    needle = f"b->{field} ="
    if needle not in fn:
        raise SystemExit(f"no store to {field}; the arm protocol's fields "
                         f"are named in contract/content_table.h and all "
                         f"four are required")
    return fn.index(needle)


def main() -> None:
    arm = body(READ, "void now_qdtrace_arm_commit(")
    disarm = body(READ, "void now_qdtrace_disarm(")

    a5 = store_index(arm, "arm_a5")
    expiry = store_index(arm, "arm_expiry")
    mode = store_index(arm, "mode")
    commit = store_index(arm, "arm_commit")

    if not (a5 < commit and expiry < commit and mode < commit):
        raise SystemExit(
            "arm_commit is not written LAST. A jGNE pass landing between "
            "the stores would see permission attached to the PREVIOUS "
            "request's target (contract/content_table.h, the arm protocol).")

    d_commit = store_index(disarm, "arm_commit")
    d_a5 = store_index(disarm, "arm_a5")
    d_mode = store_index(disarm, "mode")
    d_expiry = store_index(disarm, "arm_expiry")

    if not (d_commit < d_a5 and d_commit < d_mode and d_commit < d_expiry):
        raise SystemExit(
            "arm_commit is not CLEARED FIRST on disarm. Clearing the target "
            "before the permission leaves a window in which a live commit "
            "word names a cleared A5 (contract/content_table.h).")

    # The commit word is deliberately not 1, so that a zeroed block, a
    # stale build and scribbled memory all read as "not armed".
    if "kNowContentArmCommit" not in arm:
        raise SystemExit("the arm commit word must be kNowContentArmCommit, "
                         "not a literal; a bare 1 is what uninitialised "
                         "memory looks like")

    # Both functions go through a volatile view. Without it a compiler is
    # free to sink or reorder the four stores, and the ordering above
    # becomes a comment about source text rather than about machine code.
    for name, fn in (("arm_commit", arm), ("disarm", disarm)):
        if "volatile" not in fn:
            raise SystemExit(f"now_qdtrace_{name} writes the block without a "
                             f"volatile view; the store ORDER is only real "
                             f"if the compiler is told not to move it")

    print("ok")


if __name__ == "__main__":
    main()
