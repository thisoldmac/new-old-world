#include "cloud_drive_view.h"

#include <stdio.h>
#include <string.h>

#include "wire.h"

/* Everything the shell used to keep as g_drive_*, moved here whole.
   Behaviour is unchanged from cloud_module.c before the split — this
   file just owns what it always effectively owned. The status line,
   the loading flag and the detail pane's invalidation stay shell state
   (host, below); everything else is local.

   There is no card pane in drive mode (cloud_layout.c's drive variant
   makes r->detail the anti-rect) - the browser IS the page, full body
   width. So this view has nothing to draw() any more: view_draw is
   NULL below, and what used to go into the card - the selected row's
   kind/size/date, and the pull's byte count while a fetch runs - both
   move to the ONE line this page still owns, the status placard,
   through g_host.set_status. */

static WindowRef g_owner;
static ControlRef g_browser;
static CloudDriveHost g_host;
static Boolean g_active;

static char g_drive_path[224];
static FileEntry g_drive_rows[kCloudMaxRows];
static int g_drive_count;
static char g_shown_pull[96];

/* The placard's last non-pull line (a folder's "N items", "Empty", or
   an error) - kept so a finished pull can hand the placard back to
   whatever it was saying before, the same priority rule
   files_browser_view.c's note/pull-note pair already keeps, just with
   one shared slot instead of two rendered ones. */
static char g_folder_status[96];

static void host_status(const char *line)
{
    if (g_host.set_status != NULL) {
        g_host.set_status(line);
    }
}

/* Folder/error news, as opposed to a pull's transient byte count:
   remembered so view_idle can hand the placard back when the pull
   that was overlaying it ends. */
static void folder_status(const char *line)
{
    snprintf(g_folder_status, sizeof g_folder_status, "%.90s", line);
    host_status(line);
}

static void host_loading(Boolean loading)
{
    if (g_host.set_loading != NULL) {
        g_host.set_loading(loading);
    }
}

static void drive_request(const char *path, long cursor)
{
    char err[96];

    if (cursor <= 1) {
        g_drive_count = 0;
        if (g_host.clear_list != NULL) {
            g_host.clear_list();
        }
        strncpy(g_drive_path, path != NULL ? path : "",
                sizeof g_drive_path - 1);
        g_drive_path[sizeof g_drive_path - 1] = '\0';
        if (g_host.invalidate_detail != NULL) {
            g_host.invalidate_detail();
        }
    }
    /* The listing hook follows the asker; the Files page takes it back
       the same way the moment it asks (files_browser_view.c). */
    conn_set_listing(cloud_drive_listing);
    if (now_wire_list_host(g_drive_path, cursor, err, sizeof err) < 0) {
        host_loading(false);
        folder_status(err);
        return;
    }
    host_loading(true);
    folder_status("Reading...");
}

void cloud_drive_listing(const char *path, const FileEntry *entries,
                         int count, Boolean more, long cursor,
                         const char *root, const char *error)
{
    DataBrowserItemID ids[16];
    int i;

    (void)root;
    if (g_owner == NULL || !g_active) {
        return;
    }
    /* An answer to a question we have since replaced is not ours. */
    if (path == NULL || strcmp(path, g_drive_path) != 0) {
        return;
    }
    host_loading(false);
    if (error != NULL) {
        folder_status(error);
        return;
    }
    for (i = 0; i < count && g_drive_count < kCloudMaxRows; ++i) {
        g_drive_rows[g_drive_count] = entries[i];
        ids[i] = (DataBrowserItemID)(++g_drive_count);
    }
    if (i > 0 && g_browser != NULL) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, (UInt32)i,
                            ids, kDataBrowserItemNoProperty);
    }
    if (more && g_drive_count < kCloudMaxRows) {
        drive_request(g_drive_path, cursor);
        return;
    }
    if (g_drive_count == 0) {
        folder_status("Empty");
    } else {
        char line[96];

        snprintf(line, sizeof line, "%.60s - %d item%s",
                 g_drive_path[0] != '\0' ? g_drive_path : "iCloud Drive",
                 g_drive_count, g_drive_count == 1 ? "" : "s");
        folder_status(line);
    }
}

