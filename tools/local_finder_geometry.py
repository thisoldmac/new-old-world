"""What the Finder says is on its desktop, and where it is SAFE to drop.

Shared by the `local-*` drag instruments, and shared deliberately: the
half of this that matters is not the geometry, it is `clear_spot`'s
refusal to aim a drag at anything the Finder reported. That is a SAFETY
rule — a drop inside an open window FILES the item into that folder
rather than rearranging the desktop — and a safety rule kept in two
copies is one edit away from being true in only one of them (AGENTS.md:
state a limit once, where both sides read it).

Every answer here is the FINDER'S OWN, through `bounds of` and the
guest's own element walk. Nothing is arithmetic over a screenshot.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402,F401

ICON = 32


def rows(reply, key):
    """The reply's display rows as a dict. A convenience, not a contract."""
    out = {}
    for row in (reply.get(key) or []) if isinstance(reply, dict) else []:
        if isinstance(row, list) and len(row) == 2:
            out[row[0]] = row[1]
    return out


def script(link, src, timeout=120):
    d = rows(link.command("script", {"source": src}, timeout=timeout),
             "script")
    if d.get("osaErr") not in (None, "0"):
        raise RuntimeError(f"AppleScript refused: osaErr={d.get('osaErr')}")
    raw = d.get("output") or ""
    # OSADoScript renders its result in SOURCE form, so text is quoted.
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = raw[1:-1]
    return raw


def desktop_items(link):
    """Every desktop icon and the box the FINDER DREW, in global coords.

    `bounds of`, never `position of`: in a list view `position` answers
    the saved icon grid the window is not drawing, and the whole reason
    this project has trustworthy geometry is that it stopped asking the
    saved grid anything (MirrorKit's FinderItems header carries the
    measurement)."""
    raw = script(link,
                 'tell application "Finder"\nset r to ""\n'
                 'repeat with t in (get items of desktop)\n'
                 'set q to bounds of t\n'
                 'set r to r & (name of t) & "|" & (item 1 of q) & "," & '
                 '(item 2 of q) & "," & (item 3 of q) & "," & '
                 '(item 4 of q) & ";;"\nend repeat\nreturn r\nend tell')
    items = []
    for rec in raw.split(";;"):
        if not rec or "|" not in rec:
            continue
        name, _, box = rec.partition("|")
        try:
            l, t, r_, b = (int(n) for n in box.split(","))
        except ValueError:
            continue
        items.append({"name": name, "l": l, "t": t, "r": r_, "b": b})
    return items


def finder_psn(link):
    """The Finder's process serial number, out of the scene's own roster.

    Aimed rather than left to default. `elements` with no arguments walks
    the FRONT process, and what is frontmost is exactly the thing this
    script keeps changing -- so a walk that happened to catch NOW would
    report no Finder windows and read identically to a machine that has
    none."""
    doc = link.scene(full=True, timeout=180)[0]
    for proc in doc.get("processes") or []:
        if proc.get("name") == "Finder":
            hi, _, lo = str(proc.get("psn") or "").partition(".")
            if hi.isdigit() and lo.isdigit():
                return int(hi), int(lo)
    return None


def finder_windows(link, psn):
    """The Finder's windows as the GUEST's own element walk sees them.

    This is the half that had never been asked for. The desktop is an
    ordinary window in the window list, so the reference that names it is
    minted by the same walk that names every other window -- which is why
    dragpress's window form reaches a desktop icon at all."""
    el = link.command("elements",
                      {"serialHi": psn[0], "serialLo": psn[1]}, timeout=180)
    out = []
    for proc in (el.get("elements") or {}).get("processes") or []:
        if proc.get("name") != "Finder":
            continue
        for win in proc.get("windows") or []:
            out.append(win)
    return out


def clear_spot(items, avoid, w, h, bounds, obstacles=()):
    """A destination box that overlaps nothing the Finder reported.

    Refused rather than guessed: if the desktop is too full to find one,
    this returns None and the run stops. A drag aimed at a spot we did
    not check is a drag that could drop a file INTO something.

    `obstacles` is the half that was missing and it is not a detail. The
    first version avoided desktop ICONS only, and the first destination it
    picked on this desk was (56,76) — a 32-pixel box whose bottom five
    rows lay inside the open `Macintosh HD` WINDOW at top=103. Dropping
    there is not a rearrangement at all: it FILES the item into that
    folder, which is precisely the destructive outcome the rule about
    guessed drop targets exists to prevent, arriving through the one gap
    an icon-only check leaves. Every open window on the desk is an
    obstacle here, the desktop's own excepted."""
    for y in range(bounds["t"] + 40, bounds["b"] - h - 40, 24):
        for x in range(bounds["l"] + 40, bounds["r"] - w - 40, 24):
            box = (x, y, x + w, y + h)
            if any(it is not avoid
                   and not (box[2] <= it["l"] or box[0] >= it["r"]
                            or box[3] <= it["t"] or box[1] >= it["b"])
                   for it in items):
                continue
            if any(not (box[2] <= o["l"] or box[0] >= o["r"]
                        or box[3] <= o["t"] or box[1] >= o["b"])
                   for o in obstacles):
                continue
            return box
    return None


