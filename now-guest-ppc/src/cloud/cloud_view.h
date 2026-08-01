#ifndef NOW_CLOUD_VIEW_H
#define NOW_CLOUD_VIEW_H

#include <Carbon.h>

#include "cloud_layout.h"
#include "cloud_model.h"

/* The per-service half of the iCloud page. cloud_module.c is the
   shell — popup, Refresh, status/placard, the conn_set_cloud_note
   hook, and service choice — and renders whichever service is active
   through one of these, the way workshop_module.h's WorkshopModuleOps
   lets the Workshop render whichever page is selected.

   Same NULL-op tolerance: every entry may be NULL, and the shell must
   check before calling. Today's two views each leave several ops NULL
   rather than supply a no-op body — list's click/key/idle/reset are
   NULL because ask_save/HandleControlKey/nothing/nothing is already
   what the shell does by default; drive's create/show/layout are NULL
   because it owns no controls of its own. A fourth view is free to use
   as many or as few as it needs. */

typedef struct CloudViewOps {
    /* Called once, when the page is created (mirrors module create):
       build anything this view privately owns, invisible. Most views
       own nothing beyond the shell's popup/Refresh/Save/list and can
       leave this NULL. */
    OSErr (*create)(WindowRef owner);

    /* On every page show/hide. NULL if the view keeps no state that
       needs to react to visibility beyond what the shell already
       shows/hides for it. */
    void (*show)(Boolean visible);

    /* Grow/zoom. NULL if the view owns no rects beyond the ones
       cloud_layout_compute already places for the shell's controls. */
    void (*layout)(const CloudLayout *r);

    /* Draws the card pane (r->detail_text), given the shared model,
       the current service (may be NULL before the first report), and
       the selected row index (-1 = none). Called after the shell has
       already drawn the status line. */
    void (*draw)(const CloudLayout *r, const CloudStore *store,
                 const CloudService *service, int selected);

    /* The view's one action was invoked — the Save/Up button's
       TrackControl already succeeded; this is "do it", not "was my
       rect hit". NULL means the shell's own ask_save() is the action
       (today's list view). Return value is unused by the shell today
       but kept for symmetry with WorkshopModuleOps' click. */
    Boolean (*click)(const EventRecord *event, Point local);

    /* The list control has keyboard focus and a key came in. Return
       true if consumed (the shell then skips its own
       HandleControlKey); NULL means "never consumed", i.e. always
       fall through to the generic handling. */
    Boolean (*key)(const EventRecord *event);

    /* Every event-loop pass while the page is visible — must be
       nearly free (docs/guest-ui-start-here.md). NULL if the view has
       nothing to watch between wire answers. */
    void (*idle)(void);

    /* This service was just chosen (or Refresh was pressed while it
       was already current): drop whatever the last service showed and
       ask the wire for this one's. NULL means the shell's own
       ask_rows(1) is enough (today's list view; drive's browsing has
       no shell-level equivalent, so it always supplies this). */
    void (*reset_for_service)(const CloudService *service);
} CloudViewOps;

#endif /* NOW_CLOUD_VIEW_H */
