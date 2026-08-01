#include "cloud_drive_view.h"

#include <stdio.h>
#include <string.h>

#include "wire.h"

/* Everything the shell used to keep as g_drive_*, moved here whole.
   Behaviour is unchanged from cloud_module.c before the split — this
   file just owns what it always effectively owned. The status line,
   the loading flag and the detail pane's invalidation stay shell state
   (host, below); everything else is local. */

static WindowRef g_owner;
static ControlRef g_browser;
static CloudDriveHost g_host;
static Boolean g_active;

static char g_drive_path[224];
static FileEntry g_drive_rows[kCloudMaxRows];
static int g_drive_count;
static char g_shown_pull[96];

static void host_status(const char *line)
{
    if (g_host.set_status != NULL) {
        g_host.set_status(line);
    }
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
        host_status(err);
        return;
    }
    host_loading(true);
    host_status("Reading...");
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
        host_status(error);
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
        host_status("Empty");
    } else {
        char line[96];

        snprintf(line, sizeof line, "%.60s - %d item%s",
                 g_drive_path[0] != '\0' ? g_drive_path : "iCloud Drive",
                 g_drive_count, g_drive_count == 1 ? "" : "s");
        host_status(line);
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
        host_status(err);
    } else {
        char line[96];

        snprintf(line, sizeof line, "Fetching %.40s...", row->name);
        host_status(line);
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

static void draw_at(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    short y = (short)(r->detail_text.top + 12);

    (void)store;
    (void)service;
    if (selected >= 0 && selected < g_drive_count) {
        const FileEntry *entry = &g_drive_rows[selected];
        char line[96];

        draw_at(r->detail_text.left, y, entry->name);
        y = (short)(y + 16);
        now_files_describe(entry, line, sizeof line);
        draw_at(r->detail_text.left, y, line);
        y = (short)(y + 16);
        if (!entry->folder) {
            snprintf(line, sizeof line, "%ld K",
                     (entry->data_bytes + entry->rsrc_bytes + 1023)
                         / 1024);
            draw_at(r->detail_text.left, y, line);
            y = (short)(y + 16);
        }
        if (entry->modified != 0) {
            Str255 when;
            LongDateTime ldt = (LongDateTime)entry->modified;

            LongDateString(&ldt, shortDate, when, NULL);
            MoveTo(r->detail_text.left, y);
            DrawString(when);
            y = (short)(y + 16);
        }
        if (!entry->folder) {
            draw_at(r->detail_text.left, y,
                    "Double-click fetches it to this Mac.");
        }
    } else if (g_drive_count > 0) {
        draw_at(r->detail_text.left, y,
                "Select an item; double-click opens it.");
    }
    if (g_shown_pull[0] != '\0') {
        draw_at(r->detail_text.left, (short)(r->detail_text.bottom - 4),
                g_shown_pull);
    }
}

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

    if (now_wire_get_active(&received, &expected, NULL)) {
        snprintf(line, sizeof line, "Receiving - %ld of %ld K",
                 received / 1024,
                 expected > 0 ? (expected + 1023) / 1024 : 0);
    } else {
        line[0] = '\0';
    }
    if (strcmp(line, g_shown_pull) != 0) {
        strcpy(g_shown_pull, line);
        if (g_owner != NULL) {
            InvalWindowRect(g_owner, &r->detail);
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
    view_draw,
    view_click,
    view_key,
    view_idle,
    view_reset_for_service
};

const CloudViewOps *cloud_drive_view_ops(void)
{
    return &k_ops;
}
