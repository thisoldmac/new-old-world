#include "files_browser_view.h"

#include <stdio.h>
#include <string.h>

#include "files_path_label.h"
#include "wire.h"

enum {
    kMaxRows = 128,               /* pages accumulate into this */

    kColName = 'name',
    kColKind = 'kind',
    kColSize = 'size',
    kColModified = 'modf'
};

static WindowRef g_owner;
static ControlRef g_browser;
static Rect g_area;
static Boolean g_visible;
static FileEntry g_rows[kMaxRows];
static int g_row_count;
static char g_path[224];          /* what we are looking at, share-relative */
static char g_root[160];          /* what the other machine calls its share */
static char g_count[48];          /* listing state, for the path row */
static char g_note[128];          /* transfer talk and errors, placard */
static Boolean g_loading;

/* The pull in flight, and the one-shot that says one just started here.
   The state is folded from now_wire_get_active() rather than counted
   again: there is one notion of "a transfer is running" on this side and
   this is a view of it, not a second copy. */
static PullView g_pull;
static Boolean g_pull_began;

static void invalidate_chrome(void)
{
    /* The path row and status placard both read this view's state; the
       module repaints them off its idle caches, so a bounded poke at
       the whole pane is enough here. */
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_area);
    }
}

/* --- asking ------------------------------------------------------------- */

static void request(const char *path, long cursor)
{
    char err[96];

    /* The listing hook follows the asker: the iCloud page's drive
       browser borrows it (cloud_module.c), so every ask from here
       claims it back. */
    conn_set_listing(files_browser_listing);
    if (cursor <= 1) {
        g_row_count = 0;
        if (g_browser != NULL) {
            RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                                   kDataBrowserItemNoProperty);
        }
        strncpy(g_path, path != NULL ? path : "", sizeof g_path - 1);
        g_path[sizeof g_path - 1] = '\0';
    }
    if (now_wire_list_host(g_path, cursor, err, sizeof err) < 0) {
        snprintf(g_note, sizeof g_note, "%.100s", err);
        g_loading = false;
    } else {
        g_loading = true;
        snprintf(g_count, sizeof g_count, "Reading...");
    }
    invalidate_chrome();
}

/* The enclosing folder, by dropping the last colon-separated segment. */
void files_browser_go_up(void)
{
    char *colon;

    if (g_path[0] == '\0') {
        return;
    }
    colon = strrchr(g_path, ':');
    if (colon == NULL) {
        request("", 1);
    } else {
        *colon = '\0';
        request(g_path, 1);
    }
}

Boolean files_browser_at_root(void)
{
    return g_path[0] == '\0';
}

static void open_row(int index)
{
    char next[224];

    if (index < 0 || index >= g_row_count) {
        return;
    }
    if (!g_rows[index].folder) {
        char full[260];
        char err[96];

        if (g_path[0] == '\0') {
            snprintf(full, sizeof full, "%.31s", g_rows[index].name);
        } else {
            snprintf(full, sizeof full, "%.200s:%.31s", g_path,
                     g_rows[index].name);
        }
        /* Said before it is asked for, so the pane is already describing
           the transfer when the module paints the Stop button into this
           same click. */
        now_pull_asked(&g_pull, g_rows[index].name);
        if (now_wire_get_host(full, g_rows[index].name, err,
                              sizeof err) < 0) {
            now_pull_reset(&g_pull);
            snprintf(g_note, sizeof g_note, "%.110s", err);
        } else {
            g_pull_began = true;
            g_note[0] = '\0';         /* the last transfer's news is stale */
        }
        invalidate_chrome();
        return;
    }
    if (g_path[0] == '\0') {
        snprintf(next, sizeof next, "%.31s", g_rows[index].name);
    } else {
        snprintf(next, sizeof next, "%.180s:%.31s", g_path,
                 g_rows[index].name);
    }
    request(next, 1);
}

/* --- the control -------------------------------------------------------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const FileEntry *row;
    CFStringRef text = NULL;
    char buf[64];

    (void)browser;
    if (changeValue || item < 1 || item > (DataBrowserItemID)g_row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_rows[item - 1];
    switch (property) {
    case kColName:
        text = CFStringCreateWithCString(NULL, row->name,
                                         kCFStringEncodingMacRoman);
        break;
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
    if (message == kDataBrowserItemDoubleClicked) {
        open_row((int)item - 1);
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
    col.propertyDesc.propertyType = kDataBrowserTextType;
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

/* Real UPPs, retained for the control's lifetime. Two reasons, both
   learned the hard way: on this CFM runtime a UPP is a routine
   descriptor rather than a cast function pointer (finding
   carbon-upp-is-not-a-cast-on-cfm), and as locals they would leak one
   descriptor pair per create/dispose cycle. */
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

