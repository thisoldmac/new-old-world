#!/usr/bin/env python3
"""The dropped-file seam's four runtime-invisible promises.

Everything about a drop is Toolbox: a Drag Manager callback, an Apple
Event handler, a Finder that reads a resource fork. None of it can be
exercised by a host cc, and every one of the defects below is silent on
the machine — a send started from inside a drag's tracking loop looks
like a hang, an FREF without a handler looks like a Finder that ignores
you, a handler left on a disposed window is a crash in someone else's
drag. So the source is what gets checked.
"""

from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
drop = (GUEST / "src/workshop/workshop_drop.c").read_text()
window = (GUEST / "src/workshop/workshop_window.c").read_text()
main = (GUEST / "src/main.c").read_text()
app_r = (GUEST / "resources/app.r").read_text()


def body_of(source: str, signature: str) -> str:
    """The text of one function, by brace depth from its opening brace."""
    start = source.index(signature)
    open_brace = source.index("{", start)
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace : i + 1]
    raise AssertionError("unbalanced braces after " + signature)


# 1. NOTHING SENDS FROM INSIDE A HANDLER.
# A Drag Manager receive handler runs inside the drag's own tracking loop
# and an Apple Event handler inside AEProcessAppleEvent. Starting a
# transfer there nests the wire underneath the loop that has to pump it —
# the same class of mistake pump.h bans for modal dialogs.
assert drop.count("now_wire_send_file(") == 1, (
    "one send call, in the drain; a second one is a second transfer path"
)
for handler in ("receive_drop(WindowRef window", "now_drop_open_documents("):
    assert "now_wire_send_file(" not in body_of(drop, handler), (
        handler + " must queue and return, never send"
    )
assert "now_wire_send_file(" in body_of(drop, "void now_drop_idle(void)"), (
    "the drain is where a queued file is actually sent"
)

# 2. A UPP IS NOT A CAST ON THIS RUNTIME.
# The Apple Event Manager tolerates a bare pointer, which is how the
# belief survives; the Drag Manager will not. Every descriptor made is
# also disposed — the quit handler's UPP was leaked for months on exactly
# this shape of omission.
for maker in ("NewDragTrackingHandlerUPP(", "NewDragReceiveHandlerUPP("):
    assert maker in drop, maker + " must build a real routine descriptor"
for caster in ("(DragTrackingHandlerUPP)track_drag",
               "(DragReceiveHandlerUPP)receive_drop"):
    assert caster not in drop, "a cast to a UPP type is a Type 3 here"
for disposer in ("DisposeDragTrackingHandlerUPP(",
                 "DisposeDragReceiveHandlerUPP("):
    assert disposer in drop, disposer + " must release what was made"

# 3. THE CAPABILITY IS GATED, AND THE WINDOW OUTLIVES ITS HANDLERS.
# Drag.h annotates every call used as CarbonLib 1.0+, below this app's
# 1.6 floor — and GetControlKind is annotated too and does not link
# (control_kind.h). Absence is a supported state, so Gestalt is asked
# before anything is installed.
install = body_of(drop, "Boolean now_drop_install(WindowRef window)")
assert "now_drop_available()" in install, (
    "install must ask the Drag Manager gate at all"
)
assert install.index("now_drop_available()") < install.index(
    "InstallTrackingHandler("
), "install must not run before the Drag Manager gate answers"
assert "gestaltDragMgrPresent" in drop, "the gate is the documented selector"
close = body_of(window, "void workshop_close(Boolean quitting)")
assert "now_drop_remove()" in close, (
    "closing the Workshop must take its drag handlers off with it"
)
assert close.index("now_drop_remove()") < close.index(
    "now_control_dispose_window(g_window)"
), "RemoveTrackingHandler takes the WindowRef; remove before the window goes"

# 4. THE FINDER'S HALF AND THE APPLICATION'S HALF SHIP TOGETHER.
# A document FREF is what makes NOW's icon a drop target. Without the
# handler it is an icon that accepts a drop and does nothing with it,
# which is the more expensive of the two halves to diagnose.
assert "'****', 1, \"\"" in app_r, "the any-document FREF is the drop target"
assert "'FREF', { 0, 128, 1, 129 }" in app_r, "the BNDL must list it"
assert "AEInstallEventHandler(kCoreEventClass, kAEOpenDocuments," in main, (
    "an FREF advertising documents needs a handler that answers for them"
)
assert "AERemoveEventHandler(kCoreEventClass, kAEOpenDocuments," in main, (
    "installed conditionally, removed and disposed the same way"
)
assert "now_drop_idle();" in main, (
    "the queue drains from the application's own loop or never at all"
)

print("drop seam: handlers queue only, UPPs are real, gate and Finder agree")
