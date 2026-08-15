#ifndef NOW_RECEIVE_PROGRESS_H
#define NOW_RECEIVE_PROGRESS_H

#include <Carbon.h>

/* The receive windoid: a small floating window that appears while a file
 * the HOST pushed is landing, and says how it went before it leaves.
 *
 * WHY IT IS NOT A PAGE. The receive plumbing (now_wire_receive_active /
 * now_wire_receive_outcome) has always been there and only the Cloud
 * page ever read it, filtered to receives answering its own cloud.get.
 * A plain push - someone dropping a file on this Mac from the other one
 * - was invisible everywhere, and a page could not fix that: a page is
 * only visible when the Workshop is open and on it, and the person a
 * transfer surprises is by definition looking at something else.
 *
 * WHY IT IS NOT A MODAL. docs/68k-file-receive.md measured 4 MB at
 * 11.6 s on the sibling guest; a real folder of files is minutes. A
 * modal for that would be the app unusable for the duration, and
 * confirm.c's pattern is for QUESTIONS answered in seconds.
 *
 * WHY IT IS NOT A SECOND WINDOW IN THE "one window" SENSE. The rule in
 * docs/adding-a-workshop-module.md is about human-facing FEATURES: a
 * feature gets a page, not a window. This is a transient status window
 * over a transfer nobody started from a page, the same category as
 * confirm.c's dialog, just non-modal.
 *
 * main.c routes its events here; every entry point is a no-op while
 * nothing is landing, so the routing costs a pointer comparison. */

/* Every event-loop pass. Shows the windoid when a non-cloud receive
 * starts, moves the bar when the byte count actually changed, replaces
 * it with the outcome when the receive ends, and disposes after the
 * outcome has been readable for a moment. Allocation-free and file-free
 * (guest-ui-start-here.md: "idle work must be free"). */
void now_receive_progress_idle(void);

/* True for the windoid's own WindowRef, so main.c can route to it. */
Boolean now_receive_progress_is(WindowRef window);

/* An update event for it. */
void now_receive_progress_draw(void);

/* A click in it, already known to be ours. `part` is FindWindow's.
 * Returns true when the click was consumed. */
Boolean now_receive_progress_click(const EventRecord *event, short part);

/* Teardown at quit: the Window Manager would take it anyway, but the
 * control table has to see the disposal (control_kind.h). */
void now_receive_progress_shutdown(void);

#endif /* NOW_RECEIVE_PROGRESS_H */
