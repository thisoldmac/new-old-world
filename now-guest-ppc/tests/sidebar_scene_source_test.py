#!/usr/bin/env python3
"""Keep scene description safe when navigation rows are scrolled away.

``row_rect`` deliberately returns NULL for an off-screen navigation row.
Scene description visits every module, so it must skip that ordinary state
before adding a selection band or deriving icon/text rectangles.  The path is
Carbon-bound; this guard pins the required order directly in its owner.
"""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "src"
    / "workshop"
    / "workshop_sidebar.c"
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
    SOURCE,
    "void workshop_sidebar_describe_scene(const WorkshopSceneWriter *writer)",
)
lookup = body.index("const Rect *row = row_rect(module);")
guard = body.find("if (row == NULL)", lookup)
first_use = min(
    body.index("workshop_scene_add(writer, kWorkshopSceneSelectionBand", lookup),
    body.index("row->left", lookup),
)

if guard < 0 or guard > first_use:
    raise SystemExit(
        "workshop_sidebar_describe_scene dereferences an off-screen row; "
        "skip NULL row_rect results before scene output"
    )

print("ok")