Boolean files_browser_create(WindowRef owner, const Rect *area)
{
    DataBrowserCallbacks callbacks;

    g_owner = owner;
    g_area = *area;
    g_count[0] = '\0';
    g_note[0] = '\0';
    if (CreateDataBrowserControl(owner, &g_area, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;
        return false;
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
        return false;
    }
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
    if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr) {
        return false;
    }
    if (add_column(kColName, "Name", 180, true, 0) != noErr) {
        return false;
    }
    add_column(kColKind, "Kind", 110, false, 1);
    add_column(kColSize, "Size", 64, false, 2);
    add_column(kColModified, "Modified", 90, false, 3);
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    SetDataBrowserSortProperty(g_browser, kColName);
    HideControl(g_browser);
    g_path[0] = '\0';
    g_row_count = 0;
    return true;
}

void files_browser_dispose(void)
{
    /* Dispose the Data Browser BEFORE its UPPs: workshop_close disposes
       this module ahead of DisposeWindow, so the control is still live,
       and its disposal fires item notifications through these UPPs.
       Freeing them first let DisposeWindow later call a freed transition
       vector - an intermittent system crash on quit. */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    g_owner = NULL;
    g_row_count = 0;
}

Boolean files_browser_available(void)
{
    return g_browser != NULL;
}

void files_browser_layout(const Rect *area)
{
    g_area = *area;
    if (g_browser == NULL) {
        return;
    }
    MoveControl(g_browser, area->left, area->top);
    SizeControl(g_browser, (SInt16)(area->right - area->left),
                (SInt16)(area->bottom - area->top));
}

void files_browser_show(Boolean visible)
{
    g_visible = visible;
    if (g_browser == NULL) {
        return;
    }
    if (visible) {
        ShowControl(g_browser);
        if (g_row_count == 0 && !g_loading && conn_is_connected()) {
            request("", 1);
        }
    } else {
        HideControl(g_browser);
    }
}

void files_browser_draw(void)
{
    /* The Data Browser draws itself with the other controls; a missing
       one is the module's fallback text to draw, not ours. */
}

Boolean files_browser_click(const EventRecord *event, Point local)
{
    if (g_browser == NULL || !g_visible) {
        return false;
    }
    if (!PtInRect(local, &g_area)) {
        return false;
    }
    /* The control runs its own tracking: selection, dragging the
       divider, sorting by header. */
    HandleControlClick(g_browser, local, event->modifiers, NULL);
    return true;
}

Boolean files_browser_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    ControlRef focus = NULL;

    if (g_browser == NULL || !g_visible) {
        return false;
    }
    /* Only when the list has the focus: otherwise the arrows belong to
       the sidebar, and Return means nothing here. */
    if (GetKeyboardFocus(g_owner, &focus) != noErr || focus != g_browser) {
        return false;
    }
    if (c == '\r' || c == 3) {                 /* Return opens */
        Handle selected = NewHandle(0);

        if (selected != NULL) {
            if (GetDataBrowserItems(g_browser, kDataBrowserNoItem, false,
                                    kDataBrowserItemIsSelected,
                                    selected) == noErr
                && GetHandleSize(selected)
                       >= (Size)sizeof(DataBrowserItemID)) {
                DataBrowserItemID first;

                memcpy(&first, *selected, sizeof first);
                open_row((int)first - 1);
            }
            DisposeHandle(selected);
        }
        return true;
    }
    HandleControlKey(g_browser,
                     (SInt16)((event->message & keyCodeMask) >> 8), c,
                     event->modifiers);
    return true;
}

void files_browser_activate(Boolean active)
{
    if (g_browser == NULL) {
        return;
    }
    if (active) {
        ActivateControl(g_browser);
        if (g_visible && g_owner != NULL) {
            SetKeyboardFocus(g_owner, g_browser, kControlFocusNextPart);
        }
    } else {
        DeactivateControl(g_browser);
    }
}

/* Every event-loop pass while a pull is running, so the count moves
   instead of the pane looking hung. Reads memory only, and recomposes
   the line only when now_pull_step says something a person could see has
   changed - over MacTCP a chunk arrives thousands of times per file. */
static char g_pull_note[128];

