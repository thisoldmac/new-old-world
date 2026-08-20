#!/usr/bin/env python3
"""The Chat page's rules that live in Carbon translation units.

Everything here is behaviour no host-native test can reach -- it is
about the ORDER of Toolbox calls, or about which of two functions a
flag is cleared in -- so it is pinned lexically, the way
``continuity_nested_pump_source_test.py`` pins the nested-pump rule.
Each block names the failure a person would see if it went away.

Reviewed 2026-08-19, all seven from one code review of the page:

  1. The transcript's selection drag is a tracking loop of OURS, so
     pump.h's rule binds it.  Not pumping stopped the wire for as long
     as a finger rested on the transcript -- the 15 s ask deadline
     never evaluated, no delta drained, no ping answered -- and, with a
     still mouse, spun.
  2. A want is consumed only by an ask that can be ISSUED.  Clearing
     the flag and then sending into a dropped link spends the want on
     nothing, and nothing re-arms it.
  3. The skills roster is per-connection by the contract's own words,
     so it is dropped and re-armed when the link drops.
  4. ``chat_dispose`` clears every control it forgets, the skills popup
     included, and the per-connection state that belonged to it.
  5. The project roster is REPLACED by its answer, not emptied at the
     ask: an emptied count under a menu still showing rows maps a click
     on a project onto the New Project verb.
  6. Picking a provider records a want; the model ask is issued from
     the one dispatcher like every other listing.
  7. A modal owns the current port for its whole life AND pumps the
     wire, so no popup of ours may draw while one is up, and the port
     is restored after the dialog is disposed.
"""

import re
from pathlib import Path


def uncommented(text: str) -> str:
    """Source with block comments blanked, newlines kept.

    A comment that explains a rule satisfies a substring search for the
    rule; this is the same trap the continuity pump guard fell into.
    """

    return re.sub(
        r"/\*.*?\*/",
        lambda m: re.sub(r"[^\n]", " ", m.group(0)),
        text,
        flags=re.S,
    )


SRC = Path(__file__).resolve().parents[1] / "src"
MODULE = uncommented((SRC / "chat" / "chat_module.c").read_text())
DIALOG = uncommented((SRC / "chat" / "chat_project_dialog.c").read_text())


def function_body(text: str, signature: str, where: str) -> str:
    try:
        start = text.index(signature)
    except ValueError:
        raise SystemExit(f"{where}: no function {signature!r}")
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise SystemExit(f"{where}: unterminated function {signature!r}")


def loop_body(text: str, header: str, where: str) -> str:
    """The body of the first ``while`` whose header matches."""

    try:
        start = text.index(header)
    except ValueError:
        raise SystemExit(f"{where}: no loop {header!r}")
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise SystemExit(f"{where}: unterminated loop {header!r}")


CLICK = function_body(MODULE, "static Boolean chat_click(", "chat_module.c")
IDLE = function_body(MODULE, "static void chat_idle(", "chat_module.c")
DISPOSE = function_body(MODULE, "static void chat_dispose(", "chat_module.c")
WHEN_FREE = function_body(MODULE, "static void ask_when_free(", "chat_module.c")
ASK_PROJECTS = function_body(MODULE, "static void ask_projects(",
                             "chat_module.c")

# --- 1. the selection drag pumps -----------------------------------------
DRAG = loop_body(CLICK, "while (StillDown())", "chat_click")
if "now_wire_pump()" not in DRAG:
    raise SystemExit(
        "chat_click: the transcript selection drag does not pump the wire. "
        "It is a tracking loop of OURS - unlike TEClick, which is the "
        "Toolbox's and has no hook to give - so pump.h's rule binds it: "
        "without it the connection is dead for as long as the mouse is "
        "down, and a still mouse makes this a spin loop."
    )

# The previous band must come OFF by hand before the new drag begins.
# An invalidation cannot repaint while the mouse is down, so a
# clear_selection alone left the old highlight on screen for the whole
# drag - two bands, one of them a lie.
before_clear = CLICK[: CLICK.index("clear_selection();")]
if "invert_transcript_rows" not in before_clear.rsplit("PtInRect(local, &g_r.transcript)", 1)[-1]:
    raise SystemExit(
        "chat_click: the old selection band is not un-inverted before the "
        "new drag. Invalidation cannot repaint while the mouse is down, so "
        "the previous highlight stays on screen for the whole drag."
    )

# --- 2. no want is spent on a dead link -----------------------------------
gate = "conn_phase() != kConnConnected"
if gate not in WHEN_FREE:
    raise SystemExit(
        "ask_when_free: no connection gate. Every want here is issued over "
        "the wire; clearing one while the link is down spends it on nothing."
    )
gate_at = WHEN_FREE.index(gate)
for match in re.finditer(r"g_want_\w+ = false;", WHEN_FREE):
    if match.start() < gate_at:
        raise SystemExit(
            "ask_when_free: %r is consumed before the connection gate. "
            "A want cleared into a dead link is a listing that never "
            "arrives and nothing left to re-arm it - the chat opened as "
            "the link dropped with an empty transcript forever."
            % match.group(0)
        )

# --- 3. the skills roster is per-connection -------------------------------
if "g_asked_skills" not in MODULE:
    raise SystemExit(
        "chat_module.c: no g_asked_skills. The skills ask needs the "
        "catalog's shape - armed when it goes out, cleared when the link "
        "drops - or a timed-out first ask leaves the popup dimmed forever."
    )
