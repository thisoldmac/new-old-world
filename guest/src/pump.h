#ifndef NOW_PUMP_H
#define NOW_PUMP_H

#include <Carbon.h>
#include <Navigation.h>

/* Keeping the wire alive inside nested Toolbox loops.
   ------------------------------------------------------------------
   The connection is serviced from one place — conn_service(), called
   each pass of the main event loop. Every Toolbox call that runs its
   own event loop (ModalDialog, Navigation Services, the mouse-tracking
   calls) suspends that loop, and with it the whole wire: no pings
   answered, no requests served, no transfers pumped.

   Each of those loops offers an idle hook. These are the shared ones,
   so the servicing rule lives in one place instead of being
   re-derived — the drift between copies is what let a dialog freeze
   the wire in the first place.

   RULE: any new nested loop must pump. A bare ModalDialog(NULL, ...)
   is a defect.

   RULE: pumped code must never open a dialog. A modal opened from a
   network callback nests inside the modal we are already in, and the
   guest becomes unrecoverable. Wire code sets status strings; keep it
   that way. */

/* For ModalDialog. Chains the standard filter, so Return and Escape
   still map to the default and cancel items. */
ModalFilterUPP now_pump_modal_filter(void);

/* For NavChooseFolder / NavGetFile (the eventProc parameter). */
NavEventUPP now_pump_nav_event(void);

/* For TrackControl. NOTE: popup CDEFs need (ControlActionUPP)-1L —
   their own action — and must not be given this one. */
ControlActionUPP now_pump_action(void);

/* --- what cannot be pumped ----------------------------------------------
   Three Toolbox loops take no callback at all, so the wire genuinely
   stops for their duration. They are listed rather than fixed because
   the honest answer is "this stalls", and the peer is built to survive
   it: the host's idle timeout is 75 s and every one of these is a
   human holding the mouse for a second or two.

     MenuSelect     a menu is down
     DragWindow     a window is being dragged
     GrowWindow     a window is being resized

   If one of these ever needs to be long-running, it has to be replaced
   with a tracking loop of our own, not given a callback it does not
   have. Anything NEW that stalls belongs in this list or gets a pump. */

/* Disposes the UPPs. Call once at quit. */
void now_pump_shutdown(void);

#endif /* NOW_PUMP_H */
