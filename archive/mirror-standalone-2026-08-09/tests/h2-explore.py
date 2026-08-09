#!/usr/bin/env python3
"""Lane H2, exploration: what does the Finder actually say about a window's
items, and in what coordinate space?

Nothing here is a test. It opens ONE named folder window and asks the Finder
about THAT window — never a search (a whole-disk Finder search wedged a real
machine for ~12 minutes, lab finding 2026-07-05).
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from h2probe import agent_call                        # noqa: E402

FOLDER = sys.argv[1] if len(sys.argv) > 1 else "Macintosh HD:TimBotTu"


def sc(src, timeout_ms=20000):
    r = agent_call("script", {"source": src, "timeoutMs": timeout_ms})
    if not r.get("ok"):
        return r["error"]
    out = r["result"]["output"]
    if out.startswith('"') and out.endswith('"') and len(out) >= 2:
        out = out[1:-1]
    return {"out": out, "osaErr": r["result"]["osaErr"]}


print("== open the folder ==")
print(sc(f'tell application "Finder"\n'
         f'open folder "{FOLDER}"\n'
         f'return (count windows) as text\n'
         f'end tell'))

print("\n== window 1: name, bounds, view, position/bounds of the window ==")
print(sc('tell application "Finder"\n'
         'set w to window 1\n'
         'set b to bounds of w\n'
         'return (name of w) & "|" & (item 1 of b) & "," & (item 2 of b) & ","'
         ' & (item 3 of b) & "," & (item 4 of b)\n'
         'end tell'))

print("\n== the window's folder (item of window) ==")
print(sc('tell application "Finder"\n'
         'return (item of window 1) as text\n'
         'end tell'))

print("\n== items of that window, with `position` ==")
print(sc('tell application "Finder"\n'
         'set r to ""\n'
         'repeat with t in (get items of window 1)\n'
         'set p to position of t\n'
         'set r to r & (name of t) & "|" & (item 1 of p) & "," & (item 2 of p) & ";;"\n'
         'end repeat\n'
         'return r\n'
         'end tell'))

print("\n== the same items' `bounds` (if the Finder answers) ==")
print(sc('tell application "Finder"\n'
         'set r to ""\n'
         'try\n'
         'repeat with t in (get items of window 1)\n'
         'set b to bounds of t\n'
         'set r to r & (name of t) & "|" & (item 1 of b) & "," & (item 2 of b)'
         ' & "," & (item 3 of b) & "," & (item 4 of b) & ";;"\n'
         'end repeat\n'
         'on error e\n'
         'return "ERR " & e\n'
         'end try\n'
         'return r\n'
         'end tell'))

print("\n== what the axtree plane says the window rect is ==")
tree = agent_call("axtree", {"scope": "all"})["result"]
print(json.dumps([
    {"app": p.get("name"),
     "wins": [{"title": w.get("title"), "rect": w.get("rect")}
              for w in p.get("windows", [])]}
    for p in tree.get("processes", tree.get("apps", []))
    if p.get("windows")], indent=1)[:2000])
