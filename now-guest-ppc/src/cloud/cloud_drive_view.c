#include "cloud_drive_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "db_hilite.h"
#include "cloud_nav.h"
#include "files_path_label.h"
#include "pump.h"
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
static Rect g_path_row;               /* cached from layout(); where the
                                         breadcrumbs draw and what path
                                         changes invalidate */

static CloudNav g_nav;

/* --- the pull destination and its progress --------------------------------
   Photos' own "Save into:" furniture (cloud_photos_view.c), one lane
   over: a row plus a Choose... button, built invisible at create and
   shown only while this view is on stage. Unset means the downloads
   folder — the pull path's existing default, byte-identical to every
   drive pull before this existed — because that is what a PULL already
   means here, unlike photos' cloud.get whose unset default is the
   share root. The label is recomputed only on create/show/choose,
   never idle (now_files_downloads_name/now_files_dir_path read
   preferences or the catalog).

   The moving bar and byte-count line are photos' own recipe too,
   reused verbatim: a native kControlProgressBarProc scaled 0..1000 by
   the shared, pure cloud_dl_bar_value/cloud_dl_bytes_line
   (cloud_model.c) — genuinely shared code, not a lookalike, because
   both views watch the SAME pull machinery (Drive pulls through
   now_wire_get_host exactly as the Files page does; Photos' own bar
   watches the separate cloud.get/file.offer lane through
   now_wire_receive_active, which is why its idle reads a different
   wire entry point even though the bar/line math underneath is
   identical). Shown only while a pull the guest itself asked for is
   landing; idle-cheap, mutated only on a shown-value change. */
static ControlRef g_dest_btn;
static Boolean g_dest_set;
static short g_dest_vref;
static long g_dest_dir;
static char g_dest_path[160];
static Rect g_dest_row;               /* cached from layout(); the
                                         label's own repaint target */
static ControlRef g_dl_bar;
static Boolean g_bar_shown;
static short g_bar_value = -1;
static char g_dl_line[48];
static Rect g_dl_text_rect;           /* cached from layout(); the byte
                                         line's own repaint target */

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

/* Folder/error/pull-outcome news — durable, one line, the whole
   placard. A pull's transient byte count no longer lands here (it
   moves with the pull's own moving bar); the placard is not overlaid
   and restored around a selection or a download the way it used to be
   — whatever this last said is what it still says. */
static void folder_status(const char *line)
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

/* --- breadcrumbs --------------------------------------------------------- */

static void invalidate_path_row(void)
{
    if (g_owner != NULL && g_active
        && g_path_row.right > g_path_row.left) {
        InvalWindowRect(g_owner, &g_path_row);
    }
}

/* --- the pull destination -------------------------------------------------
   Recomputes g_dest_path from wherever a pull would actually land,
   photos' refresh_dest_path verbatim with the opposite default (the
   downloads folder here, the share root there). */
static void refresh_dest_path(void)
{
    if (g_dest_set) {
        if (now_files_dir_path(g_dest_vref, g_dest_dir, g_dest_path,
                               sizeof g_dest_path)) {
            return;
        }
        /* The folder stopped being nameable (volume gone?): fall back
           to downloads, which is also where a pull would land now. */
        g_dest_set = false;
        now_wire_get_destination(false, 0, 0);
    }
    now_files_downloads_name(g_dest_path, sizeof g_dest_path);
}

static void invalidate_dest_row(void)
{
    if (g_owner != NULL && g_active && g_dest_row.right > g_dest_row.left) {
        InvalWindowRect(g_owner, &g_dest_row);
    }
}

static void choose_dest(void)
{
    char why[128];
    short vref;
    long dir;
    short dl_vref;
    long dl_dir;
    int rc;

    rc = now_files_choose_folder("Choose where files you get land",
                                 &vref, &dir, why, sizeof why);
    if (rc == 0) {
        return;                       /* cancelled: nothing changes */
    }
    if (rc < 0) {
        snprintf(g_dest_path, sizeof g_dest_path, "%.120s", why);
        invalidate_dest_row();
        return;
    }
    /* Choosing the downloads folder itself clears the override rather
       than setting an equal one: unset is the wire's "land in
       downloads" and keeps that path byte-identical to before the
       chooser existed. */
    if (now_files_downloads(&dl_vref, &dl_dir) == kFilesOK
        && dl_vref == vref && dl_dir == dir) {
        g_dest_set = false;
        now_wire_get_destination(false, 0, 0);
    } else {
        g_dest_set = true;
        g_dest_vref = vref;
        g_dest_dir = dir;
        now_wire_get_destination(true, vref, dir);
    }
    refresh_dest_path();
    invalidate_dest_row();
}

