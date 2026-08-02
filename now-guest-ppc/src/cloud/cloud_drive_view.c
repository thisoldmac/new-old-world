#include "cloud_drive_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "db_hilite.h"
#include "cloud_nav.h"
#include "files_path_label.h"
#include "wire.h"

/* Everything the shell used to keep as g_drive_*, moved here whole —
   and, since the real-browser arc, the CONTROL too: this view owns a
   Data Browser of its own with the Files page's column recipe (Name
   with the row's native icon, Kind, Size, Modified — files_browser_
   view.c is the pattern, LongDateString and all), because the shell's
   shared two-column control cannot change wardrobe per mode without
   RemoveDataBrowserTableViewColumn, a symbol the PB1400c probe never
   proved exported (spikes/databrowser; the header's word is not
   evidence, per docs/guest-ui-start-here.md).

   The status line, the loading flag and the live search stay shell
   state (host, below); the shell mutates this browser through
   cloud_drive_view_browser() so a listing still lands ONCE per
   settled answer and keystrokes still diff per row. */

enum {
    kColName = 'name',
    kColKind = 'kind',
    kColSize = 'size',
    kColModified = 'modf',

    kIconCacheMax = 16                /* distinct type/creator pairs a
                                         folder listing plausibly holds;
                                         overflow wears the generic
                                         document icon */
};

static WindowRef g_owner;
static ControlRef g_browser;
static CloudDriveHost g_host;
static Boolean g_active;

static char g_drive_path[224];
static char g_drive_root[160];        /* the share's display name, from
                                         the listing's root field */
static FileEntry g_drive_rows[kCloudMaxRows];
static int g_drive_count;
static int g_sel = -1;                /* this view's own selection: the
                                         shell no longer sees this
                                         browser's notifications */
static char g_shown_pull[96];
static Rect g_path_row;               /* cached from layout(); where the
                                         breadcrumbs draw and what path
                                         changes invalidate */

static CloudNav g_nav;

/* The placard's last non-pull line (a folder's "N items", "Empty", or
   an error) - kept so a finished pull can hand the placard back to
   whatever it was saying before, the same priority rule
   files_browser_view.c's note/pull-note pair already keeps, just with
   one shared slot instead of two rendered ones. */
static char g_folder_status[96];

/* --- the icon cache ------------------------------------------------------

   GetIconRef per type/creator pair, once — a listing holds few
   distinct types, and Icon Services refcounts, so this is one acquire
   per pair for the page's life and one ReleaseIconRef each at dispose.
   Never per row: 128 acquires per listing is 128 releases someone
   forgets. GetIconRef and ReleaseIconRef are in the PB1400c's proven
   exports (spikes/databrowser); GetIconRefFromTypeInfo is absent and
   is not reached for. */

typedef struct {
    OSType file_type, creator;
    IconRef icon;                     /* may be NULL: a failed lookup is
                                         cached too, so it fails once */
} IconCacheEntry;

static IconCacheEntry g_icons[kIconCacheMax];
static int g_icon_count;
static IconRef g_folder_icon;         /* acquired lazily, once */
static IconRef g_doc_icon;            /* the fallback wardrobe */

static IconRef generic_doc_icon(void)
{
    if (g_doc_icon == NULL) {
        if (GetIconRef(kOnSystemDisk, kSystemIconsCreator,
                       kGenericDocumentIcon, &g_doc_icon) != noErr) {
            g_doc_icon = NULL;
        }
    }
    return g_doc_icon;
}

static IconRef icon_for_row(const FileEntry *row)
{
    int i;

    if (row->folder) {
        if (g_folder_icon == NULL) {
            if (GetIconRef(kOnSystemDisk, kSystemIconsCreator,
                           kGenericFolderIcon, &g_folder_icon) != noErr) {
                g_folder_icon = NULL;
            }
        }
        return g_folder_icon;
    }
    for (i = 0; i < g_icon_count; ++i) {
        if (g_icons[i].file_type == row->file_type
            && g_icons[i].creator == row->creator) {
            return g_icons[i].icon != NULL ? g_icons[i].icon
                                           : generic_doc_icon();
        }
    }
    if (g_icon_count == kIconCacheMax) {
        return generic_doc_icon();
    }
    g_icons[g_icon_count].file_type = row->file_type;
    g_icons[g_icon_count].creator = row->creator;
    if (GetIconRef(kOnSystemDisk, row->creator, row->file_type,
                   &g_icons[g_icon_count].icon) != noErr) {
        g_icons[g_icon_count].icon = NULL;
    }
    ++g_icon_count;
    return g_icons[g_icon_count - 1].icon != NULL
        ? g_icons[g_icon_count - 1].icon : generic_doc_icon();
}

