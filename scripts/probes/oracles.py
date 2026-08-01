"""Actuation oracles: things the GUEST changed, read back from the guest.

Ported from `timbottu/mirror/tests/trials.py` and `nohijack-probe.py`. The rule
they encode is the one rule none of these harnesses may relax:

    The oracle must be something the GUEST changed, not something the
    responder reported.

NOW's own contract states the same constraint from the other side, about the
act plane it has declared: "an ok reply means the event was handed to the
addressed element's own application, never that the window moved or the text
changed... There is deliberately no `performed` field for a responder to set
true."

## One thing genuinely IMPROVED in the crossing

Upstream's strongest oracle — a folder on disk, created by a hijacked
Finder File/New Folder — needed a LAB INSTRUMENT to read. Mirror's probes
imported `timbottu_mcp_classic.harness.Harness` and drove a second guest
process (the TimBotTu anchor worker) purely to `stat` and `delete` a path,
because Mirror's own guest could not read its filesystem.

NOW's guest can. `ls` is wire-served and `file.trash` is a typed control
message, both on the one link the probe already holds. So the folder oracle
crosses with NO second process, no second port, and no dependency on another
project's client. That is a real reduction in what a run needs to be set up,
and it removes the `--anchor-port` argument every upstream probe carried.

The METHODOLOGY is unchanged, which is what keeps the numbers comparable: the
same six candidate names are probed, every trial clears them first, and the
oracle is still a fact on disk rather than anything a verb said.
"""

from __future__ import annotations

from nowwire import GuestError, GuestLink

# How many `untitled folder*` names the Desktop oracle looks for.
# `trials.py` upstream scanned 59 because its case let them accumulate; the
# no-hijack probe clears them every trial, so at most a couple can exist — and
# each name is a wire round trip, which at 59 names made a trial take minutes.
DESKTOP_FOLDER_SCAN = 6

DESKTOP = "Macintosh HD:Desktop Folder"


def _folder_names(link: GuestLink, path: str) -> set:
    """Every name `ls` reports in one folder.

    `ls` answers a rowArray of [name, description] pairs, so the names are
    column 0. A folder that does not exist is a GuestError, not an empty set —
    the caller must not read "the Desktop is missing" as "no folders were
    created".
    """
    out = link.command("ls", line=path)
    return {row[0] for row in link.rows(out, "ls") if row}


def desktop_untitled_folders(link: GuestLink) -> set:
    """Finder new-folder names on the Desktop — the menu case's hijack oracle,
    and a fact on disk rather than anything the responder said.

    Returned as the same suffix set upstream returned ("1", "2", ...) so a
    ported trial record compares field-for-field with `p2-nohijack.json`.
    """
    names = _folder_names(link, DESKTOP)
    found = set()
    for suffix in [""] + [f" {i}" for i in range(2, DESKTOP_FOLDER_SCAN + 1)]:
        if f"untitled folder{suffix}" in names:
            found.add(suffix or "1")
    return found


def clear_desktop_untitled_folders(link: GuestLink) -> int:
    """Independent trials: what one trial created must not be there for the
    next one to see.

    The "~9 actuations per boot" ceiling this project once reported was an
    ACCUMULATING ORACLE, not a defect. A probe that leaves the previous
    trial's state behind measures a different machine each time.
    """
    removed = 0
    for name in desktop_untitled_folders(link):
        suffix = "" if name == "1" else f" {name}"
        path = f"{DESKTOP}:untitled folder{suffix}"
        try:
            link.message({"type": "file.trash", "path": path})
            # file.trash answers on its own plane. Draining it here keeps the
            # next command's reply from arriving behind an unread message.
            link.wait_for_types(("file.done", "file.refuse", "error"),
                                timeout=15.0)
            removed += 1
        except (GuestError, TimeoutError, OSError):
            # A trash that failed is reported by the NEXT read of the oracle,
            # which is the reading that matters. Swallowing it here and
            # swallowing it silently are different things: the trial's
            # `foldersBefore` will be non-empty and the trial is then
            # unusable, which the caller can see.
            pass
    return removed


def running_processes(link: GuestLink) -> list:
    """[(name, description)] from `ps` — NOW's process table.

    The substitute for Mirror's `observe`.processes, and WEAKER in one way
    that must be stated wherever it is used as an oracle: `ps` lists a
    process from the moment it exists, whereas `observe` could be asked for a
    WINDOW, and an application that has been launched but has not yet opened a
    window has also not yet installed its Apple Event handlers. Upstream's
    apple-event probe waits for a window for exactly that reason. A probe that
    substitutes `ps` here measures a race it did not mean to.
    """
    out = link.command("ps")
    return [(row[0], row[1] if len(row) > 1 else "")
            for row in link.rows(out, "ps") if row]


def front_app(link: GuestLink) -> str | None:
    """The frontmost application's name, from `ps`.

    now-guest-ppc marks the front process in its description column ("front"),
    which is what this reads. `front` is a verb that CHANGES the front app;
    reading it is `ps`.
    """
    for name, desc in running_processes(link):
        if "front" in (desc or ""):
            return name
    return None


def is_running(link: GuestLink, name: str) -> bool:
    lowered = name.strip().lower()
    return any((n or "").strip().lower() == lowered
               for n, _ in running_processes(link))