void files_browser_idle(void)
{
    long received = 0, expected = 0;
    WireGetPhase phase = kWireGetNone;
    Boolean active;
    static long last_step = -1;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    active = now_wire_get_active(&received, &expected, &phase);
    now_pull_observe(&g_pull, active,
                     (Boolean)(phase == kWireGetReceiving),
                     received, expected);
    if (!active) {
        last_step = -1;
        g_pull_note[0] = '\0';
        return;
    }
    if (now_pull_step(&g_pull) == last_step) {
        return;
    }
    last_step = now_pull_step(&g_pull);
    now_pull_note(&g_pull, g_pull_note, sizeof g_pull_note);
}

Boolean files_browser_pull(PullView *out)
{
    if (out != NULL) {
        *out = g_pull;
    }
    return (Boolean)(g_pull.phase != kPullIdle);
}

Boolean files_browser_pull_began(void)
{
    Boolean began = g_pull_began;

    g_pull_began = false;
    return began;
}

Boolean files_browser_stop_pull(char *err, long cap)
{
    if (!now_pull_can_stop(&g_pull)) {
        if (err != NULL && cap > 0) {
            snprintf(err, (size_t)cap, "Nothing is being transferred.");
        }
        return false;
    }
    now_pull_stopping(&g_pull);
    /* The line goes up before the wire is touched, so the pane is
       already saying "Stopping" if the teardown takes a pass. */
    now_pull_note(&g_pull, g_pull_note, sizeof g_pull_note);
    if (now_pull_cancel(err, cap) != 0) {
        /* The wire refused. The pull is whatever it was; let the next
           idle pass re-derive it from now_wire_get_active rather than
           guess here. */
        return false;
    }
    /* What is left behind, said out loud: a pull is never resumable, so
       the temp is deleted and nothing appears under the real name. The
       person cannot check that without walking to the downloads folder,
       so the pane says it. */
    now_pull_stopped_note(&g_pull, g_note, sizeof g_note);
    invalidate_chrome();
    return true;
}

void files_browser_path_text(char *out, long cap)
{
    now_files_path_label(g_root, g_path, out, cap);
}

void files_browser_count_text(char *out, long cap)
{
    snprintf(out, (size_t)cap, "%s", g_count);
}

void files_browser_note_text(char *out, long cap)
{
    /* A live transfer outranks the last one's news: "Got Report.cwk"
       left standing while the next file comes down is the pane telling
       a person the wrong thing about right now. */
    if (g_pull.phase != kPullIdle && g_pull_note[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_pull_note);
        return;
    }
    snprintf(out, (size_t)cap, "%s", g_note);
}

/* --- the wire's answer -------------------------------------------------- */

void files_browser_listing(const char *path, const FileEntry *entries,
                           int count, Boolean more, long cursor,
                           const char *root, const char *error)
{
    DataBrowserItemID ids[16];
    int i;

    if (g_browser == NULL) {
        return;
    }
    /* An answer to a question we have since replaced is not ours. */
    if (path == NULL || strcmp(path, g_path) != 0) {
        return;
    }
    g_loading = false;
    if (error != NULL) {
        snprintf(g_note, sizeof g_note, "%.110s", error);
        g_count[0] = '\0';
        invalidate_chrome();
        return;
    }
    if (root != NULL && root[0] != '\0') {
        strncpy(g_root, root, sizeof g_root - 1);
        g_root[sizeof g_root - 1] = '\0';
    }

    for (i = 0; i < count && g_row_count < kMaxRows; ++i) {
        g_rows[g_row_count] = entries[i];
        ids[i] = (DataBrowserItemID)(++g_row_count);
    }
    if (i > 0) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem, i, ids,
                            kDataBrowserItemNoProperty);
    }

    if (more && g_row_count < kMaxRows) {
        /* Pages are fetched straight through: a listing is small and
           control-plane, and a half-shown folder invites acting on a
           file that is not really the one you meant. */
        request(g_path, cursor);
        return;
    }
    if (more) {
        snprintf(g_count, sizeof g_count, "%d items (more not shown)",
                 g_row_count);
    } else if (g_row_count == 0) {
        strcpy(g_count, "Empty");
    } else {
        snprintf(g_count, sizeof g_count, "%d item%s", g_row_count,
                 g_row_count == 1 ? "" : "s");
    }
    invalidate_chrome();
}

void files_browser_note(const char *line)
{
    if (g_owner == NULL) {
        return;
    }
    snprintf(g_note, sizeof g_note, "%.110s", line);
    invalidate_chrome();
}
