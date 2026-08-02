#!/usr/bin/env python3
"""Every content hook stamps ticks BEFORE it branches on the mode.

WHY A SOURCE TEST. The ten QuickDraw hooks in ext/src/now_content.c run
at draw time inside an armed application's context; no compiler here can
execute them, and the plane's testable half (now_content_logic.c) never
sees this path. The defect this pins is one this project has already
paid for once, in the archived port:

  content_stamp() ran only on the count-mode branch, so a Record session
  froze `ticks` at its arm-time value and every drained record carried
  the SAME stamp - measured on a real drain: 19 records, ticks all 1735.
  SceneIslands orders redraws by that field, so a frozen stamp cannot
  tell two later blits apart. Nothing crashed and nothing refused; the
  data was simply unordered while looking ordered.

The fix is an ordering fact, invisible to an after-the-fact inspection
of any single run: each hook calls content_stamp() unconditionally,
after its counter and before the kNowContentModeRecord branch. This
reads that order out of the source. What it can catch is the exact
regression that shipped once - a tidy-up moving the stamp back into an
else-branch. What it cannot do is prove the stamp's value on a machine;
only a drain on one can, and WP0's first-arm run is where that happens.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "..", "..", "ext", "src", "now_content.c")

HOOKS = [
    "content_text",
    "content_line",
    "content_rect",
    "content_rrect",
    "content_oval",
    "content_arc",
    "content_poly",
    "content_rgn",
    "content_bits",
    "content_comment",
]

# content_comment counts and stamps but never records - picComments have
# no ring payload by design - so it alone carries no mode branch.
NO_RECORD_BRANCH = {"content_comment"}

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)


def bodies(text):
    """Each hook's own code, from its definition to the closing brace."""
    out = {}
    for name in HOOKS:
        match = re.search(r"^static pascal void %s\(" % re.escape(name),
                          text, re.M)
        if match is None:
            failures.append("%s is not in the source at all" % name)
            continue
        end = text.find("\n}", match.start())
        out[name] = text[match.start():end if end != -1 else len(text)]
    return out


def main():
    with open(SOURCE, "r") as handle:
        text = handle.read()

    for name, body in bodies(text).items():
        stamp = body.find("content_stamp();")
        branch = body.find("kNowContentModeRecord")
        counter = body.find("gBlock->counters.")
        check(stamp != -1,
              "%s never stamps ticks - a Record session drains records "
              "that all carry the arm-time value" % name)
        if name in NO_RECORD_BRANCH:
            check(branch == -1,
                  "%s grew a mode branch - it is no longer exempt; move "
                  "it out of NO_RECORD_BRANCH so the order is pinned"
                  % name)
        else:
            check(branch != -1,
                  "%s has no mode branch - the hook shape changed and "
                  "this test no longer reads it; update both together"
                  % name)
        if stamp != -1 and branch != -1:
            check(stamp < branch,
                  "%s stamps only after (or inside) the mode branch - "
                  "the count-mode-only regression, back again" % name)
        if stamp != -1 and counter != -1:
            check(counter < stamp,
                  "%s stamps before its counter - order drifted from "
                  "the shape the archive fix established" % name)
        check(re.search(r"else\s*\{\s*content_stamp\(\);", body) is None,
              "%s carries the else-branch stamp, the exact shape that "
              "froze Record stamps once already" % name)

    if failures:
        for line in failures:
            sys.stderr.write("FAIL: %s\n" % line)
        sys.stderr.write("%d failure(s)\n" % len(failures))
        return 1
    print("content_stamp_order_source: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
