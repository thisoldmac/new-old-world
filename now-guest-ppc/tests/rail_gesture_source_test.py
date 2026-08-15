#!/usr/bin/env python3
"""Pin the rail's rearrange gesture to the words that teach it.

The gesture is a plain drag. It used to want Option, and the sentence
that taught the modifier lived in THREE places away from the code that
implemented it - the Preferences page's drawn line, its status line, and
the module definition's blurb. A gesture nobody can see is a gesture
nobody finds, so those sentences are the whole of the discoverability;
one of them left behind teaches a gesture that no longer works, which is
worse than saying nothing.

This is the pairing check: whatever the rail's click path does about
modifiers, the copy must agree. It cannot tell whether the drag WORKS -
only metal and the emulator answer that - which is why it asserts about
words and the modifier test, not about behaviour.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
sidebar = (SRC / "workshop/workshop_sidebar.c").read_text()
prefs_page = (SRC / "preferences/preferences_module.c").read_text()
prefs_def = (SRC / "preferences/preferences_module_definition.c").read_text()

# 1. The rail reads no modifier at all. optionKey in this file would mean
#    some press is being routed by a modifier again, and the sentences
#    below would be wrong the moment it was.
assert "optionKey" not in sidebar, (
    "the rail's rearrange carries no modifier; a modifier test here means "
    "the Preferences copy is teaching the wrong gesture"
)

# 2. Every press on a nav row goes through the drag tracker, and a press
#    that turns out to be a click still selects. Both halves: routing
#    through drag_row without the fallthrough would make the rail
#    unclickable, which is the failure this transition can actually cause.
assert "if (drag_row(" in sidebar, (
    "a press on a nav row must go through the drag tracker"
)
assert re.search(
    r"if \(drag_row\([^\n]*\n\s*return true;\s*\n\s*\}\s*\n"
    r"\s*if \(module != g_selected", sidebar
), "a press the tracker declined must fall through to selection"

# 3. The threshold is what separates a drag from a click now that no
#    modifier does. Losing it makes every click a one-pixel rearrange.
assert "kDragSlop" in sidebar, (
    "the drag threshold is the only thing left telling a drag from a click"
)

# 4. The copy. Drawn lines, the status line, and the blurb the host and
#    the docs read - all three, because all three carried the old wording.
for label, text in (
    ("preferences page", prefs_page),
    ("preferences definition", prefs_def),
):
    for quoted in re.findall(r'"((?:[^"\\]|\\.)*)"', text):
        assert "Option" not in quoted, (
            f"{label} still teaches an Option gesture: {quoted!r}"
        )

assert "drag a row" in prefs_page.lower(), (
    "the Preferences page must still state the gesture in words - that "
    "sentence is the discoverability"
)

# 5. The hover tag is where the retired rich density's description went,
#    so it must explain an EXPANDED row and not only a collapsed one. The
#    early return this guard names was really there: tag_idle predates the
#    density retirement, and left as it was the description would have had
#    nowhere at all to appear.
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


tag_idle = function_body(sidebar, "void workshop_sidebar_tag_idle(void)")
assert "!g_collapsed" not in tag_idle, (
    "the hover tag must explain an expanded row too - it carries the "
    "description no row draws any more"
)
tag_text = function_body(sidebar, "static const char *tag_text(")
assert "sidebar_subtitle" in tag_text and "title" in tag_text, (
    "the tag says the name when collapsed and the description when not"
)

print("rail_gesture_source_test: ok")
