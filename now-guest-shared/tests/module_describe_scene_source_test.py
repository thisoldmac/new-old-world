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

HOW IT FINDS THE ENTRY, and why that is not a detail. C initializers are
POSITIONAL, so a reader that assumes an index is a reader that starts
agreeing with itself the moment the struct grows. This gate's first
version took the LAST element - and the very next commit appended
`copy_text` to `WorkshopModuleOps`, at which point it was reading the
wrong field for all seventeen pages and said so, loudly, for every one of
them. It was right to fail and wrong about why.

So the field order is DERIVED from `workshop_module.h` on every run, and
`describe_scene`'s index is looked up in it. If the member is renamed or
removed the gate stops rather than guessing.

Mutations to watch it fail: set screenshots_module.c's `describe_scene`
entry to NULL (it must name that file), and rename the member in
`workshop_module.h` (it must refuse to read anything rather than pass).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "now-guest-ppc/src"
OPS_HEADER = ROOT / "now-guest-ppc/src/workshop/workshop_module.h"

# The Toolbox calls that put words on screen without telling anyone.
TEXT_CALLS = ("DrawString", "DrawText", "TETextBox")

OPS_TYPE = "WorkshopModuleOps"
MEMBER = "describe_scene"


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.S)


def braced_body(text, start):
    """The {...} body beginning at or after `start`, without its braces."""
    i = text.index("{", start)
    depth = 0
    j = i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j], j
        j += 1
    return None, len(text)


def ops_field_order():
    """The members of WorkshopModuleOps, in declaration order.

    Derived, not remembered: a C initializer is positional, so knowing
    WHICH element is describe_scene means knowing where the header puts
    it. Function-pointer members declare their name inside parentheses -
    `void (*draw)(void);` - and plain members do not, so both shapes are
    read.
    """
    text = strip_comments(OPS_HEADER.read_text(errors="replace"))
    m = re.search(r"typedef\s+struct\s+" + OPS_TYPE + r"\s*\{", text)
    if m is None:
        return []
    body, _ = braced_body(text, m.start())
    if body is None:
        return []
    names = []
    for decl in body.split(";"):
        decl = decl.strip()
        if not decl:
            continue
        fn = re.search(r"\(\s*\*\s*(\w+)\s*\)", decl)
        if fn is not None:
            names.append(fn.group(1))
            continue
        plain = re.search(r"(\w+)\s*(?:\[[^\]]*\])?$", decl)
        if plain is not None:
            names.append(plain.group(1))
    return names


def text_call_lines(text):
    """Line numbers of every raw text draw."""
    hits = []
    for name in TEXT_CALLS:
        for m in re.finditer(r"(?<![A-Za-z0-9_])" + name + r"\s*\(", text):
            hits.append(text[:m.start()].count("\n") + 1)
    return sorted(hits)


def ops_initializers(text):
    """Every `... WorkshopModuleOps <name> = { ... };` body in the file."""
    bodies = []
    for m in re.finditer(OPS_TYPE + r"\s+\w+\s*=\s*\{", text):
        body, _ = braced_body(text, m.end() - 1)
        if body is not None:
            bodies.append((text[:m.start()].count("\n") + 1, body))
    return bodies


def elements(body):
    """Top-level initializer elements, in order.

    Split on commas at nesting depth zero only: an element may be a call
    or a braced sub-initializer, and splitting on every comma would
    renumber every field after the first one that contains an argument.
    """
    body = strip_comments(body)
    out = []
    depth = 0
    current = ""
    for ch in body:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(current.strip())
            current = ""
        else:
            current += ch
    if current.strip():
        out.append(current.strip())
    return out


def main():
    order = ops_field_order()
    if MEMBER not in order:
        print(f"{OPS_HEADER.relative_to(ROOT)}: no `{MEMBER}` member in "
              f"{OPS_TYPE} - this gate cannot say which initializer "
              "element it is reading, so it is refusing rather than "
              "guessing one", file=sys.stderr)
        return 1
    index = order.index(MEMBER)

    module_sources = sorted(SRC.rglob("*_module.c"))
    offenders = []
    unreadable = []
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
            unreadable.append(f"{rel}: no {OPS_TYPE} initializer found")
            continue

        for line, body in tables:
            parts = elements(body)
            if len(parts) <= index:
                unreadable.append(
                    f"{rel}:{line}: {len(parts)} initializer elements, "
                    f"but `{MEMBER}` is element {index + 1}")
                continue
            if parts[index] == "NULL":
                if draws:
                    offenders.append(
                        f"{rel}:{line}: draws text at line "
                        f"{draws[0]} but {MEMBER} is NULL")
            else:
                described += 1

    if offenders or unreadable:
        for o in offenders:
            print("  " + o, file=sys.stderr)
        for u in unreadable:
            print("  " + u + " - this gate read nothing about that page",
                  file=sys.stderr)
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
          f"describe what they draw ({MEMBER} is element {index + 1} of "
          f"{len(order)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
