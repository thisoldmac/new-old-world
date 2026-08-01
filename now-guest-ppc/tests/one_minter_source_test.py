#!/usr/bin/env python3
"""There is exactly ONE thing on this Mac that mints a reference.

Until 2026-07-31 there were two. src/act/act_ref.c and src/observe/obsref.c
both minted `now-window-` / `now-element-` tokens, from separate tables with
separate staleness rules, because each was written while the other was
unmerged. Nothing caught it: both compiled, both passed their own tests, and
the two would only have disagreed on a running Macintosh - a reference minted
by one might not resolve in the other, and a caller holding one could not tell
which it held.

THIS FILE EXISTS BECAUSE THE NATIVE TESTS CANNOT SEE THE DEFECT. The deciding
half of the reference layer (obsref.c, obsresolve.c) is Toolbox-free and
thoroughly tested; observe.c, which is the file that binds ONE registry to all
five wire surfaces, touches Carbon on every line and has no host test at all.
That was measured rather than assumed: pointing the resolver at a second,
never-minted-into registry - the exact shape of the old defect - compiled
clean and left all 58 native tests green. A gate that only fails on a machine
is a gate nobody runs before merging.

So the property is asserted structurally, where a text scan genuinely can see
it: the registry type appears once, the mint and lookup entry points are
called only from inside src/observe/, and no second table of references
exists anywhere in the guest.

WHAT IS NOT CLAIMED, in the same spirit as ot_connect_source_test.py and
get_cancel_source_test.py: that any of it runs. A source assertion says the
code still says what it was made to say. Behaviour needs a Macintosh.

Run with: python3 one_minter_source_test.py
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
OBSERVE = SRC / "observe"


def strip_comments(text: str) -> str:
    """Code only.

    Every identifier below is also written in the prose beside it - this
    layer's headers discuss `now_obs_mint` and `NowObsRegistry` at length, and
    the whole point of act_ref.c's removal is recorded in comments that name
    it. Reading the comments would make this test pass over deleted code,
    which is the failure the OT source test carries as a known note.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def sources():
    """Every C source and header in the PowerPC guest, comments removed."""
    for path in sorted(SRC.rglob("*.[ch]")):
        yield path, strip_comments(path.read_text())


ALL = list(sources())
assert len(ALL) > 40, f"expected the whole guest tree, found {len(ALL)} files"


# --- one registry ---------------------------------------------------------
# The type is declared once and instantiated once. A second instance is
# precisely the mutation that proved invisible: a resolver looking up in a
# table no observation writes refuses every reference ever minted, and says
# "no observation minted this reference" while doing it - the most plausible
# possible lie.
declares = [p for p, t in ALL if "} NowObsRegistry;" in t]
assert declares == [OBSERVE / "obsref.h"], declares

instances = []
for path, text in ALL:
    for match in re.finditer(r"\bNowObsRegistry\s+(\w+)\s*;", text):
        instances.append((path.relative_to(ROOT), match.group(1)))
assert instances == [(Path("src/observe/observe.c"), "g_registry")], instances


# --- one minter -----------------------------------------------------------
# now_obs_mint is the only function that creates a token, and it is called
# only from the walk. A call anywhere else is a second observation, whatever
# it is spelled.
minters = sorted(
    str(p.relative_to(ROOT)) for p, t in ALL if "now_obs_mint(" in t)
assert minters == [
    "src/observe/observe.c",
    "src/observe/obsref.c",
    "src/observe/obsref.h",
], minters

# And the resolver's own entry point is reached from exactly one place too:
# obsresolve.c decides, observe.c asks. Anything else holding a registry
# would be reading the table without the identity checks around it.
lookups = sorted(
    str(p.relative_to(ROOT)) for p, t in ALL if "now_obs_lookup(" in t)
assert lookups == [
    "src/observe/observe.c",
    "src/observe/obsref.c",
    "src/observe/obsref.h",
    "src/observe/obsresolve.c",
], lookups


# --- the act plane holds no references ------------------------------------
# It asks; it does not remember. The two resolve calls below are the whole of
# its addressing, and the contract that comes with them (observe.h) is that a
# verdict other than kNowObsOk is a refusal - so the act plane must have no
# way to reach a reference that did not come through them.
ACT = {p.name: t for p, t in ALL if p.parent.name == "act"}
assert "act_ref.c" not in ACT and "act_ref.h" not in ACT, sorted(ACT)

act_cmds = ACT["act_cmds.c"]
for call in ("now_observe_resolve_window(", "now_observe_resolve_element("):
    assert call in act_cmds, call
for forbidden in ("NowObsRegistry", "now_obs_mint(", "now_obs_lookup("):
    assert forbidden not in act_cmds, forbidden

# The token shape itself is written down in one place. A second literal is how
# two minters agreed on a format while disagreeing about everything else.
prefixes = sorted(
    str(p.relative_to(ROOT))
    for p, t in ALL
    if '"now-window-"' in t or '"now-element-"' in t)
assert prefixes == ["src/observe/obsref.c"], prefixes


# --- and the act plane cannot address anything else ------------------------
# The refusal the whole layer exists for, asserted where a scan can see it:
# no act verb reads a window or control by a name, a coordinate or a pointer
# the caller supplied. `element` and `window` are the only target arguments,
# and both are references.
targets = set(re.findall(r'arg_str\(json, kind == kNowObsKindWindow\s*\?\s*'
                         r'"(\w+)"\s*:\s*"(\w+)"', act_cmds))
assert targets == {("window", "element")}, targets
for banned in ('"frontmost"', '"front"', "GetFrontProcess", "FrontWindow"):
    assert banned not in act_cmds, banned

print("one_minter_source_test: all assertions passed")
