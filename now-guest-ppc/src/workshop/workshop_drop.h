#ifndef NOW_WORKSHOP_DROP_H
#define NOW_WORKSHOP_DROP_H

#include <Carbon.h>

/* **Files arriving from outside this application.**
 *
 * Two doors, one room. A person can drag files from the Finder onto the
 * Workshop window (Drag Manager), or onto NOW's icon in the Finder
 * (kAEOpenDocuments). Both mean the same thing — "send these to the other
 * Mac" — so both land in the queue below and leave through
 * `now_wire_send_file`, which is the same call the Files page's
 * "Send File..." button and the console's send verb already make. There
 * is no second transfer path here and there must never be one.
 *
 * **Nothing is sent from inside a handler.** A Drag Manager receive
 * handler runs inside the drag's own tracking loop and an Apple Event
 * handler inside `AEProcessAppleEvent`; starting a transfer there is the
 * same class of mistake as opening a modal from a wire callback (pump.h).
 * So each handler does one cheap thing — copy the FSSpec into this queue
 * — and `now_drop_idle`, called from the application's own event loop,
 * is the only code that sends. That is the same shape as
 * `dispatch_pending_menu_choice` and `ask_about_replacing` in main.c, and
 * for the same reason.
 *
 * **One at a time, because the wire is.** `now_wire_send_file` carries
 * one offer; the Files page greys its Send button on exactly that fact.
 * The queue therefore releases its head only when the wire reports
 * `kSendNothing`, which is what "multiple files queue sequentially"
 * means here.
 *
 * Capability: the Drag Manager is gated at runtime through
 * `gestaltDragMgrAttr` / `gestaltDragMgrPresent` before a handler is
 * installed. Every entry point used is annotated "CarbonLib 1.0 and
 * later" in Drag.h, below this application's 1.6 floor — but a
 * declaration is not an export (GetControlKind cost this project a link
 * failure; control_kind.h carries that history), so absence is a
 * supported state: no handlers, no hilite, and the Files page's own
 * Send button remains the way in. */

/* True when the Drag Manager answered Gestalt. Asked once, at install. */
Boolean now_drop_available(void);

/* Installs the tracking and receive handlers on the Workshop window.
   Returns false when the Drag Manager is absent or a UPP could not be
   made; the caller carries on without drop, it is not an error. */
Boolean now_drop_install(WindowRef window);
void now_drop_remove(void);

/* kAEOpenDocuments — the Finder dropping files on NOW's icon, or opening
   a document with it. Queues every FSSpec in the direct object. */
OSErr now_drop_open_documents(const AppleEvent *event, AppleEvent *reply);

/* Releases the head of the queue when the wire is free. Called from the
   application's event loop, whether or not the Workshop is open: a
   Finder icon drop arrives without any window being involved. */
void now_drop_idle(void);

/* What the queue would tell a person right now, or "" when it has
   nothing to say. The Workshop's status placard shows this in front of
   the selected page's own line, because a drop is the most recent thing
   the person did. */
void now_drop_status(char *out, long cap);

/* Forgets the last outcome. The page switch calls it: a refusal about a
   file is news on the page it happened on and clutter on the next one. */
void now_drop_clear_note(void);

/* Disposes the UPPs. Once, at quit. */
void now_drop_shutdown(void);

#endif /* NOW_WORKSHOP_DROP_H */
