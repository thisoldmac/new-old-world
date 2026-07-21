#include "host_browser.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "pump.h"
#include "wire.h"

enum {
    kWinWidth = 460,
    kWinHeight = 320,
    kBarHeight = 44,              /* path line and the Up button */
    kMaxRows = 128,               /* pages accumulate into this */

    kColName = 'name',
    kColKind = 'kind',
    kColSize = 'size',

    kUpButton = 1
};

static WindowRef g_window;
static ControlRef g_browser;
static ControlRef g_up;
static FileEntry g_rows[kMaxRows];
static int g_row_count;
static char g_path[224];          /* what we are looking at, share-relative */
static char g_root[160];          /* what the other machine calls its share */
static char g_status[128];
static Boolean g_loading;

static void invalidate_bar(void)
{
    Rect r;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    SetRect(&r, 0, 0, kWinWidth, kBarHeight);
    InvalWindowRect(g_window, &r);
}

/* --- asking ------------------------------------------------------------- */

static void request(const char *path, long cursor)
{
    char err[96];

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
        snprintf(g_status, sizeof g_status, "%.100s", err);
        g_loading = false;
    } else {
        g_loading = true;
        snprintf(g_status, sizeof g_status, "Reading...");
    }
    invalidate_bar();
}

/* The enclosing folder, by dropping the last colon-separated segment. */
static void go_up(void)
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

