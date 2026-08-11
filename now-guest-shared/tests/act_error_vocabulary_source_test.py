#!/usr/bin/env python3
"""Every act-plane error the contract declares has a name and a sentence.

WHY A SOURCE TEST. `act_client.c` includes Carbon, so the two mapping
functions cannot be linked by a host cc, and the thing they get wrong is
invisible at runtime: a missing `case` does not fail, it falls through to
`default` and answers "act-refused - the target refused the request".
That string is indistinguishable from a real refusal, so the plane's own
account of what went wrong is replaced by a shrug, and the instrument
reports a mystery instead of an answer.

MEASURED, 2026-08-02. `kNowPeekActErrPostFailed` had no case in either
switch. It means "the Event Manager refused to queue the press, so
nothing was asked of the application at all" - a completely different
repair from a refusal - and it read as a generic refusal. In the same
pass, `actselftest` refused against SimpleText and against the Finder
while abi-agreeing against NOW's own application, and the reason was
sitting in the cell's `error` field being discarded. A vocabulary with a
hole in it is worse than no vocabulary, because it looks complete.

So: every `kNowPeekActErr*` declared in contract/peek_table.h must appear
in BOTH switches. What this cannot check is whether the sentence is the
RIGHT sentence - only that one exists, which is the failure that actually
happened.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = os.path.join(HERE, "..", "..", "contract", "peek_table.h")
CLIENT = os.path.join(HERE, "..", "..", "now-guest-ppc", "src", "act",
                      "act_client.c")

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def declared_errors(text):
    """Every kNowPeekActErr* the contract names, except None.

    `None` is excluded deliberately: it is the absence of an error and
    the mappings answer it, but a reader looking for "which failures can
    this plane report" should not have to subtract it here.
    """
    names = set(re.findall(r"\b(kNowPeekActErr[A-Za-z0-9_]+)\b", text))
    names.discard("kNowPeekActErrNone")
    return names


def body_of(text, signature):
    start = text.find(signature)
    if start == -1:
        failures.append("%s is not in act_client.c at all" % signature)
        return ""
    end = text.find("\n}", start)
    return text[start:end if end != -1 else len(text)]


def main():
    with open(CONTRACT, "r") as handle:
        contract = handle.read()
    with open(CLIENT, "r") as handle:
        client = handle.read()

    declared = declared_errors(contract)
    check(len(declared) >= 12,
          "only %d act errors found in the contract - the pattern that "
          "finds them has stopped matching, and this test would then pass "
          "by looking at nothing" % len(declared))

    for signature, what in (
            ("const char *now_act_error_code(", "a short code"),
            ("const char *now_act_error_message(", "a sentence")):
        body = body_of(client, signature)
        if not body:
            continue
        for name in sorted(declared):
            check("case %s:" % name in body,
                  "%s has no case for %s, so it answers the generic "
                  "act-refused - a real failure wearing the word for "
                  "'something refused', which is how a diagnosis becomes "
                  "a mystery" % (what, name))

    if failures:
        for line in failures:
            sys.stderr.write("FAIL: %s\n" % line)
        sys.stderr.write("%d failure(s)\n" % len(failures))
        return 1
    print("act_error_vocabulary_source: ok (%d errors mapped twice)"
          % len(declared))
    return 0


if __name__ == "__main__":
    sys.exit(main())
