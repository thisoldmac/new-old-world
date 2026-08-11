#!/usr/bin/env python3
"""`handle` states its verdict and its reason from ONE value.

THE SHAPE THIS EXISTS TO PREVENT. `handle` is the only reply either guest
emits that puts a reason-shaped field inside an `ok:true` frame - the
contract makes `ok` true for all five verdicts on purpose, because "your
reference is stale" is an answer rather than a failed call. That design is
right, and it is also the one place in the tree where a verdict and an
explanation sit side by side in a success-shaped reply. If those two are
ever read off separate expressions, nothing stops an `ok` verdict appearing
beside a sentence explaining a refusal, and a reply of that shape reads as a
failure to everyone quoting it - in a report, or in a test assertion, which
is how a lie of this shape gets propagated rather than noticed.

It was three expressions before 2026-08-07: `handle.verdict` for the word,
`handle.why` for the sentence, and `handle.verdict` again for `resolved`.
Nothing was wrong - resolve_kind assigns the pair together and
obsresolve.c's resolver never returns Ok with a reason. But the invariant
was upheld by convention in a file with NO host test, which is the same
standing gap one_minter_source_test.py was written for: observe.c touches
Carbon on every line, so pointing its emitter at a stale field compiles
clean and leaves every native test green.

So the property is asserted where a text scan genuinely can see it: the
handle emitter reads `why`, and does not read `verdict` at all.

WHAT IS NOT CLAIMED, in the same spirit as one_minter_source_test.py: that
any of it runs. A source assertion says the code still says what it was
made to say. Behaviour needs a Macintosh.

Run with: python3 handle_reason_source_test.py
"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
OBSERVE_C = ROOT / "src" / "observe" / "observe.c"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


def strip_comments(text: str) -> str:
    """Code only.

    The comment beside this very emitter explains the defect by naming
    `handle.verdict` as the thing it deliberately does not consult. Reading
    the comments would make this test fail on the explanation of why it
    passes.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def handle_command_body(source: str) -> str:
    """The body of now_observe_handle_command, brace-matched.

    Brace-matched rather than "to the next blank line" because the emitter
    is a chain of appends with nested blocks, and a scan that stopped early
    would pass over exactly the tail where the element object is written.
    """
    start = source.index("void now_observe_handle_command")
    open_brace = source.index("{", start)
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace:i + 1]
    raise AssertionError("now_observe_handle_command has unbalanced braces")


def main() -> int:
    source = strip_comments(OBSERVE_C.read_text())
    body = handle_command_body(source)

    # The reply's three statements about the outcome all come from `why`.
    check("now_obs_verdict_for_why(handle.why)" in body,
          "the verdict word is derived from the reason, not carried beside it")
    check("handle.why == kNowObsWhyNone" in body,
          "`resolved` is derived from the reason too")
    check("now_obs_why_text(handle.why)" in body,
          "the reason itself is the same value")

    # And the second copy is not consulted. This is the assertion with
    # teeth: everything above can be true while a stale `verdict` field is
    # still read somewhere in the same reply.
    check("handle.verdict" not in body,
          "the emitter does not read handle.verdict - one value, "
          "seen three ways, cannot disagree with itself")

    # The mapping it derives through is the resolver's own, not a copy.
    resolve_c = strip_comments(
        (ROOT / "src" / "observe" / "obsresolve.c").read_text())
    check(resolve_c.count("static NowObsVerdict verdict_for") == 1,
          "there is exactly one why-to-verdict table")
    check("return verdict_for(why);" in resolve_c,
          "and the public entry point is that table rather than a second one")

    for what in failures:
        print(f"FAIL: {what}", file=sys.stderr)
    if failures:
        print(f"{len(failures)} failure(s)", file=sys.stderr)
        return 1
    print("handle states one value three ways")
    return 0


if __name__ == "__main__":
    sys.exit(main())