static void open_row(int index)
{
    char next[224];

    if (index < 0 || index >= g_row_count) {
        return;
    }
    if (!g_rows[index].folder) {
        /* Pulling a file is the next rung; opening one says so rather
           than doing nothing, which reads as a broken double-click. */
        snprintf(g_status, sizeof g_status,
                 "Getting a file is not built yet: %.31s",
                 g_rows[index].name);
        invalidate_bar();
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

static Boolean build_control(void)
{
    Rect bounds;
    DataBrowserCallbacks callbacks;
    DataBrowserItemDataUPP data_upp;
    DataBrowserItemNotificationUPP notify_upp;

    SetRect(&bounds, -1, kBarHeight, kWinWidth + 1, kWinHeight + 1);
    if (CreateDataBrowserControl(g_window, &bounds, kDataBrowserListView,
                                 &g_browser) != noErr) {
        return false;
    }

    /* Real UPPs. This runtime is TARGET_RT_MAC_CFM, where a UPP is a
       routine descriptor rather than a bare pointer, and handing the
       Toolbox a cast C function is an immediate Type 3 (learned on the
       spike, not here). NULL means the constructor is missing, which is
       reportable rather than fatal. */
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    data_upp = NewDataBrowserItemDataUPP(item_data);
    notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    if (data_upp == NULL || notify_upp == NULL) {
        return false;
    }
    callbacks.u.v1.itemDataCallback = data_upp;
    callbacks.u.v1.itemNotificationCallback = notify_upp;
    if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr) {
        return false;
    }

    if (add_column(kColName, "Name", 210, true, 0) != noErr) {
        return false;
    }
    add_column(kColKind, "Kind", 150, false, 1);
    add_column(kColSize, "Size", 80, false, 2);
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    SetDataBrowserSortProperty(g_browser, kColName);
    /* Type-select answers to the focused control. It did not work on
       the spike even with this, and is not load-bearing; the focus is
       still right for the arrow keys. */
    SetKeyboardFocus(g_window, g_browser, kControlFocusNextPart);
    return true;
}

/* --- the wire's answer --------------------------------------------------- */

void host_browser_listing(const char *path, const FileEntry *entries,
                          int count, Boolean more, long cursor,
                          const char *root, const char *error)
{
    DataBrowserItemID ids[16];
    int i;

    if (g_window == NULL) {
        return;
    }
    /* An answer to a question we have since replaced is not ours. */
    if (path == NULL || strcmp(path, g_path) != 0) {
        return;
    }
    g_loading = false;
    if (error != NULL) {
        snprintf(g_status, sizeof g_status, "%.110s", error);
        invalidate_bar();
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
        snprintf(g_status, sizeof g_status, "%d items (more not shown)",
                 g_row_count);
    } else if (g_row_count == 0) {
        strcpy(g_status, "Empty");
    } else {
        snprintf(g_status, sizeof g_status, "%d item%s", g_row_count,
                 g_row_count == 1 ? "" : "s");
    }
    invalidate_bar();
}

/* --- window ------------------------------------------------------------- */

void host_browser_open(void)
{
    Rect bounds;
    Str255 text;
    char title[64];
    char peer[40];

    if (g_window != NULL) {
        SelectWindow(g_window);
        return;
    }
    SetRect(&bounds, 60, 80, 60 + kWinWidth, 80 + kWinHeight);
    CreateNewWindow(kDocumentWindowClass,
                    kWindowCloseBoxAttribute | kWindowCollapseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return;
    }
    conn_peer_label(peer, sizeof peer);
    snprintf(title, sizeof title, "%.40s", peer);
    CopyCStringToPascal(title, text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);

    SetRect(&bounds, kWinWidth - 60, 12, kWinWidth - 16, 32);
    CopyCStringToPascal("Up", text);
    g_up = NewControl(g_window, &bounds, text, true, 0, 0, 1, pushButProc,
                      kUpButton);

    if (!build_control()) {
        strcpy(g_status, "This Mac cannot show a list here");
        ShowWindow(g_window);
        return;
    }
    ShowWindow(g_window);
    SelectWindow(g_window);
    g_path[0] = '\0';
    request("", 1);
}

void host_browser_close(void)
{
    if (g_window == NULL) {
        return;
    }
    DisposeWindow(g_window);          /* takes its controls with it */
    g_window = NULL;
    g_browser = NULL;
    g_row_count = 0;
}

Boolean host_browser_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef host_browser_ref(void)
{
    return g_window;
}

void host_browser_draw(void)
{
    Rect bar;
    Str255 text;
    char line[200];
    RgnHandle visible;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    SetRect(&bar, 0, 0, kWinWidth, kBarHeight);
    EraseRect(&bar);

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    MoveTo(16, 18);
    if (g_path[0] == '\0') {
        snprintf(line, sizeof line, "%.60s",
                 g_root[0] != '\0' ? g_root : "Shared folder");
    } else {
        snprintf(line, sizeof line, "%.60s%.100s",
                 g_root[0] != '\0' ? g_root : "", g_path);
    }
    CopyCStringToPascal(line, text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo(16, 34);
    CopyCStringToPascal(g_status, text);
    DrawString(text);

    HiliteControl(g_up, g_path[0] == '\0' ? 255 : 0);
    DrawControls(g_window);
    visible = NewRgn();
    if (visible != NULL) {
        GetPortVisibleRegion(GetWindowPort(g_window), visible);
        UpdateControls(g_window, visible);
        DisposeRgn(visible);
    }
}

void host_browser_click(const EventRecord *event)
{
    ControlRef control = NULL;
    Point local = event->where;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GlobalToLocal(&local);
    if (FindControl(local, g_window, &control) != 0 && control == g_up) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            go_up();
        }
        return;
    }
    if (g_browser != NULL) {
        /* The control runs its own tracking: selection, dragging the
           divider, sorting by header. */
        HandleControlClick(g_browser, local, event->modifiers, NULL);
    }
}

void host_browser_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);

    if (g_window == NULL || g_browser == NULL) {
        return;
    }
    if (c == '\r' || c == 3) {                 /* Return opens */
        Handle selected = NewHandle(0);

        if (selected != NULL) {
            if (GetDataBrowserItems(g_browser, kDataBrowserNoItem, false,
                                    kDataBrowserItemIsSelected,
                                    selected) == noErr
                && GetHandleSize(selected) >= (Size)sizeof(DataBrowserItemID)) {
                DataBrowserItemID first;

                memcpy(&first, *selected, sizeof first);
                open_row((int)first - 1);
            }
            DisposeHandle(selected);
        }
        return;
    }
    HandleControlKey(g_browser,
                     (SInt16)((event->message & keyCodeMask) >> 8), c,
                     event->modifiers);
}

void host_browser_activate(Boolean becoming_active)
{
    if (g_browser != NULL) {
        SetControlVisibility(g_browser, true, true);
        (void)becoming_active;
    }
}