static void drive_open_row(int index)
{
    const FileEntry *row;
    char next[224];
    char err[96];

    if (index < 0 || index >= g_drive_count) {
        return;
    }
    row = &g_drive_rows[index];
    if (g_drive_path[0] == '\0') {
        snprintf(next, sizeof next, "%.31s", row->name);
    } else {
        snprintf(next, sizeof next, "%.180s:%.31s", g_drive_path,
                 row->name);
    }
    if (row->folder) {
        drive_request(next, 1);
        return;
    }
    if (now_wire_get_host(next, row->name, err, sizeof err) < 0) {
        folder_status(err);
    } else {
        char line[96];

        snprintf(line, sizeof line, "Fetching %.40s...", row->name);
        folder_status(line);
    }
}

void cloud_drive_view_row_opened(int index)
{
    drive_open_row(index);
}

static void drive_go_up(void)
{
    char *colon;

    if (g_drive_path[0] == '\0') {
        return;
    }
    colon = strrchr(g_drive_path, ':');
    if (colon == NULL) {
        drive_request("", 1);
    } else {
        *colon = '\0';
        drive_request(g_drive_path, 1);
    }
}

void cloud_drive_view_bind(ControlRef browser, const CloudDriveHost *host)
{
    g_browser = browser;
    if (host != NULL) {
        g_host = *host;
    } else {
        memset(&g_host, 0, sizeof g_host);
    }
}

void cloud_drive_view_activate(Boolean active)
{
    g_active = active;
}

Boolean cloud_drive_view_at_root(void)
{
    return g_drive_path[0] == '\0';
}

void cloud_drive_view_dispose(void)
{
    g_owner = NULL;
    g_browser = NULL;
    g_active = false;
    memset(&g_host, 0, sizeof g_host);
}

Boolean cloud_drive_view_row_text(DataBrowserItemID item,
                                  DataBrowserPropertyID property,
                                  char *out, long cap)
{
    const FileEntry *entry;

    if (item < 1 || item > (DataBrowserItemID)g_drive_count) {
        return false;
    }
    entry = &g_drive_rows[item - 1];
    switch (property) {
    case kCloudColTitle:
        snprintf(out, (size_t)cap, "%.31s", entry->name);
        return true;
    case kCloudColSubtitle:
        now_files_describe(entry, out, cap);
        return true;
    default:
        return false;
    }
}

/* --- ops ------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    g_owner = owner;
    return noErr;
}

/* No draw() any more: cloud_layout.c's drive variant makes r->detail
   the anti-rect (no card pane, full-width list instead), so there is
   nowhere left for this to draw into. What it used to say - the
   selected row's kind/size/date, "double-click fetches it" - was a
   convenience the flat file list's own Detail column already restates
   per row (files_browser_view.c's item_data pattern, shared here via
   now_files_describe); it is not lost, just no longer duplicated in a
   pane that does not exist. */

static Boolean view_click(const EventRecord *event, Point local)
{
    (void)event;
    (void)local;
    drive_go_up();
    return true;
}

static Boolean view_key(const EventRecord *event, int selected)
{
    char c = (char)(event->message & charCodeMask);

    if (c != '\r' && c != 3) {
        return false;
    }
    if (selected >= 0) {
        drive_open_row(selected);
    }
    return true;
}

static void view_idle(const CloudLayout *r)
{
    long received = 0, expected = 0;
    char line[96];

    (void)r;                          /* nothing left to invalidate here */
    if (now_wire_get_active(&received, &expected, NULL)) {
        snprintf(line, sizeof line, "Receiving - %ld of %ld K",
                 received / 1024,
                 expected > 0 ? (expected + 1023) / 1024 : 0);
    } else {
        line[0] = '\0';
    }
    if (strcmp(line, g_shown_pull) != 0) {
        Boolean was_active = g_shown_pull[0] != '\0';

        strcpy(g_shown_pull, line);
        if (line[0] != '\0') {
            /* A pull's byte count overlays the placard - it outranks
               whatever the last folder news was, the same priority
               files_browser_view.c's note/pull-note pair keeps. */
            host_status(line);
        } else if (was_active) {
            /* The pull ended; hand the placard back to the folder's
               own news rather than leaving the last byte count
               standing forever. */
            host_status(g_folder_status);
        }
    }
}

static void view_reset_for_service(const CloudService *service)
{
    (void)service;
    drive_request("", 1);
}

static const CloudViewOps k_ops = {
    view_create,
    NULL,                              /* show */
    NULL,                              /* layout */
    NULL,                              /* draw: no card pane in drive mode */
    view_click,
    view_key,
    view_idle,
    view_reset_for_service
};

const CloudViewOps *cloud_drive_view_ops(void)
{
    return &k_ops;
}
