#ifndef NOW_CONTROL_KIND_H
#define NOW_CONTROL_KIND_H

#include <Controls.h>
#include <MacWindows.h>

/* **What a control IS, remembered at the moment it is made.**
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
 * Every control this application creates goes through `now_control_new`;
 * `control_kind_source_test.py` fails the build if a bare `NewControl`
 * appears outside this file, because a control made the old way is one
 * the mirror silently mis-draws. */
ControlRef now_control_new(WindowRef window, const Rect *bounds,
                           ConstStr255Param title, Boolean visible,
                           short value, short min, short max,
                           short procID, long refCon);

/* The IR role for a control this application made, or "" when it was not
   made here (or the table has since been reused). Empty leaves the
   emitter's range guess in place, which is the honest ordering. */
const char *now_control_role(ControlRef control);

#endif
