#!/usr/bin/env python3
"""Probe `textget` / `textset` — the Portal's TEXT_GET / TEXT_SET (op 5).

The oracle is guest state, and where possible it is a SECOND, INDEPENDENT READ
PATH. That matters more here than anywhere else in the Portal so far, because
`textset`'s reply already contains a read-back: the guest re-reads the object
after writing it. That read-back is real evidence, but it travels the same
code, in the same call, through the same hook — so it cannot rule out a verb
that faithfully reports its own private copy of a string.

Two independent paths are therefore used:

  * `axtree`'s per-window `textEdit.text`. That comes from axtext.c, which
    walks the target's DialogRecord and TERec from OUTSIDE the process over the
    ax_memory seam. It shares no code with the Portal, no call, and no moment.
    Where it applies, it is the strongest oracle this project has for text.
  * a fresh `textget` in a separate round trip, after a settle.

Both must agree with what was written, or the trial does not count as
actuated.

Independence between trials: every trial closes the dialog and reopens it, and
writes a value unique to that trial. The "~9 actuations per boot" ceiling that
this project once reported was an accumulating oracle, not a defect; a probe
that leaves the previous trial's string in the field measures a different
machine each time.

Usage (a guest must already be up, e.g. via tools/spin-up.sh):

    python3 tests/textops-probe.py --agent-port 1728 --anchor-port 1708
    python3 tests/textops-probe.py ... --case ditem --case te --n 20
"""

from __future__ import annotations

import argparse
import json
import os
import random
import string
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from trials import Agent, GuestError  # noqa: E402

MIRROR = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.path.abspath(os.path.join(MIRROR, ".."))
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

# Dialogs.h:93-103. The type byte's high bit (itemDisable, 128) is masked off
# by the guest before it reports itemType, so these compare directly.
CTRL_ITEM, STAT_TEXT, EDIT_TEXT = 4, 8, 16
ITEM_DISABLE = 128          # Dialogs.h:103 — rides in the type byte's high bit


def item_kind(t: int) -> int:
    """The item's type with itemDisable masked off. `textget` reports the RAW
    byte, so SimpleText's Find field reads 144 (editText|itemDisable) and its
    label 136 (statText|itemDisable). Comparing 144 against 16 is how a probe
    quietly decides a dialog has no text in it."""
    return t & ~ITEM_DISABLE

# MacWindows.h:433.
DIALOG_KIND = 2

# CONTROL-SURFACE.md: the `key` verb wants INTEGERS on the raw wire, the mods
# are evtQModifiers bits, and menu shortcuts match on KEYCODE, not character.
KEY_ESC = {"code": 53, "char": 27, "mods": 0}
KEY_CMD_F = {"code": 3, "char": 102, "mods": 256}
KEY_RETURN = {"code": 36, "char": 13, "mods": 0}
CMD = 256


# --- guest reads ------------------------------------------------------------

def front(agent: Agent):
    for p in agent.call("observe").get("processes", []):
        if p.get("front"):
            return p.get("name")
    return None


def windows(agent: Agent) -> list:
    return agent.call("axtree", {"scope": "front"}).get("windows", [])


def dialogs(agent: Agent) -> list:
    return [w for w in windows(agent) if w.get("kind") == DIALOG_KIND]


def outside_text(agent: Agent, z: int):
    """The INDEPENDENT oracle: the dialog's TERec, read from outside the
    process by axtext.c over the ax_memory seam. Shares nothing with the
    Portal path."""
    for w in windows(agent):
        if w.get("z") == z:
            te = w.get("textEdit")
            return te.get("text") if te else None
    return None


# --- setup ------------------------------------------------------------------

def launch_simpletext(agent: Agent, h: Harness) -> bool:
    if front(agent) == "SimpleText":
        return True
    h.request("launch", {"path": SIMPLETEXT})
    for _ in range(15):
        time.sleep(2)
        if front(agent) == "SimpleText":
            return True
    return False


def close_dialogs(agent: Agent, tries: int = 3) -> None:
    for _ in range(tries):
        if not dialogs(agent):
            return
        agent.call("key", KEY_ESC)
        time.sleep(1.2)


def open_find(agent: Agent, settle: float = 2.5):
    """SimpleText's Find dialog — one editText item, modal, and cheap to open
    and close. Modal is FINE: ModalDialog pumps GetNextEvent, so the Portal's
    GNEFilter hook still runs inside it."""
    agent.call("key", KEY_CMD_F)
    time.sleep(settle)
    for w in dialogs(agent):
        return w
    return None


