#ifndef NOW_CLOUD_VIEW_H
#define NOW_CLOUD_VIEW_H

#include <Carbon.h>

#include "cloud_layout.h"
#include "cloud_model.h"

/* The SHELL's Data Browser's two columns, drawn from CloudRow by its
   item_data callback for the list and contacts views. Drive and
   Photos do not use them: each owns a browser of its own (Drive's
   Files-page Name/Kind/Size/Modified set, Photos' Name/Size/Modified)
   for the same reason — one control cannot change its column set
   under CarbonLib 1.6 on the PB1400c, so a different set means a
   different control (cloud_drive_view.c's header says why in full). */
enum {
    kCloudColTitle = 'titl',
    kCloudColSubtitle = 'subt'
};

/* The per-service half of the iCloud page. cloud_module.c is the
   shell — popup, Refresh, status/placard, the conn_set_cloud_note
   hook, and service choice — and renders whichever service is active
   through one of these, the way workshop_module.h's WorkshopModuleOps
   lets the Workshop render whichever page is selected.

   Same NULL-op tolerance: every entry may be NULL, and the shell must
   check before calling. Today's views leave ops NULL rather than
   supply a no-op body — list's click/key/idle/reset are NULL because
   ask_save/HandleControlKey/nothing/nothing is already what the shell
   does by default. Drive supplies create/layout/draw for what it owns
   (its four-column browser and the breadcrumb row) but leaves show
   NULL: which browser is on stage is MODE chrome, and the shell owns
   the mode. Drive has no card pane to draw into — full body width for
   the list, per-row detail in its own columns, and a pull's progress
   on the status placard (cloud_drive_view.c's set_status host hook)
   rather than a pane that does not exist. A fourth view is free to use
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

    /* The list control has keyboard focus and a key came in; `selected`
       is the shell's current row index (-1 = none), since the shell
       owns selection across both views. Return true if consumed (the
       shell then skips its own HandleControlKey); NULL means "never
       consumed", i.e. always fall through to the generic handling. */
    Boolean (*key)(const EventRecord *event, int selected);

    /* Every event-loop pass while the page is visible — must be
       nearly free (docs/guest-ui-start-here.md). NULL if the view has
       nothing to watch between wire answers. Takes `r` so a view that
       needs to invalidate its own rectangle (a running pull's byte
       count, say) can, without the shell handing out its WindowRef
       separately. */
    void (*idle)(const CloudLayout *r);

    /* This service was just chosen (or Refresh was pressed while it
       was already current): drop whatever the last service showed and
       ask the wire for this one's. NULL means the shell's own
       ask_rows(1) is enough (today's list view; drive's browsing has
       no shell-level equivalent, so it always supplies this). */
    void (*reset_for_service)(const CloudService *service);

    /* The live search's per-view half: does row `index` (0-based —
       DataBrowserItemID is index+1, the convention every row storage
       here already uses) match `needle`, already lowercased
       (cloud_filter_lower)? `store` is the shell's shared listing —
       list and contacts read its rows and title+subtitle through it
       (cloud_filter_matches_either); Drive ignores it and reads its
       own row storage instead, the same split cloud_drive_view_row_text
       already draws for item_data. The shell (cloud_module.c) owns the
       Data Browser and calls this on every keystroke and on every
       arriving page, never mutating the store — filtering is a VIEW of
       the fetched rows. NULL means "matches everything": a view with
       nothing filterable never withholds a row the shell would
       otherwise show. */
    Boolean (*row_matches)(int index, const CloudStore *store,
                           const char *needle);

    /* Selection changed: `selected` is the new row index (-1 = none).
       The shell calls this on every real selection change AND with -1
       on every service change, after its own ask_card bookkeeping, so
       a view that keeps per-selection state (the photos preview: one
       image in memory, evicted on every change) has exactly one seam
       to keep it at. NULL for the views whose card is all the state
       there is. */
    void (*select)(const CloudLayout *r, const CloudStore *store,
                   int selected);

    /* A control the shell does not own was clicked (FindControl has
       already succeeded on `control`; nothing has tracked it yet).
       The view tracks it with whatever action proc ITS control needs
       — a popup CDEF wants (ControlActionUPP)-1L, a button wants
       now_pump_action() — and returns true when the control was this
       view's. NULL for views that own no controls of their own
       (today: everything but photos, whose Size popup and destination
       chooser live here). */
    Boolean (*control_click)(ControlRef control,
                             const EventRecord *event, Point local);

    /* The size token a Save/cloud.get should carry — the contract's
       "original"/"fit1024"/"fit640", or NULL to omit the field and
       take the host's configured default. NULL op means NULL token:
       a view with no size choice always asks for the default. */
    const char *(*save_size)(void);
} CloudViewOps;

#endif /* NOW_CLOUD_VIEW_H */
