"""Lane H2 shared probe helpers: the Finder's own answers about a window.

Every script here is scoped to a NAMED window — never a search. A whole-disk
Finder search wedged a real machine for ~12 minutes (lab finding 2026-07-05),
and that hazard is the reason `mirror.act.open`'s window items were never
implemented by hunting for a name.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2probe import agent_call                        # noqa: E402

ICON = 32          # the Finder's icon box: `bounds of` an item is pos..pos+32


def sc(src, timeout_ms=20000):
    """Run AppleScript through the mirror agent's own `script` verb and return
    the text, with OSADoScript's source-form quotes stripped."""
    r = agent_call("script", {"source": src, "timeoutMs": timeout_ms})
    if not r.get("ok"):
        raise RuntimeError(r["error"])
    out = r["result"]["output"]
    if out.startswith('"') and out.endswith('"') and len(out) >= 2:
        out = out[1:-1]
    if r["result"]["osaErr"]:
        raise RuntimeError(f'osaErr {r["result"]["osaErr"]}: {out}')
    return out


def window_items(index=1):
    """(content rect, [(name, x, y)…]) for Finder window `index`."""
    b = sc(f'tell application "Finder"\n'
           f'set b to bounds of window {index}\n'
           f'return (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b)'
           f' & "," & (item 4 of b) as text\n'
           f'end tell')
    rect = tuple(int(v) for v in b.split(","))
    raw = sc(f'tell application "Finder"\n'
             f'set r to ""\n'
             f'repeat with t in (get items of window {index})\n'
             f'set p to position of t\n'
             f'set r to r & (name of t) & "|" & (item 1 of p) & "," '
             f'& (item 2 of p) & ";;"\n'
             f'end repeat\n'
             f'return r\n'
             f'end tell')
    items = []
    for rec in raw.split(";;"):
        if not rec:
            continue
        name, coords = rec.split("|", 1)
        x, y = (int(v) for v in coords.split(","))
        items.append((name, x, y))
    return rect, items


def selection():
    return sc('tell application "Finder"\n'
              'set s to selection\n'
              'if (count s) is 0 then return ""\n'
              'return name of item 1 of s\n'
              'end tell')


def deselect():
    """Independent trials: clear the selection between clicks, so a hit is
    this click's doing and not the previous one's (the accumulating-oracle
    trap that produced the famous "~9 actuations per boot")."""
    sc('tell application "Finder"\nselect {}\nend tell')