/* The wire's outcome for a pull THIS view asked for — reclaimed the
   instant drive_open_row asks, the listing hook's own rule
   (cloud_drive_listing follows drive_request the same way). Durable
   news (begin/end/refusal), so it goes through folder_status: it
   replaces the last folder listing the way a completed pull's outcome
   ought to outlive the click that started it, and view_idle's
   transient byte count still overlays it live and hands it back
   unharmed when the transfer ends. */
static void drive_get_note(const char *line)
{
    folder_status(line);
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
    /* The get-note hook follows the asker, the listing hook's own rule
       (drive_request, above): the Files page can steal it back for its
       own pull, so every ask from here claims it. */
    conn_set_get_note(drive_get_note);
    if (now_wire_get_host(next, row->name, err, sizeof err) < 0) {
        folder_status(err);
    } else {
        char line[96];

        snprintf(line, sizeof line, "Receiving %.40s into %.40s...",
                 row->name, g_dest_path);
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

/* Selection changed (-1 = deselected). The pane (view_draw's
   draw_item_card) reads g_sel directly and draws the selected item's
   own name/kind/size/date plus the double-click affordance line — that
   text moved off the placard and into the pane in this arc, so
   selection touches only the pane, never the placard. */
static void row_selected(int index)
{
    g_sel = (index >= 0 && index < g_drive_count) ? index : -1;
    if (g_host.invalidate_detail != NULL) {
        g_host.invalidate_detail();
    }
}

/* Shared by the Data Browser's own Size column and the pane's card:
   one wardrobe for the same number. */
static void format_size(const FileEntry *row, char *buf, size_t cap)
{
    long total = row->data_bytes + row->rsrc_bytes;

    if (total < 1024) {
        snprintf(buf, cap, "%ld bytes", total);
    } else if (total < 1024L * 1024L) {
        snprintf(buf, cap, "%ld K", total / 1024);
    } else {
        snprintf(buf, cap, "%ld.%ld MB", total / (1024L * 1024L),
                 (total % (1024L * 1024L)) / (105L * 1024L));
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
            format_size(row, buf, sizeof buf);
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
    /* The window owns g_dest_btn's/g_dl_bar's disposal (docs/adding-a-
       workshop-module.md, what you own and what you do not); only the
       refs and the wire's own override die here. */
    g_dest_btn = NULL;
    g_dest_set = false;
    now_wire_get_destination(false, 0, 0);
    g_dl_bar = NULL;
    g_bar_shown = false;
    g_bar_value = -1;
    g_dl_line[0] = '\0';
}

/* --- ops ------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    DataBrowserCallbacks callbacks;
    Rect start = { 0, 0, 0, 0 };      /* layout() places it before it
                                         is ever shown */
    Str255 text;

    g_owner = owner;
    cloud_nav_reset(&g_nav);
    g_dest_set = false;
    now_wire_get_destination(false, 0, 0);
    refresh_dest_path();
    g_bar_shown = false;
    g_bar_value = -1;
    g_dl_line[0] = '\0';
    SetRect(&g_dl_text_rect, 0, 0, 0, 0);
    CopyCStringToPascal("Choose...", text);
    g_dest_btn = NewControl(owner, &start, text, false, 0, 0, 1,
                            pushButProc, 0);
    /* Native determinate bar, Photos' download furniture verbatim
       (metal-verified there): scaled 0..1000 by cloud_dl_bar_value. */
    text[0] = 0;
    g_dl_bar = NewControl(owner, &start, text, false, 0, 0, 1000,
                          kControlProgressBarProc, 0);
    /* A missing control degrades that control, not the page: a pull
       still lands in downloads exactly as before, the row still names
       it, and the byte line still draws without the bar beside it. */
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

/* Shown only while drive mode is the page on stage — the shell already
   knows to call this (g_view->show, generic in cloud_module.c) the
   moment its own show/hide of g_browser and the history pair runs. */
static void view_show(Boolean visible)
{
    if (g_dest_btn != NULL) {
        if (visible) {
            /* The downloads folder may have moved while another page
               had the stage; one preferences read on a show is not
               idle work. */
            refresh_dest_path();
            ShowControl(g_dest_btn);
        } else {
            HideControl(g_dest_btn);
        }
    }
    if (g_dl_bar != NULL) {
        if (visible && g_bar_shown) {
            ShowControl(g_dl_bar);
        } else {
            HideControl(g_dl_bar);
        }
    }
}

static void view_layout(const CloudLayout *r)
{
    g_path_row = r->path_row;
    g_dest_row = r->dest_row;
    g_dl_text_rect = r->dl_text;
    if (g_dest_btn != NULL) {
        MoveControl(g_dest_btn, r->dest_btn.left, r->dest_btn.top);
        SizeControl(g_dest_btn,
                    (SInt16)(r->dest_btn.right - r->dest_btn.left),
                    (SInt16)(r->dest_btn.bottom - r->dest_btn.top));
    }
    if (g_dl_bar != NULL) {
        MoveControl(g_dl_bar, r->dl_bar.left, r->dl_bar.top);
        SizeControl(g_dl_bar,
                    (SInt16)(r->dl_bar.right - r->dl_bar.left),
                    (SInt16)(r->dl_bar.bottom - r->dl_bar.top));
    }
    if (g_browser == NULL) {
        return;
    }
    MoveControl(g_browser, r->list.left, r->list.top);
    SizeControl(g_browser, (SInt16)(r->list.right - r->list.left),
                (SInt16)(r->list.bottom - r->list.top));
}

static void draw_small_line(const Rect *row, const char *prefix,
                            const char *rest, Boolean middle_trunc)
{
    Str255 text;
    char line[224];
    short width = (short)(row->right - row->left);

    if (width <= 0) {
        return;
    }
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    snprintf(line, sizeof line, "%s%s", prefix, rest);
    CopyCStringToPascal(line, text);
    TruncString(width, text, middle_trunc ? truncMiddle : truncEnd);
    MoveTo(row->left, (short)(row->bottom - 6));
    DrawString(text);
}

/* One left-aligned, end-truncated line at an explicit y — the pane's
   own card text, as opposed to draw_small_line's fixed single-row
   furniture (which bottom-aligns inside its own rect). */
static void draw_pane_line(const Rect *text, short y, const char *s)
{
    Str255 t;
    short width = (short)(text->right - text->left);

    if (width <= 0 || y > text->bottom) {
        return;
    }
    CopyCStringToPascal(s, t);
    TruncString(width, t, truncEnd);
    MoveTo(text->left, y);
    DrawString(t);
}

/* The selected drive item's own detail, in the pane: for a folder,
   its name and kind; for a file, name/kind/size/date and the
   double-click affordance line — which used to live on the placard
   and comes back into the pane now, the same seam every other view's
   per-selection detail already draws into (docs/icloud.md, this arc).

   Deliberately textual only, no image preview: an IMAGE type here
   (PICT/JPEG/GIFf/PNGf) is still just a drive row with no cloud item
   id — cloud.preview is a cloud.* verb and Drive's transport is the
   file family, not cloud.* — so previewing one would need a REAL
   fetch-and-decode path this arc does not build. The seam is this
   function: a later arc that wants a preview replaces its body for
   the image-type case, honestly, rather than faking one from text. */
static void draw_item_card(const Rect *text)
{
    short y;
    char buf[64];
    char line[160];
    const FileEntry *row;

    if (text->right <= text->left || text->bottom <= text->top) {
        return;
    }
    y = (short)(text->top + 12);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    if (g_sel < 0 || g_sel >= g_drive_count) {
        draw_pane_line(text, y, "Select an item to see its detail.");
        return;
    }
    row = &g_drive_rows[g_sel];
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    draw_pane_line(text, y, row->name);
    y = (short)(y + 16);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    now_files_describe(row, buf, sizeof buf);
    snprintf(line, sizeof line, "Kind: %s", buf);
    draw_pane_line(text, y, line);
    y = (short)(y + 14);
    if (row->folder) {
        y = (short)(y + 6);
        draw_pane_line(text, y, "Double-click opens it.");
        return;
    }
    format_size(row, buf, sizeof buf);
    snprintf(line, sizeof line, "Size: %s", buf);
    draw_pane_line(text, y, line);
    y = (short)(y + 14);
    if (row->modified != 0 && y <= text->bottom) {
        Str255 prefix, when;
        LongDateTime ldt = (LongDateTime)row->modified;

        /* LongDateString, not DateString: 1904-epoch seconds pass
           2^31 in 1972, so every modern date through the signed API
           clamps to 1/19/72 - watched happening on the PowerBook.
           Drawn as two DrawStrings on one baseline rather than built
           into a C buffer: the pen advances on its own. */
        LongDateString(&ldt, shortDate, when, NULL);
        CopyCStringToPascal("Modified: ", prefix);
        MoveTo(text->left, y);
        DrawString(prefix);
        DrawString(when);
        y = (short)(y + 14);
    }
    y = (short)(y + 6);
    snprintf(line, sizeof line,
             "Double-click fetches \"%.40s\" to this Mac.", row->name);
    draw_pane_line(text, y, line);
}

/* The breadcrumbs: share-root name plus colon path, the Files page's
   path row verbatim (files_module.c's draw, now_files_path_label's
   words). Truncated in the middle — the ends are the halves a person
   reads. Full width, above the list/detail split. The destination row
   and the pull's byte line are this view's own furniture, in the
   pane now (moved off the old toolbar strip, 2026-08-02); the pane's
   card text is drawn last so its own trimmed detail_text never
   competes with a live control below it. */
static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    char line[224];
    Str255 text;

    (void)store;
    (void)service;
    (void)selected;               /* the shell's own selection; this
                                      view keeps its own (g_sel) */
    if (r->path_row.right > r->path_row.left) {
        now_files_path_label(g_drive_root, g_drive_path, line,
                             sizeof line);
        UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
        CopyCStringToPascal(line, text);
        TruncString((short)(r->path_row.right - r->path_row.left - 4),
                    text, truncMiddle);
        MoveTo((short)(r->path_row.left + 2),
               (short)(r->path_row.top + 12));
        DrawString(text);
    }
    draw_small_line(&r->dest_row, "Save into: ", g_dest_path, true);
    if (g_dl_line[0] != '\0') {
        draw_small_line(&r->dl_text, "", g_dl_line, false);
    }
    draw_item_card(&r->detail_text);
}

static Boolean view_click(const EventRecord *event, Point local)
{
    (void)event;
    (void)local;
    drive_go_up();
    return true;
}

/* The Choose... button: not shell-owned, offered here before the
   generic track (cloud_module.c's own rule — photos' Size popup and
   destination chooser are the precedent). */
static Boolean view_control_click(ControlRef control,
                                  const EventRecord *event, Point local)
{
    (void)event;
    if (control == NULL || control != g_dest_btn) {
        return false;
    }
    if (TrackControl(control, local, now_pump_action()) != 0) {
        choose_dest();
    }
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

/* Every pass while drive mode is on stage: two in-memory reads, the
   bar and its byte line repainted only when a shown value actually
   changed — Photos' download furniture idle discipline, reused
   verbatim (cloud_dl_bar_value/cloud_dl_bytes_line are pure functions
   in cloud_model.c; the two views just feed them from different wire
   entry points, see the furniture comment above g_dl_bar). The
   placard is untouched here — durable news only, from folder_status
   and the wire's own get-note outcomes, never a per-idle byte
   count. */
static void view_idle(const CloudLayout *r)
{
    long received = 0, expected = 0;
    char line[48];
    int value = -1;
    Boolean moving;

    if (now_wire_get_active(&received, &expected, NULL)) {
        value = cloud_dl_bar_value(received, expected);
        moving = (Boolean)(value >= 0);
        cloud_dl_bytes_line(received, expected, line, sizeof line);
    } else {
        moving = false;
        line[0] = '\0';
    }
    if (moving != g_bar_shown) {
        g_bar_shown = moving;
        if (g_dl_bar != NULL) {
            if (moving) {
                ShowControl(g_dl_bar);
            } else {
                HideControl(g_dl_bar);
            }
        }
        if (!moving) {
            g_bar_value = -1;
        }
    }
    if (moving && g_dl_bar != NULL && (short)value != g_bar_value) {
        g_bar_value = (short)value;
        SetControlValue(g_dl_bar, g_bar_value);
    }
    if (strcmp(line, g_dl_line) != 0) {
        strcpy(g_dl_line, line);
        if (g_owner != NULL && g_active) {
            InvalWindowRect(g_owner, &r->dl_text);
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
    view_show,                         /* the destination button only —
                                          the shell still owns both
                                          browsers' own visibility */
    view_layout,
    view_draw,                         /* the breadcrumb and dest rows */
    view_click,
    view_key,
    view_idle,
    view_reset_for_service,
    view_row_matches,
    NULL,                              /* select: no per-selection state */
    view_control_click,                /* the destination Choose... */
    NULL                               /* save_size: host default */
};

const CloudViewOps *cloud_drive_view_ops(void)
{
    return &k_ops;
}