def text_items(agent: Agent, w: dict) -> list:
    """Every item in the dialog that holds text, by type. Discovered by asking
    the guest rather than by assuming a DITL layout — a hardcoded item number
    is a phantom constant with extra steps."""
    found = []
    for item in range(1, 33):
        try:
            r = agent.call("textget", {"windowZ": w["z"], "window": w["title"],
                                       "kind": "ditem", "item": item})
        except GuestError as e:
            if "no such dialog item" in str(e):
                break
            continue                     # not_text: a button, an icon, a line
        found.append({"item": item, "type": r["itemType"], "text": r["text"]})
    return found


def find_edit_item(agent: Agent, w: dict):
    for it in text_items(agent, w):
        if item_kind(it["type"]) == EDIT_TEXT:
            return it
    return None


def value(n: int = 8) -> str:
    """A per-trial value. Distinct from every other trial's, so a stale read
    can never be mistaken for a successful write."""
    return "".join(random.choice(string.ascii_uppercase) for _ in range(n))


# --- the cases --------------------------------------------------------------

def read_trial(agent: Agent, kind: str, w: dict, item: int | None,
               handle: int | None, seed: str) -> dict:
    """TEXT_GET: type a known string into the field, then read it back through
    the Portal and check it against what the OUTSIDE path sees.

    The string is put there by the guest's own key plane, not by textset — a
    read test that writes with the thing it is testing proves nothing."""
    args = {"windowZ": w["z"], "window": w["title"], "kind": kind}
    if item is not None:
        args["item"] = item
    if handle is not None:
        args["handle"] = handle
    t = {"kind": kind, "want": seed}
    try:
        r = agent.call("textget", args)
    except GuestError as e:
        t.update(replied=False, error=str(e), correct=False)
        return t
    t.update(replied=True, got=r["text"], length=r["length"],
             itemType=r["itemType"], teHandle=r["teHandle"])
    t["outside"] = outside_text(agent, w["z"])
    t["correct"] = (r["text"] == seed)
    t["agrees_outside"] = (t["outside"] == seed) if t["outside"] is not None \
        else None
    return t


def write_trial(agent: Agent, kind: str, w: dict, item: int | None,
                handle: int | None, want: str, settle: float) -> dict:
    args = {"windowZ": w["z"], "window": w["title"], "kind": kind,
            "text": want}
    if item is not None:
        args["item"] = item
    if handle is not None:
        args["handle"] = handle
    t = {"kind": kind, "want": want}
    try:
        r = agent.call("textset", args)
    except GuestError as e:
        t.update(replied=False, error=str(e), actuated=False)
        return t
    t.update(replied=True, readback=r["text"])
    time.sleep(settle)
    # Oracle 1: a FRESH round trip, not the set's own reply.
    reread = {"windowZ": w["z"], "window": w["title"], "kind": kind}
    if item is not None:
        reread["item"] = item
    if handle is not None:
        reread["handle"] = handle
    try:
        t["fresh"] = agent.call("textget", reread)["text"]
    except GuestError as e:
        t["fresh"] = f"<error {e}>"
    # Oracle 2: the independent outside read path.
    t["outside"] = outside_text(agent, w["z"])
    t["actuated"] = (t["fresh"] == want)
    t["agrees_outside"] = (t["outside"] == want) if t["outside"] is not None \
        else None
    return t


