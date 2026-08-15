#!/usr/bin/env python3
"""A Workshop page that DRAWS text must be able to SAY what it drew.

The host's observation plane reads a window through `describe_scene`:
the Workshop describes its own chrome, `workshop_sidebar.c` describes the
rail, and every control is already a Control Manager fact that
`control_kind.c` hands over. Everything else on a page - a heading, a
fact row, a scrollback line, a probe's refusal sentence - is raw
QuickDraw, and raw QuickDraw tells nobody anything.

For most of this project's life exactly ONE module implemented the op
(screenshots). The other sixteen ended their ops table in NULL, so a host
looking at fourteen of the seventeen pages saw window chrome and an empty
body - and an empty body is precisely what a page with nothing on it
looks like. That is the shape of failure this repository has already paid
for once at a different layer: an instrument that reports absence and
defect in the same words (AGENTS.md, "an instrument that READS a live
machine must assert that the plane armed").

So the rule, and it is deliberately narrow:

    if a module's own source draws text, its ops table's
    describe_scene entry is not NULL.

WHAT THIS DOES NOT CLAIM, said plainly, because a gate that overstates
itself is worse than none. It does not check that every string reaches
the writer, that the rects match the pixels, or that a page's helper
files (a card view, a share pane) describe their own drawing. Those are
judgments about content; this is a check that the seam exists at all. A
page can satisfy this gate and still under-report - `cloud_module.c` says
so in its own comment - but a page CANNOT satisfy it while having no way
to report anything, which is the state all sixteen were in.

Mutation to watch it fail: set screenshots_module.c's last ops entry back
to NULL and run this. It must name that file.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "now-guest-ppc/src"

# The Toolbox calls that put words on screen without telling anyone.
TEXT_CALLS = ("DrawString", "DrawText", "TETextBox")

# The ops table's last member. Found by name so a member added to
# WorkshopModuleOps in the middle cannot silently shift which entry this
# reads - the initializer is positional, and a positional reader that
# guesses is how a gate starts agreeing with itself.
OPS_TYPE = "WorkshopModuleOps"


def text_call_lines(text):
    """Line numbers of every raw text draw, ignoring comments crudely."""
    hits = []
    for name in TEXT_CALLS:
        for m in re.finditer(r"(?<![A-Za-z0-9_])" + name + r"\s*\(", text):
            hits.append(text[:m.start()].count("\n") + 1)
    return sorted(hits)


def ops_initializers(text):
    """Every `... WorkshopModuleOps <name> = { ... };` body in the file."""
    bodies = []
    for m in re.finditer(OPS_TYPE + r"\s+\w+\s*=\s*\{", text):
        depth = 0
        i = m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append((text[:m.start()].count("\n") + 1,
                                   text[m.end():i]))
                    break
            i += 1
    return bodies


def last_entry(body):
    """The final initializer element, comments and whitespace removed."""
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    parts = [p.strip() for p in body.split(",")]
    parts = [p for p in parts if p != ""]
    return parts[-1] if parts else ""


def main():
    module_sources = sorted(SRC.rglob("*_module.c"))
    offenders = []
    tableless = []
    described = 0

    for path in module_sources:
        rel = str(path.relative_to(ROOT))
        text = path.read_text(errors="replace")
        draws = text_call_lines(text)
        tables = ops_initializers(text)

        if not tables:
            # A file named like a module with no ops table is either a
            # rename this gate has not been told about or a table built
            # some other way. Either way it is not something to pass in
            # silence.
            tableless.append(rel)
            continue

        for line, body in tables:
            entry = last_entry(body)
            if entry == "NULL":
                if draws:
                    offenders.append(
                        f"{rel}:{line}: draws text at line "
                        f"{draws[0]} but describe_scene is NULL")
            else:
                described += 1

    if offenders or tableless:
        for o in offenders:
            print("  " + o, file=sys.stderr)
        for t in tableless:
            print(f"  {t}: no {OPS_TYPE} initializer found - this gate "
                  "read nothing about that page", file=sys.stderr)
        print("\nA page that draws with QuickDraw and has no "
              "describe_scene is invisible to the host's observation "
              "plane, and invisible looks exactly like empty. Emit the "
              "same strings and rects draw() already computes, using the "
              "kinds in workshop/workshop_scene.h; the pattern the other "
              "pages use is one walk taken twice, drawing on a NULL "
              "writer and describing on a real one.", file=sys.stderr)
        return 1

    if described == 0:
        print("no module ops tables found - this asserted nothing",
              file=sys.stderr)
        return 1

    print(f"ok: {len(module_sources)} Workshop pages, {described} "
          "describe what they draw")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
