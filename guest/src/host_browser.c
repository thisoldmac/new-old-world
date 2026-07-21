#include "host_browser.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "pump.h"
#include "wire.h"

enum {
    kWinWidth = 470,
    kWinHeight = 348,
    kBarHeight = 44,              /* path line and the Up button */
    kFootHeight = 34,             /* where things land, and how to get there */
    kMaxRows = 128,               /* pages accumulate into this */

    kColName = 'name',
    kColKind = 'kind',
    kColSize = 'size',

    kUpButton = 1
};

static WindowRef g_window;
static ControlRef g_browser;
static ControlRef g_up;
static ControlRef g_where;        /* the downloads folder */
static ControlRef g_reveal;
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
        char full[260];
        char err[96];

        if (g_path[0] == '\0') {
            snprintf(full, sizeof full, "%.31s", g_rows[index].name);
        } else {
            snprintf(full, sizeof full, "%.200s:%.31s", g_path,
                     g_rows[index].name);
        }
        if (now_wire_get_host(full, g_rows[index].name, err,
                              sizeof err) < 0) {
            snprintf(g_status, sizeof g_status, "%.110s", err);
        }
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

/* The two callback UPPs outlive build_control(), so they cannot be
   locals: they are routine descriptors the control keeps calling, and
   they have to be disposed when the control goes. DisposeWindow takes
   the CONTROL with it but knows nothing about these, so as locals they
   leaked two descriptors per open/close cycle - in a 6 MB partition,
   against a window a person opens and closes all afternoon. */
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

static Boolean build_control(void)
{
    Rect bounds;
    DataBrowserCallbacks callbacks;

    SetRect(&bounds, -1, kBarHeight, kWinWidth + 1,
            kWinHeight - kFootHeight);
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
    g_data_upp = NewDataBrowserItemDataUPP(item_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    /* Either one failing means no list; releasing BOTH matters, because
       the old code returned with the first still allocated whenever the
       second was the one that failed. */
    if (g_data_upp == NULL || g_notify_upp == NULL) {
        dispose_callbacks();
        return false;
    }
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
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

    {
        char where[64];
        char label[96];

        now_files_downloads_name(where, sizeof where);
        snprintf(label, sizeof label, "Get files into: %.31s", where);
        SetRect(&bounds, 12, kWinHeight - kFootHeight + 6, 296,
                kWinHeight - 8);
        CopyCStringToPascal(label, text);
        g_where = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                             pushButProc, 0);

        SetRect(&bounds, 304, kWinHeight - kFootHeight + 6, 372,
                kWinHeight - 8);
        CopyCStringToPascal("Open", text);
        g_reveal = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                              pushButProc, 0);
    }

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
    /* After the control is gone, never before: until DisposeWindow
       returns, the Data Browser may still call back through these. */
    dispose_callbacks();
}

Boolean host_browser_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef host_browser_ref(void)
{
    return g_window;
}

/* The wire's running commentary on a pull (conn_set_get_note). */
static void refresh_where(void)
{
    char where[64];
    char label[96];
    Str255 text;

    if (g_where == NULL) {
        return;
    }
    now_files_downloads_name(where, sizeof where);
    snprintf(label, sizeof label, "Get files into: %.31s", where);
    CopyCStringToPascal(label, text);
    SetControlTitle(g_where, text);
}

void host_browser_note(const char *line)
{
    if (g_window == NULL) {
        return;
    }
    snprintf(g_status, sizeof g_status, "%.110s", line);
    invalidate_bar();
}

/* Every event-loop pass while a pull is running, so the count moves
   instead of the window looking hung. Costs nothing when idle, and does
   NOT read preferences or redraw unless the number changed - the last
   panel that did paid for it by starving the transfer it was drawing. */
void host_browser_idle(void)
{
    long received = 0, expected = 0;
    static long last_shown = -1;

    if (g_window == NULL) {
        return;
    }
    if (!now_wire_get_active(&received, &expected)) {
        last_shown = -1;
        return;
    }
    if (received / 4096 == last_shown) {
        return;
    }
    last_shown = received / 4096;
    if (expected > 0) {
        snprintf(g_status, sizeof g_status, "Getting... %ld%% of %ld K",
                 received * 100 / expected, expected / 1024);
    } else {
        snprintf(g_status, sizeof g_status, "Getting... %ld K", received / 1024);
    }
    invalidate_bar();
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
    SetRect(&bar, 0, kWinHeight - kFootHeight, kWinWidth, kWinHeight);
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
    if (FindControl(local, g_window, &control) != 0 && control != NULL
        && (control == g_up || control == g_where || control == g_reveal)) {
        if (TrackControl(control, local, now_pump_action()) == 0) {
            return;
        }
        if (control == g_up) {
            go_up();
        } else if (control == g_where) {
            char why[128];
            int rc = now_files_choose_downloads(why, sizeof why);

            if (rc > 0) {
                refresh_where();
                snprintf(g_status, sizeof g_status, "Files you get land there");
            } else if (rc < 0) {
                snprintf(g_status, sizeof g_status, "%.110s", why);
            }
            invalidate_bar();
        } else {
            if (now_files_reveal_downloads() != kFilesOK) {
                snprintf(g_status, sizeof g_status,
                         "Could not open that folder");
                invalidate_bar();
            }
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

/* This existed, took the flag, and threw it away — nothing called it
   either, because the event loop had no activateEvt case at all. Both
   halves are fixed now: main.c routes activation here, and here it means
   what it says.

   The Data Browser draws its own active/inactive selection and header, but
   only if it is told; the three buttons around it need the usual pair. Up
   keeps its own rule (disabled at the root), so re-activation re-derives
   it rather than blanket-enabling. */
void host_browser_activate(Boolean becoming_active)
{
    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    if (becoming_active) {
        if (g_browser != NULL) {
            ActivateControl(g_browser);
            SetKeyboardFocus(g_window, g_browser, kControlFocusNextPart);
        }
        if (g_up != NULL) {
            ActivateControl(g_up);
            HiliteControl(g_up, g_path[0] == '\0' ? 255 : 0);
        }
        if (g_where != NULL) {
            ActivateControl(g_where);
        }
        if (g_reveal != NULL) {
            ActivateControl(g_reveal);
        }
    } else {
        if (g_browser != NULL) {
            DeactivateControl(g_browser);
        }
        if (g_up != NULL) {
            DeactivateControl(g_up);
        }
        if (g_where != NULL) {
            DeactivateControl(g_where);
        }
        if (g_reveal != NULL) {
            DeactivateControl(g_reveal);
        }
    }
}
