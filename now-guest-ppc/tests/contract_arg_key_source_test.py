#!/usr/bin/env python3
"""No declared arg key may shadow an envelope key. For every verb.

The rule is stated once, in contract/asyncapi.yaml's preamble:

    RULE: an arg key must not shadow an envelope key (type, id, name,
    args, line). The classic guest scans a frame FLAT - first occurrence
    wins - so a shadowed key is read as the command name.

This test exists because that rule has now been broken twice, by two
different verbs, years of lesson apart:

  - `launch` shipped an arg named "name" to METAL. The family was moved
    to "target" and the rule was written into the preamble.
  - `transitions` declared "name" anyway (2026-08-05). Its start verb
    read the envelope's own `"name":"transitions"` and armed the literal
    string `transitions`, which is never a running process. Because the
    by-name route is tried before the serial/front/a5 selector, it also
    short-circuited the other three, so `transitions start` could not arm
    by ANY route and P5's plane could never publish. Found by driving a
    live guest, not by a test.

A rule that is only prose gets followed until someone does not read it.
This is the same rule, executable, over every verb at once - so the next
one costs a failing gate instead of an evening on an emulator.

WHY IT PARSES THE YAML BY HAND. No PyYAML dependency: a contributor who
cannot run a gate is not failing it (AGENTS.md), and a gate that silently
skips when an import is missing is worse than no gate for a rule whose
whole job is to fail. The structure it needs is four fixed indentation
levels and nothing more.

Run with: python3 contract_arg_key_source_test.py
"""

from pathlib import Path
import sys

# The envelope's own keys. A request frame carries `type`, `id`, `name`
# and either `args` or `line`; the flat scan sees all of them before it
# ever reaches the args object.
ENVELOPE_KEYS = {"type", "id", "name", "args", "line"}

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "contract" / "asyncapi.yaml"


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def key_of(line: str):
    """The mapping key on this line, or None if it is not one.

    Deliberately strict: a key line is `<indent><name>:` followed by end
    of line or a space. Anything else - a list item, a folded scalar's
    continuation, a `{ $ref: ... }` flow mapping - is not a key at this
    level and must not be read as one.
    """
    body = line.strip()
    if not body or body.startswith("#") or body.startswith("-"):
        return None
    if ":" not in body:
        return None
    name, _, rest = body.partition(":")
    if not name or " " in name.strip():
        return None
    if rest and not rest.startswith(" "):
        return None
    return name.strip().strip('"').strip("'")


def arg_keys_by_verb(text: str):
    """{verb: [arg keys]} for every verb under components.x-commands.

    Walks the four levels the contract actually uses:
        2  x-commands:
        4    <verb>:
        6      args:
        8        properties:
       10          <arg key>:
    """
    lines = text.splitlines()
    verbs = {}

    # Find x-commands and the indent its verbs sit at.
    start = None
    base = None
    for i, line in enumerate(lines):
        if key_of(line) == "x-commands":
            start = i
            base = indent_of(line)
            break
    if start is None:
        raise SystemExit("no x-commands block in the contract - this test "
                         "has lost its subject and must not pass quietly")

    verb_indent = None
    verb = None
    in_args = None       # indent of the `args:` key for the current verb
    in_props = None      # indent of the `properties:` key under it

    for line in lines[start + 1:]:
        if not line.strip():
            continue
        ind = indent_of(line)
        if ind <= base:
            break                       # out of x-commands entirely
        k = key_of(line)
        if k is None:
            continue
        if verb_indent is None:
            verb_indent = ind
        if ind == verb_indent:
            verb = k
            verbs.setdefault(verb, [])
            in_args = None
            in_props = None
            continue
        if verb is None:
            continue
        if in_args is None:
            if k == "args" and ind == verb_indent + 2:
                in_args = ind
            continue
        if ind <= in_args:
            in_args = None              # left the args block
            in_props = None
            continue
        if in_props is None:
            if k == "properties" and ind == in_args + 2:
                in_props = ind
            continue
        if ind <= in_props:
            in_props = None
            continue
        if ind == in_props + 2:
            verbs[verb].append(k)

    return verbs


def main() -> int:
    text = CONTRACT.read_text()
    verbs = arg_keys_by_verb(text)

    # The parse must have found a real inventory. A walker that silently
    # matched nothing would pass this test forever - the exact shape of
    # failure the rule itself is about.
    if len(verbs) < 30:
        raise SystemExit(f"only {len(verbs)} verbs parsed out of "
                         f"components.x-commands; the walker is broken, "
                         f"not the contract")
    if "hide" not in verbs or "target" not in verbs.get("hide", []):
        raise SystemExit("`hide` should declare a `target` arg; the walker "
                         "is not reading arg keys correctly")
    if "transitions" not in verbs:
        raise SystemExit("`transitions` is missing from x-commands")

    bad = []
    for verb, keys in sorted(verbs.items()):
        for k in keys:
            if k in ENVELOPE_KEYS:
                bad.append((verb, k))

    if bad:
        for verb, k in bad:
            print(f"FAIL: `{verb}` declares an arg named `{k}`, which "
                  f"shadows an envelope key. The classic guest scans a "
                  f"frame flat and will read the envelope's own `{k}` "
                  f"instead. Use `target` for a by-name selector - see the "
                  f"arg-key rule in contract/asyncapi.yaml's preamble.",
                  file=sys.stderr)
        return 1

    total = sum(len(v) for v in verbs.values())
    print(f"contract_arg_key_source_test: ok "
          f"({len(verbs)} verbs, {total} arg keys, none shadow "
          f"{sorted(ENVELOPE_KEYS)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
