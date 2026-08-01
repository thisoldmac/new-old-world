#ifndef NOW_CLOUD_DRIVE_VIEW_H
#define NOW_CLOUD_DRIVE_VIEW_H

#include <Carbon.h>

#include "cloud_view.h"
#include "fileshare.h"

/* iCloud Drive: a real file browser over the share, browsed the same
   way the Files page browses it (files_browser_view.c) — this view
   calls the same now_wire_list_host and reclaims conn_set_listing the
   moment it asks ("a second request replaces the first" is already
   the wire's rule for the answer). All g_drive_* state that used to
   live in cloud_module.c lives here now; the shell only knows this
   view is active (the ops it gets back from cloud_drive_view_ops) and
   that the Data Browser it still owns needs row text and two
   notifications this file cannot reach through CloudViewOps. */

const CloudViewOps *cloud_drive_view_ops(void);

/* The shell operations this view needs and cannot do itself, because
   each one touches state (g_selected, g_status, g_loading, the detail
   pane's invalidation) that stays shell-owned — shared across whatever
   view is active, not drive-specific. */
typedef struct CloudDriveHost {
    void (*clear_list)(void);
    void (*invalidate_detail)(void);
    void (*set_status)(const char *line);
    void (*set_loading)(Boolean loading);
} CloudDriveHost;

/* One-time wiring, called from cloud_create() right after the shell's
   shared Data Browser exists (or failed to — pass NULL either way;
   every entry point below already guards it, same as the old inline
   code did). `host`'s callbacks must outlive the page (they are the
   shell's own static functions, so they do). */
void cloud_drive_view_bind(ControlRef browser, const CloudDriveHost *host);

/* Window close / quit, called from cloud_dispose() before the shell
   nulls its own g_owner: stops a listing reply that arrives after
   disposal from touching a control the Window Manager already took
   (files_browser_view.c's dispose guards the same way). */
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

/* Row text for the shell's shared Data Browser while this view is
   active. `item` is 1-based, matching AddDataBrowserItems' IDs.
   Returns false (property unsupported) exactly where the old inline
   switch in cloud_module.c's item_data did. */
Boolean cloud_drive_view_row_text(DataBrowserItemID item,
                                  DataBrowserPropertyID property,
                                  char *out, long cap);

/* Double-click on a row: open the folder, or fetch the file. Selection
   and deselection stay in the shell's item_notify — they only ever
   toggled g_selected and an invalidate, no drive-specific state. */
void cloud_drive_view_row_opened(int index);

/* The wire's listing answer (conn_set_listing), reclaimed inside this
   file's own request function the instant it asks, exactly as
   files_browser_view.c's is. */
void cloud_drive_listing(const char *path, const FileEntry *entries,
                         int count, Boolean more, long cursor,
                         const char *root, const char *error);

#endif /* NOW_CLOUD_DRIVE_VIEW_H */