drop = IDLE[IDLE.index("conn_phase() != kConnConnected"):] if \
    "conn_phase() != kConnConnected" in IDLE else ""
if "g_asked_skills = false" not in drop or "g_skill_count = 0" not in drop:
    raise SystemExit(
        "chat_idle: the skills roster survives a disconnect. The contract "
        "says the guest never caches it across connections, so both the "
        "rows and the asked flag are dropped where g_asked_catalog is."
    )
if "g_want_skills = true" not in IDLE:
    raise SystemExit(
        "chat_idle: nothing re-arms the skills ask. chat_show alone means "
        "a timed-out or dropped roster stays missing until a person "
        "leaves the page and comes back."
    )

# --- 4. dispose forgets every control -------------------------------------
for control in ("g_provider_popup", "g_model_popup", "g_mode_popup",
                "g_project_popup", "g_skills_popup", "g_sidebar_toggle",
                "g_new_btn", "g_send_btn", "g_scroll"):
    if f"{control} = NULL;" not in DISPOSE:
        raise SystemExit(
            f"chat_dispose: {control} is left pointing at a control the "
            "window disposed. Every other one here is cleared; a stale "
            "ControlRef is drawn through on the next page show."
        )
for state in ("g_skill_count = 0;", "g_want_skills = false;",
              "g_asked_skills = false;"):
    if state not in DISPOSE:
        raise SystemExit(
            f"chat_dispose: {state!r} missing. The roster belonged to the "
            "popup that was just forgotten and to a connection that is "
            "gone; a recreated page must ask, not redraw what it kept."
        )

# --- 5. the project roster is replaced, never pre-emptied -----------------
if "g_project_count = 0" in ASK_PROJECTS:
    raise SystemExit(
        "ask_projects: the rows are emptied before the send is known to "
        "have succeeded. The ask is refused whenever another is pending, "
        "and a count of zero under a menu still showing rows maps a click "
        "on a project onto item g_project_count + 2 - the New Project "
        "verb. Set the restart flag after the send, like the chat roster."
    )
if "g_project_restart = true;" not in ASK_PROJECTS:
    raise SystemExit(
        "ask_projects: no restart flag, so a fresh listing would append "
        "to the rows it meant to replace."
    )
if "g_project_restart" not in MODULE.split("case kChatAnswerProjects:")[1]:
    raise SystemExit(
        "kChatAnswerProjects: nothing consumes g_project_restart, so the "
        "answer never replaces the rows."
    )

# --- 6. picking a provider records a want ---------------------------------
if "ask_models();" in CLICK:
    raise SystemExit(
        "chat_click: the models ask is sent straight from the provider "
        "popup. With chat.skills asked on every page show, picking a "
        "provider during any in-flight listing is refused and the model "
        "popup stays empty with nothing retrying it. Record a want."
    )
if "want_models();" not in CLICK:
    raise SystemExit("chat_click: picking a provider records no models want.")
if "ask_models();" not in WHEN_FREE:
    raise SystemExit(
        "ask_when_free: the models ask is not issued from the one "
        "dispatcher, so nothing re-tries it when the slot frees."
    )

# --- 7. a modal owns the port ---------------------------------------------
for name in ("rebuild_provider_popup", "rebuild_model_popup",
             "rebuild_skills_popup", "rebuild_project_popup"):
    body = function_body(MODULE, f"static void {name}(void)", "chat_module.c")
    head = body[: body.index("if (menu == NULL)")]
    if "if (g_modal_up)" not in head:
        raise SystemExit(
            f"{name}: runs while a modal owns the port. The project dialog "
            "pumps the wire, so a roster answer can land mid-dialog - and "
            "Draw1Control, SetControlValue and HiliteControl all take the "
            "CURRENT port, which is the dialog's. The rebuild is owed, not "
            "done: return, and let the click redraw on the way out."
        )
if "g_modal_up = true;" not in CLICK or "g_modal_up = false;" not in CLICK:
    raise SystemExit(
        "chat_click: now_chat_project_new is not fenced by g_modal_up, so "
        "nothing tells the rebuilds a dialog owns the port."
    )
fence = CLICK[CLICK.index("g_modal_up = true;"):]
if fence.index("now_chat_project_new") > fence.index("g_modal_up = false;"):
    raise SystemExit("chat_click: the fence does not enclose the dialog.")
after = CLICK[CLICK.index("g_modal_up = false;"):]
if "rebuild_project_popup();" not in after:
    raise SystemExit(
        "chat_click: nothing redraws the popups after the dialog. What "
        "arrived while it was up mutated the menus and drew nothing."
    )

dialog_body = function_body(DIALOG, "Boolean now_chat_project_new(",
                            "chat_project_dialog.c")
if "GetPort(&saved_port);" not in dialog_body:
    raise SystemExit(
        "now_chat_project_new: the caller's port is not saved."
    )
if dialog_body.index("GetPort(&saved_port);") > dialog_body.index("GetNewDialog"):
    raise SystemExit(
        "now_chat_project_new: the port is saved after the dialog exists, "
        "which saves the dialog's own port."
    )
dispose_at = dialog_body.index("now_control_dispose_dialog(dialog);")
if "SetPort(saved_port);" not in dialog_body[dispose_at:]:
    raise SystemExit(
        "now_chat_project_new: DisposeDialog leaves the current port "
        "pointing at a port that no longer exists, and the next thing to "
        "draw without setting one of its own draws through it."
    )

print("chat_page_wire_source_test: all passed")
