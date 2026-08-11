#ifndef NOW_CONTROL_KIND_H
#define NOW_CONTROL_KIND_H

#include <Controls.h>
#include <Dialogs.h>
#include <MacWindows.h>

/* **What a control IS, and THAT it is, remembered at the moment it is
 * made.**
 *
 * The scene has to report a `role` for every control, and until now it
 * guessed one from the value range: `min != max` meant "scrollbar". A
 * push button carries min 0 max 1, so every button in this application
 * mirrored as a SCROLL BAR - drawn as a track, hit-tested as `pageDown`,
 * and a click on it would have sent a page-scroll part. Measured by
 * hovering the mirror, 2026-08-03.
 *
 * The Control Manager can answer this properly with GetControlKind, and
 * CarbonLib 1.6 does not export it - the link fails. But the answer was
 * in our hands the whole time: `procID` is the CDEF, and this
 * application passes one every time it makes a control. So the wrapper
 * records it, and the scene asks.
 *
 * As of 2026-08-06 the same table answers a SECOND question, and it is
 * the one that turned a 1.9-second hitch into nothing: **which controls
 * does this window have.** The scene used to discover that by sweeping a
 * `FindControl` grid over the content area - 3,724 points on the
 * Workshop - because `GetRootControl` fails in an application that never
 * calls `CreateRootControl`. `FindControl` costs ~240us a point on an
 * ACTIVE window, so the sweep cost ~900ms, and it was paid in full the
 * moment a person clicked into NOW. It also answered NOTHING at all on an
 * INACTIVE window, so a backgrounded NOW mirrored its own window as
 * EMPTY - an absence nobody had observed.
 *
 * Both fall out of the same fact: an application does not have to
 * discover its own controls, it MADE them. So every constructor and every
 * destructor goes through this file, `control_kind_source_test.py` fails
 * the build if one does not, and the scene reads the list instead of
 * hunting for it. Position, title, value, enabled and visible are still
 * read live from the Toolbox on every pass - only EXISTENCE is
 * remembered, which is the one thing the Toolbox will not tell us.
 *
 * The freshness rule that makes this safe: a ControlRef here is
 * dereferenced by the scene, so a disposal this table did not see would
 * be a read of freed memory. That is why disposal is wrapped as tightly
 * as creation, why `now_control_dispose_window` exists (DisposeWindow
 * takes a window's controls with it), and why the source gate covers all
 * five calls rather than just `NewControl`. */

enum {
    /* A control made by a constructor that takes no procID - today only
       CreateDataBrowserControl. Chosen negative because every real CDEF
       id is non-negative. */
    kNowControlProcDataBrowser = -1
};

ControlRef now_control_new(WindowRef window, const Rect *bounds,
                           ConstStr255Param title, Boolean visible,
                           short value, short min, short max,
                           short procID, long refCon);

/* Records a control this application made through some OTHER Toolbox
   constructor - `CreateDataBrowserControl` is the only one today. Same
   bookkeeping as `now_control_new`; pass the sentinel above as `procID`
   when there is no CDEF id to give. */
void now_control_adopt(WindowRef window, ControlRef control, short procID);

/* DisposeControl, plus the forget that keeps the table from handing the
   scene a freed ControlRef. */
void now_control_dispose(ControlRef control);

/* DisposeWindow / DisposeDialog, plus the same forget for every control
   the window owned - the Window Manager disposes them and never tells
   anyone. */
void now_control_dispose_window(WindowRef window);
void now_control_dispose_dialog(DialogRef dialog);

/* The IR role for a control this application made, or "" when it was not
   made here. Empty leaves the emitter's range guess in place, which is
   the honest ordering. */
const char *now_control_role(ControlRef control);

/* How many controls this application has ever made. Not an identity and
   not a count of live controls - a CHANGE in it means the interface this
   application presents may differ from the last time anyone looked. */
unsigned long now_control_generation(void);

/* The live controls this application made in `window`, in creation order.
   `now_control_indexed` returns NULL past the end. These are the scene's
   discovery: see scene_self.c. */
short now_control_count(WindowRef window);
ControlRef now_control_indexed(WindowRef window, short index);

/* Dispose every still-live control this window registered after `marker`, in
   reverse creation order. This is the Workshop constructor's rollback seam:
   module dispose handles non-control state, then this restores the window's
   exact pre-attempt control set. */
void now_control_rollback_window_since(WindowRef window,
                                       unsigned long marker);

/* False once the table has had to reuse a slot that was still live -
   after which it is a SUBSET of this application's controls rather than
   all of them, and a consumer that needs completeness has to go and look
   for itself. It has never happened; it is reported rather than trusted
   because a silently short list is exactly the defect this file exists
   to prevent. */
Boolean now_control_registry_complete(void);

#endif