static void drop_icons(void)
{
    int i;

    for (i = 0; i < g_icon_count; ++i) {
        if (g_icons[i].icon != NULL) {
            ReleaseIconRef(g_icons[i].icon);
            g_icons[i].icon = NULL;
        }
    }
    g_icon_count = 0;
    if (g_folder_icon != NULL) {
        ReleaseIconRef(g_folder_icon);
        g_folder_icon = NULL;
    }
    if (g_doc_icon != NULL) {
        ReleaseIconRef(g_doc_icon);
        g_doc_icon = NULL;
    }
}

/* --- the placard --------------------------------------------------------- */

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

/* --- breadcrumbs --------------------------------------------------------- */

static void invalidate_path_row(void)
{
    if (g_owner != NULL && g_active
        && g_path_row.right > g_path_row.left) {
        InvalWindowRect(g_owner, &g_path_row);
    }
}

/* --- asking -------------------------------------------------------------- */

static void drive_request(const char *path, long cursor)
{
    char err[96];

    if (cursor <= 1) {
        g_drive_count = 0;
        g_sel = -1;
        if (g_host.clear_list != NULL) {
            g_host.clear_list();
        }
        strncpy(g_drive_path, path != NULL ? path : "",
                sizeof g_drive_path - 1);
        g_drive_path[sizeof g_drive_path - 1] = '\0';
        invalidate_path_row();
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

/* A navigation a person meant (descend, Up, Back's own destination is
   NOT one — history moves differently there): record where we were,
   then go. */
static void drive_navigate(const char *next)
{
    cloud_nav_visit(&g_nav, g_drive_path);
    drive_request(next, 1);
}

void cloud_drive_listing(const char *path, const FileEntry *entries,
                         int count, Boolean more, long cursor,
                         const char *root, const char *error)
{
    int first = g_drive_count;
    int i;

    if (g_owner == NULL || !g_active) {
        return;
    }
    /* An answer to a question we have since replaced is not ours. */
    if (path == NULL || strcmp(path, g_drive_path) != 0) {
        return;
    }
    if (root != NULL && root[0] != '\0'
        && strcmp(root, g_drive_root) != 0) {
        strncpy(g_drive_root, root, sizeof g_drive_root - 1);
        g_drive_root[sizeof g_drive_root - 1] = '\0';
        invalidate_path_row();
    }
    host_loading(false);
    if (error != NULL) {
        folder_status(error);
        return;
    }
    for (i = 0; i < count && g_drive_count < kCloudMaxRows; ++i) {
        g_drive_rows[g_drive_count] = entries[i];
        ++g_drive_count;
    }
    (void)first;
    if (more && g_drive_count < kCloudMaxRows) {
        /* Mid-listing: rows accumulate here only. The Data Browser is
           mutated ONCE when the listing settles — a mutation per wire
           page repainted the whole full-width control per page,
           watched on the PowerBook 2026-08-02. */
        drive_request(g_drive_path, cursor);
        return;
    }
    /* The shell decides which rows the live search currently admits —
       the same filter its note_listing applies to its own rows, so a
       listing settling mid-search never shows a row the field says it
       is hiding. */
    if (g_drive_count > 0 && g_host.add_rows != NULL) {
        g_host.add_rows(0, g_drive_count);
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
        drive_navigate(next);
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

static void drive_go_up(void)
{
    char parent[224];
    char *colon;

    if (g_drive_path[0] == '\0') {
        return;
    }
    /* The parent, computed on a copy: g_drive_path is the history's
       "where we were" until drive_navigate has recorded it. */
    strcpy(parent, g_drive_path);
    colon = strrchr(parent, ':');
    if (colon == NULL) {
        parent[0] = '\0';
    } else {
        *colon = '\0';
    }
    drive_navigate(parent);
}

/* --- history ------------------------------------------------------------- */

Boolean cloud_drive_view_can_back(void)
{
    return (Boolean)(cloud_nav_can_back(&g_nav) != 0);
}

Boolean cloud_drive_view_can_forward(void)
{
    return (Boolean)(cloud_nav_can_forward(&g_nav) != 0);
}

void cloud_drive_view_go_back(void)
{
    char dest[224];

    if (!g_active
        || !cloud_nav_back(&g_nav, g_drive_path, dest, sizeof dest)) {
        return;
    }
    drive_request(dest, 1);
}

void cloud_drive_view_go_forward(void)
{
    char dest[224];

    if (!g_active
        || !cloud_nav_forward(&g_nav, g_drive_path, dest, sizeof dest)) {
        return;
    }
    drive_request(dest, 1);
}

/* --- the control --------------------------------------------------------- */

/* Selection changed (-1 = deselected). The placard carries the card
   pane's old affordance line — there is no card in drive mode. */
static void row_selected(int index)
{
    g_sel = index;
    if (index < 0 || index >= g_drive_count) {
        /* Deselected: back to the folder's own news. */
        g_sel = -1;
        host_status(g_folder_status);
        return;
    }
    if (g_drive_rows[index].folder) {
        host_status("Double-click opens it.");
    } else {
        char line[96];

        snprintf(line, sizeof line,
                 "Double-click fetches \"%.40s\" to this Mac.",
                 g_drive_rows[index].name);
        host_status(line);
    }
}

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const FileEntry *row;
    CFStringRef text = NULL;
    char buf[64];

    (void)browser;
    if (changeValue || item < 1
        || item > (DataBrowserItemID)g_drive_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_drive_rows[item - 1];
    switch (property) {
    case kColName: {
        IconRef icon = icon_for_row(row);

        if (icon != NULL) {
            SetDataBrowserItemDataIcon(data, icon);
        }
        text = CFStringCreateWithCString(NULL, row->name,
                                         kCFStringEncodingMacRoman);
        break;
    }
    case kColKind:
        now_files_describe(row, buf, sizeof buf);
        text = CFStringCreateWithCString(NULL, buf,
                                         kCFStringEncodingMacRoman);
        break;
    case kColSize:
        if (row->folder) {
            strcpy(buf, "--");
        } else {
            long total = row->data_bytes + row->rsrc_bytes;

            if (total < 1024) {
                snprintf(buf, sizeof buf, "%ld bytes", total);
            } else if (total < 1024L * 1024L) {
                snprintf(buf, sizeof buf, "%ld K", total / 1024);
            } else {
                snprintf(buf, sizeof buf, "%ld.%ld MB",
                         total / (1024L * 1024L),
                         (total % (1024L * 1024L)) / (105L * 1024L));
            }
        }
        text = CFStringCreateWithCString(NULL, buf,
                                         kCFStringEncodingMacRoman);
        break;
    case kColModified:
        if (row->modified == 0) {
            text = CFStringCreateWithCString(NULL, "--",
                                             kCFStringEncodingMacRoman);
        } else {
            Str255 when;
            LongDateTime ldt = (LongDateTime)row->modified;

            /* LongDateString, not DateString: 1904-epoch seconds pass
               2^31 in 1972, so every modern date through the signed API
               clamps to 1/19/72 - watched happening on the PowerBook. */
            LongDateString(&ldt, shortDate, when, NULL);
            text = CFStringCreateWithPascalString(
                NULL, when, kCFStringEncodingMacRoman);
        }
        break;
    default:
        return errDataBrowserPropertyNotSupported;
    }
    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    /* Unlike the shell's, this handler needs no rebuild guard: a
       deselect fired by the search's own remove settles the placard
       back to folder news, which is also what the person's deselect
       means — and nothing here asks the wire. */
    if (message == kDataBrowserItemDoubleClicked) {
        drive_open_row((int)item - 1);
    } else if (message == kDataBrowserItemSelected) {
        row_selected((int)item - 1);
    } else if (message == kDataBrowserItemDeselected
               && g_sel == (int)item - 1) {
        row_selected(-1);
    }
}

/* Real UPPs, retained for the control's lifetime — a UPP is a routine
   descriptor on this CFM runtime, never a cast
   (carbon-upp-is-not-a-cast-on-cfm). */
static DataBrowserItemDataUPP g_data_upp;
static DataBrowserItemNotificationUPP g_notify_upp;

static void dispose_callbacks(void)
{
    if (g_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_data_upp);
        g_data_upp = NULL;
    }
    if (g_notify_upp != NULL) {
        DisposeDataBrowserItemNotificationUPP(g_notify_upp);
        g_notify_upp = NULL;
    }
}

static OSStatus add_column(DataBrowserPropertyID id, const char *title,
                           UInt16 width, Boolean isName,
                           DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType =
        isName ? kDataBrowserIconAndTextType : kDataBrowserTextType;
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn
        | (isName ? kDataBrowserListViewSelectionColumn : 0);
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.titleOffset = 0;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnFontStyle.flags = 0;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(g_browser, &col, at);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    if (err == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(g_browser, id, width);
    }
    return err;
}

void cloud_drive_view_bind(const CloudDriveHost *host)
{
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

int cloud_drive_view_row_count(void)
{
    return g_drive_count;
}

ControlRef cloud_drive_view_browser(void)
{
    return g_browser;
}

void cloud_drive_view_dispose(void)
{
    /* The Data Browser goes BEFORE its UPPs: disposal fires item
       notifications through them (files_browser_view.c and the finding
       carbon-upp-is-not-a-cast-on-cfm carry the full story). */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    drop_icons();
    g_owner = NULL;
    g_active = false;
    g_sel = -1;
    memset(&g_host, 0, sizeof g_host);
}

/* --- ops ------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    DataBrowserCallbacks callbacks;
    Rect start = { 0, 0, 0, 0 };      /* layout() places it before it
                                         is ever shown */

    g_owner = owner;
    cloud_nav_reset(&g_nav);
    if (CreateDataBrowserControl(owner, &start, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;             /* the shell says so; no hard fail */
        return noErr;
    }
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    g_data_upp = NewDataBrowserItemDataUPP(item_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    if (g_data_upp == NULL || g_notify_upp == NULL) {
        dispose_callbacks();
        DisposeControl(g_browser);
        g_browser = NULL;
        return noErr;
    }
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
    SetDataBrowserCallbacks(g_browser, &callbacks);
    add_column(kColName, "Name", 200, true, 0);
    add_column(kColKind, "Kind", 110, false, 1);
    add_column(kColSize, "Size", 64, false, 2);
    add_column(kColModified, "Modified", 90, false, 3);
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
            now_browser_fill_hilite(g_browser);
    SetDataBrowserSortProperty(g_browser, kColName);
    HideControl(g_browser);
    return noErr;
}

static void view_layout(const CloudLayout *r)
{
    g_path_row = r->path_row;
    if (g_browser == NULL) {
        return;
    }
    MoveControl(g_browser, r->list.left, r->list.top);
    SizeControl(g_browser, (SInt16)(r->list.right - r->list.left),
                (SInt16)(r->list.bottom - r->list.top));
}

/* The breadcrumbs: share-root name plus colon path, the Files page's
   path row verbatim (files_module.c's draw, now_files_path_label's
   words). Truncated in the middle — the ends are the halves a person
   reads. */
static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    char line[224];
    Str255 text;

    (void)store;
    (void)service;
    (void)selected;
    if (r->path_row.right <= r->path_row.left) {
        return;
    }
    now_files_path_label(g_drive_root, g_drive_path, line, sizeof line);
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    CopyCStringToPascal(line, text);
    TruncString((short)(r->path_row.right - r->path_row.left - 4), text,
                truncMiddle);
    MoveTo((short)(r->path_row.left + 2),
           (short)(r->path_row.top + 12));
    DrawString(text);
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

    (void)selected;                   /* this view keeps its own: the
                                         shell no longer sees this
                                         browser's notifications */
    if (c != '\r' && c != 3) {
        return false;
    }
    if (g_sel >= 0) {
        drive_open_row(g_sel);
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
    /* A fresh pick starts a fresh trail: Back must not walk into a
       previous session's folders, whose listing this view no longer
       holds. */
    cloud_nav_reset(&g_nav);
    drive_request("", 1);
}

/* This view's own row storage, searched by name — the one free-text
   field its columns show (Kind/Size/Modified are computed from the
   entry, not text worth matching). */
static Boolean view_row_matches(int index, const CloudStore *store,
                                const char *needle)
{
    (void)store;
    if (index < 0 || index >= g_drive_count) {
        return false;
    }
    return cloud_filter_matches(g_drive_rows[index].name, needle);
}

static const CloudViewOps k_ops = {
    view_create,
    NULL,                              /* show: the shell owns both
                                          browsers' visibility */
    view_layout,
    view_draw,                         /* the breadcrumb row */
    view_click,
    view_key,
    view_idle,
    view_reset_for_service,
    view_row_matches
};

const CloudViewOps *cloud_drive_view_ops(void)
{
    return &k_ops;
}