def case_text(agent: Agent, h: Harness, kind: str, n: int, settle: float,
              use_handle: bool = False) -> dict:
    """Read then write, N independent trials, dialog reopened each time."""
    print(f"\n== case {kind}{' (explicit handle)' if use_handle else ''} "
          f"— N={n} ==")
    if not launch_simpletext(agent, h):
        return {"case": kind, "error": "SimpleText never came to the front"}
    trials = []
    for i in range(n):
        _t = [("start", time.time())]
        close_dialogs(agent)
        _t.append(("close", time.time()))
        w = open_find(agent)
        _t.append(("open", time.time()))
        if w is None:
            trials.append({"valid": False, "why": "no dialog"})
            continue
        edit = find_edit_item(agent, w)
        _t.append(("items", time.time()))
        if edit is None:
            trials.append({"valid": False, "why": "no editText item"})
            continue
        item = edit["item"] if kind == "ditem" else None
        handle = None
        if use_handle:
            probe = agent.call("textget", {"windowZ": w["z"],
                                           "window": w["title"],
                                           "kind": "dialogte"})
            handle = probe["teHandle"]
            if not handle:
                trials.append({"valid": False, "why": "no TEHandle"})
                continue

        # READ: seed through the guest's own KEY plane, then read it back.
        #
        # The field is cleared first with `textset ""`. Using the verb under
        # test for SETUP is fine and using it as the ORACLE is not: if the
        # clear silently failed, the leftover string would not match this
        # trial's seed and the trial would fail. It cannot manufacture a pass.
        seed = value()
        try:
            agent.call("textset", dict({"windowZ": w["z"],
                                        "window": w["title"], "kind": kind,
                                        "text": ""},
                                       **({"item": item} if item else {}),
                                       **({"handle": handle} if handle else {})))
        except GuestError:
            pass
        time.sleep(0.4)
        for ch in seed:
            agent.call("key", {"code": key_code(ch), "char": ord(ch),
                               "mods": 0})
        time.sleep(settle)
        _t.append(("seed", time.time()))
        rd = read_trial(agent, kind, w, item, handle, seed)
        _t.append(("read", time.time()))

        # WRITE: a different value again, so neither can be confused for the
        # other.
        want = value()
        wr = write_trial(agent, kind, w, item, handle, want, settle)
        _t.append(("write", time.time()))
        if os.environ.get("TEXTOPS_TIMING"):
            print("      phases: " + "  ".join(
                f"{_t[k][0]}={_t[k][1] - _t[k - 1][1]:.1f}"
                for k in range(1, len(_t))))

        trials.append({"valid": True, "read": rd, "write": wr})
        print(f"  {i + 1:2}/{n}  read {'ok ' if rd.get('correct') else 'MISS'}"
              f" ({rd.get('got')!r} want {seed!r})   "
              f"write {'ok ' if wr.get('actuated') else 'MISS'}"
              f" ({wr.get('fresh')!r} want {want!r})"
              f"  outside={wr.get('outside')!r}")
    close_dialogs(agent)
    return summarize(kind, trials)


# The `key` verb wants a keycode. Uppercase letters are typed as the unshifted
# letter and compared case-insensitively where needed; these are the standard
# ADB virtual key codes for A-Z (Inside Macintosh: Toolbox Essentials, the
# Event Manager key-code figure; the same table CONTROL-SURFACE.md cites).
_KEYCODES = {
    "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4,
    "I": 34, "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35,
    "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7,
    "Y": 16, "Z": 6,
}


def key_code(ch: str) -> int:
    return _KEYCODES[ch.upper()]


