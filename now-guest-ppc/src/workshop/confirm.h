#ifndef NOW_CONFIRM_H
#define NOW_CONFIRM_H

#include <Carbon.h>

/* Asking the person a yes/no question they can act on.
   ------------------------------------------------------------------
   A MOVABLE MODAL window, not an alert. Alerts are for reporting that
   something went wrong; this is a decision, and the window has to be
   draggable so the thing being decided about can be looked at. Mac OS
   also reads modal ALERTS aloud, which turns every routine confirm
   into a spoken interruption.

   The wire is pumped for the whole time it is up, so a question left
   on screen never costs the connection.

   RULE (pump.h): this must never be called from wire code. A modal
   opened from a network callback nests inside whatever loop is already
   running. Wire code raises a flag; the event loop asks the question. */

/* True if the action button was pressed, false for Cancel. `action` is
   the verb ("Replace"), which is also the default button. */
Boolean now_confirm(const char *heading, const char *detail,
                    const char *action);

#endif /* NOW_CONFIRM_H */
