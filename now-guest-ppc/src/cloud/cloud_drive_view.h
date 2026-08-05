#ifndef NOW_CLOUD_DRIVE_VIEW_H
#define NOW_CLOUD_DRIVE_VIEW_H

#include <Carbon.h>

#include "cloud_view.h"
#include "fileshare.h"

/* iCloud Drive: a real file browser over the share, browsed the same
   way the Files page browses it (files_browser_view.c) — this view
   calls the same now_wire_list_host and reclaims conn_set_listing the
   moment it asks ("a second request replaces the first" is already
   the wire's rule for the answer).

   This view owns its OWN Data Browser, with the Files page's exact
   column recipe (Name with the row's native icon, Kind, Size,
   Modified) — not the shell's shared two-column control. One control
   cannot safely wear both column sets: the only way off a column is
   RemoveDataBrowserTableViewColumn, which is NOT among the 22 symbols
   spikes/databrowser proved CarbonLib 1.6.0 exports on the PB1400c,
   and declared-but-unproven is exactly the gap that keeps Drive a
   flat list (docs/guest-ui-start-here.md). So the drive browser is a
   second, mostly-hidden control built from proven calls only, and the
   shell shows whichever control the mode owns.

   The shell still owns the live search and mutates whichever browser
   is active (cloud_drive_view_browser() hands this one over), still
   routes clicks/keys by rectangle and focus, and still runs the
   status placard. Selection, double-click and row text moved in here
   with the control: the affordance line goes out through
   CloudDriveHost.set_status, exactly as before. */

const CloudViewOps *cloud_drive_view_ops(void);

/* The shell operations this view needs and cannot do itself, because
   each one touches state (the search filter's g_in_view diff, g_status,
   g_loading) that stays shell-owned — shared across whatever view is
   active, not drive-specific. */
typedef struct CloudDriveHost {
    void (*clear_list)(void);
    void (*invalidate_detail)(void);
    void (*set_status)(const char *line);
    void (*set_loading)(Boolean loading);

    /* [first_index, first_index + count) just landed in this view's own
       row storage (g_drive_rows) — the shell decides which of them the
       live search currently admits and adds only those to whichever
       Data Browser is active (this view's, in drive mode), exactly as
       it does for its own rows in note_listing. Without this hook a
       page arriving while a search is typed would show rows the field
       says it is hiding. */
    void (*add_rows)(int first_index, int count);
} CloudDriveHost;

/* One-time wiring, called from cloud_create() (this view's create op
   builds its own browser first). `host`'s callbacks must outlive the
   page (they are the shell's own static functions, so they do). */
void cloud_drive_view_bind(const CloudDriveHost *host);

/* Window close / quit, called from cloud_dispose() before the shell
   nulls its own g_owner: disposes this view's browser BEFORE its UPPs
   (files_browser_view.c's dispose order and the finding
   carbon-upp-is-not-a-cast-on-cfm carry the reason), and releases the
   icon cache. */
void cloud_drive_view_dispose(void);

/* choose_service tells this view whether it is the one currently
   picked. Needed because conn_set_listing is reclaimed by whoever asks
   last (files_browser_view.c follows the same rule): a listing answer
   for a path this view already moved on from — or that arrived after
   the person picked a different service altogether — must be able to
   tell "not mine anymore" apart from "mine, but for an old path",
   which the path check alone cannot do once the person has left and
   come back to the same path. */
void cloud_drive_view_activate(Boolean active);

/* True once browsing has moved off the share root — the shell's Save
   button wears "Up" in drive mode and is enabled by exactly this. */
Boolean cloud_drive_view_at_root(void);

/* How many rows the current folder holds — the shell's live-search
   rebuild/refilter need this the way they need CloudStore's row_count
   for every other view, and this view keeps its own count instead of
   the shared store's. */
int cloud_drive_view_row_count(void);

/* This view's own Data Browser (NULL when creation failed): the
   control the shell shows, sizes, focuses and filter-mutates while
   drive mode is on. */
ControlRef cloud_drive_view_browser(void);

/* The toolbar history pair. can_* feed the buttons' dimming (the
   shell's idle caches the answer and calls HiliteControl only on a
   change); go_* retrace. All four are safe with no history. */
Boolean cloud_drive_view_can_back(void);
Boolean cloud_drive_view_can_forward(void);
void cloud_drive_view_go_back(void);
void cloud_drive_view_go_forward(void);

/* The wire's listing answer (conn_set_listing), reclaimed inside this
   file's own request function the instant it asks, exactly as
   files_browser_view.c's is. */
void cloud_drive_listing(const char *path, const FileEntry *entries,
                         int count, Boolean more, long cursor,
                         const char *root, const char *error);

#endif /* NOW_CLOUD_DRIVE_VIEW_H */