def case_saveas(agent: Agent, h: Harness, n: int) -> dict:
    """Does the APPLICATION agree with what we wrote?

    Every other case here proves the object holds our string. That is not the
    same claim: an application that keeps its own shadow copy of a field would
    read its copy and ignore ours, and the object-level oracles could not tell
    the difference. This one asks the application to ACT on the string.

    SimpleText's Save As is a Dialog Manager dialog (windowKind 2) whose
    filename is editText item 10. Write a name into it, press Return, and the
    oracle is a FILE ON DISK with that name, read back through the anchor —
    a different machine's view of a different subsystem, and the strongest
    oracle this project has.
    """
    print(f"\n== case saveas — does the application act on it? N={n} ==")
    if not launch_simpletext(agent, h):
        return {"case": "saveas", "error": "SimpleText never came to the front"}
    trials = []
    for i in range(n):
        close_dialogs(agent)
        agent.call("key", {"code": 45, "char": 110, "mods": CMD})     # cmd-N
        time.sleep(2.5)
        for ch in "HELLO":
            agent.call("key", {"code": key_code(ch), "char": ord(ch),
                               "mods": 0})
        time.sleep(1.0)
        agent.call("key", {"code": 1, "char": 115, "mods": CMD})      # cmd-S
        time.sleep(4)
        w = None
        for d in dialogs(agent):
            w = d
            break
        if w is None:
            trials.append({"valid": False, "why": "no Save As dialog"})
            continue
        edit = find_edit_item(agent, w)
        if edit is None:
            trials.append({"valid": False, "why": "Save As has no editText"})
            continue
        name = "PORTAL" + chr(65 + i % 26) + chr(65 + (i // 26) % 26)
        try:
            agent.call("textset", {"windowZ": w["z"], "window": w["title"],
                                   "kind": "ditem", "item": edit["item"],
                                   "text": name})
        except GuestError as e:
            trials.append({"valid": False, "why": str(e)})
            continue
        time.sleep(1.0)
        agent.call("key", {"code": 36, "char": 13, "mods": 0})        # Return
        time.sleep(5)
        titles = [x.get("title") for x in windows(agent)]
        on_disk = False
        where = None
        for folder in ("Macintosh HD:Desktop Folder:", "Macintosh HD:",
                       "Macintosh HD:Documents:"):
            try:
                r = h.request("list", {"path": folder})
            except Exception:
                continue
            entries = r.get("entries", r.get("items", []))
            if any(e.get("name") == name for e in entries):
                on_disk, where = True, folder
                break
        trials.append({"valid": True, "name": name, "titles": titles,
                       "retitled": name in titles, "onDisk": on_disk,
                       "where": where})
        print(f"  {i + 1:2}/{n}  wrote {name!r}  window retitled="
              f"{name in titles}  on disk={on_disk} {where or ''}")
    scored = [t for t in trials if t.get("valid")]
    disk = sum(1 for t in scored if t["onDisk"])
    retitled = sum(1 for t in scored if t["retitled"])
    print(f"    the app retitled its window to it: {retitled}/{len(scored)}")
    print(f"    a FILE by that name exists:        {disk}/{len(scored)}")
    return {"case": "saveas", "n": len(scored),
            "dropped": len(trials) - len(scored),
            "retitled": retitled, "onDisk": disk, "trials": trials}


def summarize(name: str, trials: list) -> dict:
    scored = [t for t in trials if t.get("valid")]
    dropped = len(trials) - len(scored)
    n = len(scored)
    reads = sum(1 for t in scored if t["read"].get("correct"))
    writes = sum(1 for t in scored if t["write"].get("actuated"))
    r_out = sum(1 for t in scored if t["read"].get("agrees_outside"))
    w_out = sum(1 for t in scored if t["write"].get("agrees_outside"))
    r_reply = sum(1 for t in scored if t["read"].get("replied"))
    w_reply = sum(1 for t in scored if t["write"].get("replied"))
    print(f"    read  reply {r_reply}/{n}   correct {reads}/{n}   "
          f"outside agrees {r_out}/{n}")
    print(f"    write reply {w_reply}/{n}   actuated {writes}/{n}   "
          f"outside agrees {w_out}/{n}")
    if dropped:
        print(f"    dropped (setup never produced the dialog): {dropped}")
    return {"case": name, "n": n, "dropped": dropped,
            "readReply": r_reply, "readCorrect": reads, "readOutside": r_out,
            "writeReply": w_reply, "writeActuated": writes,
            "writeOutside": w_out, "trials": trials}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent-port", type=int, required=True)
    ap.add_argument("--anchor-port", type=int, required=True)
    ap.add_argument("--case", action="append",
                    choices=("ditem", "dialogte", "handle", "saveas"))
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--settle", type=float, default=1.2)
    ap.add_argument("--json")
    args = ap.parse_args()

    agent = Agent(args.agent_port)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})
    hello = agent.call("hello")
    print(f"agent v{hello['version']} build={hello['build']} "
          f"portal={hello.get('portal')}")

    results = []
    for case in (args.case or ["ditem", "dialogte", "handle"]):
        if case == "saveas":
            results.append(case_saveas(agent, h, args.n))
        elif case == "handle":
            results.append(case_text(agent, h, "te", args.n, args.settle,
                                     use_handle=True))
        else:
            results.append(case_text(agent, h, case, args.n, args.settle))

    print("\n--- summary ---")
    for r in results:
        if "error" in r:
            print(f"{r['case']:9} FAILED SETUP: {r['error']}")
            continue
        if r["case"] == "saveas":
            print(f"{r['case']:9} retitled {r['retitled']}/{r['n']}  "
                  f"file on disk {r['onDisk']}/{r['n']}")
            continue
        print(f"{r['case']:9} read {r['readCorrect']}/{r['n']}  "
              f"write {r['writeActuated']}/{r['n']}  "
              f"outside {r['writeOutside']}/{r['n']}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"agent": hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
