#include "cloud_module.h"

#include <stdio.h>
#include <string.h>

#include "cloud_drive_view.h"
#include "cloud_layout.h"
#include "cloud_list_view.h"
#include "cloud_model.h"
#include "cloud_view.h"
#include "json.h"
#include "pump.h"
#include "wire.h"

/* The iCloud page: the modern machine's cloud, browsed from this one.
   One dropdown of services (cloud.report), and a render tailored to
   the chosen service. Photos and Contacts list rows (cloud.listing,
   paged straight through like the Files browser) with a card for the
   selected one (cloud.card) and Save, which asks for the row as an
   ordinary file into this machine's share (cloud.get -> file.offer).

   Drive is a real file browser HERE, not a signpost — but its
   transport is still the file family against the share, exactly as
   the contract's x-cloud prescribes: this page calls the same
   now_wire_list_host the Files page calls, and the listing hook
   follows whoever asked last ("a second request replaces the first"
   is already the wire's rule for the answer). One implementation,
   now genuinely two renderers. A double-clicked file pulls through
   now_wire_get_host into the downloads folder, and the card pane
   shows the pull moving.

   All cloud answers arrive through one raw-frame hook and are parsed
   by cloud_model.c, which the host cc tests; this file owns controls,
   rectangles and pixels, and decides nothing about the bytes.

   This file is the SHELL: the popup, Refresh, the status/placard, the
   conn_set_cloud_note hook, and which service is chosen. Everything
   about how a chosen service renders — Drive's file browser, the
   generic listing+card Photos and Contacts share — lives behind
   CloudViewOps (cloud_view.h) in cloud_drive_view.c and
   cloud_list_view.c, so a new service view is a new file, not a new
   branch in this one. */

enum {
    kCloudServicesMenuID = 135
};

static WindowRef g_owner;
static Rect g_body;
static CloudLayout g_r;
static Boolean g_visible;

static ControlRef g_popup;
static ControlRef g_refresh;
static ControlRef g_save;
static ControlRef g_browser;
static MenuRef g_menu;

static CloudStore g_store;
static int g_service = -1;            /* index into g_store.services */
static int g_selected = -1;           /* row index: cloud rows, or in
                                         drive mode the view's own rows */
static Boolean g_loading;
static Boolean g_asked_once;
static Boolean g_in_rebuild;
static char g_status[128];

/* Drive mode: the chosen service is drive and the share serves it.
   g_drive_mode is chrome bookkeeping only now (the button's title, the
   Save/Up enable rule) — cloud_drive_view.c owns everything else about
   browsing it. */
static Boolean g_drive_mode;
static const CloudViewOps *g_view;

static char g_shown_status[128];
static Boolean g_shown_save_on;

static void invalidate_detail(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.detail);
    }
}

static void invalidate_status(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.status);
    }
}

static void set_status(const char *line)
{
    snprintf(g_status, sizeof g_status, "%.120s", line);
    invalidate_status();
}

static void set_loading(Boolean loading)
{
    g_loading = loading;
}

static const CloudService *current_service(void)
{
    if (g_service < 0 || g_service >= g_store.service_count) {
        return NULL;
    }
    return &g_store.services[g_service];
}

/* --- asking (services and the list/card pair; Drive asks through its
   own view file) -------------------------------------------------- */

static void ask_services(void)
{
    char err[96];

    if (now_wire_cloud_services(err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    g_loading = true;
    set_status("Asking what is on offer...");
}

static void ask_rows(long cursor)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL) {
        return;
    }
    if (cursor <= 1) {
        cloud_store_reset_rows(&g_store, service->service);
        g_selected = -1;
        if (g_browser != NULL) {
            g_in_rebuild = true;
            RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                                   kDataBrowserItemNoProperty);
            g_in_rebuild = false;
        }
        invalidate_detail();
    }
    if (now_wire_cloud_list(service->service, cursor, err,
                            sizeof err) != 0) {
        g_loading = false;
        set_status(err);
        return;
    }
    g_loading = true;
    set_status("Reading...");
}

static void ask_card(void)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL || g_selected < 0
        || g_selected >= g_store.row_count) {
        return;
    }
    cloud_store_reset_card(&g_store);
    invalidate_detail();
    if (now_wire_cloud_detail(service->service,
                              g_store.rows[g_selected].item,
                              err, sizeof err) != 0) {
        set_status(err);
    }
}

static void ask_save(void)
{
    const CloudService *service = current_service();
    char err[96];

    if (service == NULL || g_selected < 0
        || g_selected >= g_store.row_count) {
        return;
    }
    if (now_wire_cloud_get(service->service,
                           g_store.rows[g_selected].item,
                           err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    set_status("Asking for it...");
}

/* --- the list, shared by both views -------------------------------- */

static void clear_list(void)
{
    g_selected = -1;
    if (g_browser != NULL) {
        g_in_rebuild = true;
        RemoveDataBrowserItems(g_browser, kDataBrowserNoItem, 0, NULL,
                               kDataBrowserItemNoProperty);
        g_in_rebuild = false;
    }
}

/* --- the dropdown ------------------------------------------------------- */

/* The popup's menu, asked for the blessed way. Under CarbonLib the
   classic popupMenuProc procID resolves to the Appearance popup, whose
   menu is reached through GetControlData — GetMenuHandle only finds it
   if the CDEF put it in the menu list, which is the CDEF's business,
   not a promise. Fall back to the menu list for older paths, and say
   so out loud when both come up empty: a silent NULL here is a
   dropdown stuck on "(none)" with nothing to explain it. */
static MenuRef popup_menu(void)
{
    MenuRef menu = NULL;
    Size got = 0;

    if (g_popup != NULL
        && GetControlData(g_popup, kControlEntireControl,
                          kControlPopupButtonMenuHandleTag,
                          sizeof menu, (Ptr)&menu, &got) == noErr
        && got == (Size)sizeof menu && menu != NULL) {
        return menu;
    }
    return GetMenuHandle(kCloudServicesMenuID);
}

static void rebuild_popup(void)
{
    int i;

    g_menu = popup_menu();
    if (g_menu == NULL) {
        set_status("The services menu is missing (resource 135)");
        return;
    }
    while (CountMenuItems(g_menu) > 0) {
        DeleteMenuItem(g_menu, 1);
    }
    for (i = 0; i < g_store.service_count; ++i) {
        Str255 label;

        /* Appended as a placeholder then renamed: AppendMenu interprets
           metacharacters, and a label is data, not a menu program. */
        CopyCStringToPascal("x", label);
        AppendMenu(g_menu, label);
        CopyCStringToPascal(g_store.services[i].label, label);
        SetMenuItemText(g_menu, (short)(i + 1), label);
    }
    if (g_store.service_count == 0) {
        Str255 none;

        CopyCStringToPascal("(none)", none);
        AppendMenu(g_menu, none);
    }
    if (g_popup != NULL) {
        SetControlMaximum(g_popup, CountMenuItems(g_menu));
        SetControlValue(g_popup,
                        (short)(g_service >= 0 ? g_service + 1 : 1));
        Draw1Control(g_popup);
    }
}

static void retitle_button(void)
{
    Str255 text;

    if (g_save == NULL) {
        return;
    }
    CopyCStringToPascal(g_drive_mode ? "Up" : "Save to this Mac", text);
    SetControlTitle(g_save, text);
}

static void choose_service(int index)
{
    const CloudService *service;

    if (index < 0 || index >= g_store.service_count) {
        return;
    }
    g_service = index;
    service = &g_store.services[g_service];
    cloud_store_reset_rows(&g_store, service->service);
    g_drive_mode = strcmp(service->service, "drive") == 0
        && strcmp(service->state, "serving") == 0;
    cloud_drive_view_activate(g_drive_mode);
    g_view = g_drive_mode ? cloud_drive_view_ops() : cloud_list_view_ops();
    retitle_button();
    clear_list();
    invalidate_detail();
    if (g_drive_mode) {
        if (g_view != NULL && g_view->reset_for_service != NULL) {
            g_view->reset_for_service(service);
        }
    } else if (strcmp(service->state, "serving") == 0
               && cloud_service_listable(service->service)) {
        ask_rows(1);
    } else {
        /* The pane's words are the service's own: state and detail from
           the report, drawn by the active view's draw(). */
        set_status(service->detail[0] != '\0' ? service->detail
                                              : service->state);
    }
}

/* --- the wire's answers ------------------------------------------------- */

static void note_report(const char *reply)
{
    int first;

    g_loading = false;
    cloud_parse_report(reply, &g_store);
    first = cloud_first_listable(&g_store);
    if (first < 0 && g_store.service_count > 0) {
        first = 0;
    }
    g_service = first;
    rebuild_popup();
    if (g_store.service_count == 0) {
        set_status("The other Mac offers no cloud services");
        return;
    }
    choose_service(first);
}

static void note_listing(const char *reply)
{
    DataBrowserItemID ids[16];
    int before = g_store.row_count;
    int added;
    int i;

    g_loading = false;
    added = cloud_parse_listing(reply, &g_store);
    for (i = 0; i < added && i < 16; ++i) {
        ids[i] = (DataBrowserItemID)(before + i + 1);
    }
    if (i > 0 && g_browser != NULL) {
        AddDataBrowserItems(g_browser, kDataBrowserNoItem,
                            (UInt32)i, ids, kDataBrowserItemNoProperty);
    }
    if (g_store.more && g_store.row_count < kCloudMaxRows) {
        ask_rows(g_store.cursor);
        return;
    }
    {
        char line[64];

        cloud_listing_status(&g_store, line, sizeof line);
        set_status(line);
    }
}

static void note_card(const char *reply)
{
    cloud_parse_card(reply, &g_store);
    invalidate_detail();
}

static void note_get_under_way(const char *offer)
{
    char name[64];
    char line[96];

    name[0] = '\0';
    now_json_find_text(offer, "name", name, sizeof name);
    if (name[0] != '\0') {
        snprintf(line, sizeof line,
                 "Receiving %.40s into the shared folder", name);
    } else {
        strcpy(line, "Receiving into the shared folder");
    }
    set_status(line);
}

static void cloud_answers(int kind, const char *reply)
{
    switch (kind) {
    case kCloudAnswerReport:      note_report(reply); break;
    case kCloudAnswerListing:     note_listing(reply); break;
    case kCloudAnswerCard:        note_card(reply); break;
    case kCloudAnswerGetUnderWay: note_get_under_way(reply); break;
    case kCloudAnswerError:
        g_loading = false;
        set_status(reply);
        break;
    default:
        break;
    }
}

/* --- the list control --------------------------------------------------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const CloudRow *row;
    CFStringRef text = NULL;
    char buf[64];               /* matches the pre-split buffer size */

    (void)browser;
    if (changeValue || item < 1) {
        return errDataBrowserPropertyNotSupported;
    }
    if (g_drive_mode) {
        if (!cloud_drive_view_row_text(item, property, buf, sizeof buf)) {
            return errDataBrowserPropertyNotSupported;
        }
        text = CFStringCreateWithCString(NULL, buf,
                                         kCFStringEncodingMacRoman);
        if (text == NULL) {
            return memFullErr;
        }
        SetDataBrowserItemDataText(data, text);
        CFRelease(text);
        return noErr;
    }
    if (item > (DataBrowserItemID)g_store.row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_store.rows[item - 1];
    switch (property) {
    case kCloudColTitle:
        text = CFStringCreateWithCString(NULL, row->title,
                                         kCFStringEncodingMacRoman);
        break;
    case kCloudColSubtitle:
        text = CFStringCreateWithCString(NULL, row->subtitle,
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
    /* Notifications fired by our own rebuild are not user intent. */
    if (g_in_rebuild) {
        return;
    }
    if (message == kDataBrowserItemDoubleClicked && g_drive_mode) {
        cloud_drive_view_row_opened((int)item - 1);
        return;
    }
    if (message == kDataBrowserItemSelected) {
        g_selected = (int)item - 1;
        if (g_drive_mode) {
            invalidate_detail();      /* the card is composed by the view */
        } else {
            ask_card();
        }
    } else if (message == kDataBrowserItemDeselected
               && g_selected == (int)item - 1) {
        g_selected = -1;
        cloud_store_reset_card(&g_store);
        invalidate_detail();
    }
}

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
                           UInt16 width,
                           DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags = 0;
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

/* --- module ops --------------------------------------------------------- */

static OSErr cloud_create(WindowRef owner, const Rect *body)
{
    DataBrowserCallbacks callbacks;
    CloudDriveHost host;
    const CloudViewOps *drive_ops = cloud_drive_view_ops();
    Str255 text;

    g_owner = owner;
    g_body = *body;
    cloud_layout_compute(body, &g_r);
    cloud_store_reset(&g_store);
    g_service = -1;
    g_selected = -1;
    g_drive_mode = false;
    g_view = cloud_list_view_ops();
    g_status[0] = '\0';
    g_shown_status[0] = '\0';
    g_shown_save_on = false;

    /* The dropdown's menu: a placeholder resource the report rewrites.
       The popup CDEF inserts it into the hierarchical list, which is
       where GetMenuHandle finds it again. */
    text[0] = 0;
    g_popup = NewControl(owner, &g_r.popup, text, false,
                         popupTitleLeftJust, kCloudServicesMenuID, 0,
                         popupMenuProc, 0);
    g_menu = popup_menu();
    CopyCStringToPascal("Refresh", text);
    g_refresh = NewControl(owner, &g_r.refresh_btn, text, false, 0, 0, 1,
                           pushButProc, 0);
    CopyCStringToPascal("Save to this Mac", text);
    g_save = NewControl(owner, &g_r.save_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    if (g_popup == NULL || g_refresh == NULL || g_save == NULL) {
        return memFullErr;
    }

    if (CreateDataBrowserControl(owner, &g_r.list, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;             /* the pane says so; no hard fail */
    } else {
        memset(&callbacks, 0, sizeof callbacks);
        callbacks.version = kDataBrowserLatestCallbacks;
        InitDataBrowserCallbacks(&callbacks);
        g_data_upp = NewDataBrowserItemDataUPP(item_data);
        g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
        if (g_data_upp == NULL || g_notify_upp == NULL) {
            dispose_callbacks();
            DisposeControl(g_browser);
            g_browser = NULL;
        } else {
            callbacks.u.v1.itemDataCallback = g_data_upp;
            callbacks.u.v1.itemNotificationCallback = g_notify_upp;
            SetDataBrowserCallbacks(g_browser, &callbacks);
            add_column(kCloudColTitle, "Item", 200, 0);
            add_column(kCloudColSubtitle, "Detail", 130, 1);
            SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
            SetDataBrowserHasScrollBars(g_browser, false, true);
            HideControl(g_browser);
        }
    }

    if (drive_ops->create != NULL) {
        drive_ops->create(owner);
    }
    host.clear_list = clear_list;
    host.invalidate_detail = invalidate_detail;
    host.set_status = set_status;
    host.set_loading = set_loading;
    cloud_drive_view_bind(g_browser, &host);
    cloud_drive_view_activate(false);

    conn_set_cloud_note(cloud_answers);
    return noErr;
}

static void cloud_dispose(void)
{
    conn_set_cloud_note(NULL);
    cloud_drive_view_dispose();
    /* The Data Browser goes BEFORE its UPPs: disposal fires item
       notifications through them (files_browser_view.c and the finding
       carbon-upp-is-not-a-cast-on-cfm carry the full story). */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    g_popup = NULL;
    g_refresh = NULL;
    g_save = NULL;
    g_menu = NULL;
    g_owner = NULL;
    g_view = NULL;
}

static void show_control(ControlRef control, Boolean on)
{
    if (control == NULL) {
        return;
    }
    if (on) {
        ShowControl(control);
    } else {
        HideControl(control);
    }
}

/* The one action button, worn per mode: Up in the drive browser
   (enabled off the root), Save for a selected row elsewhere. */
static Boolean action_applies(void)
{
    const CloudService *service = current_service();

    if (g_drive_mode) {
        return !cloud_drive_view_at_root();
    }
    return service != NULL && g_selected >= 0
        && g_selected < g_store.row_count
        && cloud_service_listable(service->service);
}

static void cloud_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_popup, visible);
    show_control(g_refresh, visible);
    show_control(g_save, visible && action_applies());
    show_control(g_browser, visible);
    if (g_view != NULL && g_view->show != NULL) {
        g_view->show(visible);
    }
    if (visible && !g_asked_once && conn_is_connected()) {
        g_asked_once = true;
        ask_services();
    }
}

static void cloud_layout(const Rect *body)
{
    g_body = *body;
    cloud_layout_compute(body, &g_r);
    if (g_popup != NULL) {
        MoveControl(g_popup, g_r.popup.left, g_r.popup.top);
        SizeControl(g_popup, (SInt16)(g_r.popup.right - g_r.popup.left),
                    (SInt16)(g_r.popup.bottom - g_r.popup.top));
    }
    if (g_refresh != NULL) {
        MoveControl(g_refresh, g_r.refresh_btn.left, g_r.refresh_btn.top);
        SizeControl(g_refresh,
                    (SInt16)(g_r.refresh_btn.right - g_r.refresh_btn.left),
                    (SInt16)(g_r.refresh_btn.bottom - g_r.refresh_btn.top));
    }
    if (g_save != NULL) {
        MoveControl(g_save, g_r.save_btn.left, g_r.save_btn.top);
        SizeControl(g_save,
                    (SInt16)(g_r.save_btn.right - g_r.save_btn.left),
                    (SInt16)(g_r.save_btn.bottom - g_r.save_btn.top));
    }
    if (g_browser != NULL) {
        MoveControl(g_browser, g_r.list.left, g_r.list.top);
        SizeControl(g_browser, (SInt16)(g_r.list.right - g_r.list.left),
                    (SInt16)(g_r.list.bottom - g_r.list.top));
    }
    if (g_view != NULL && g_view->layout != NULL) {
        g_view->layout(&g_r);
    }
}

static void draw_at(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

static void cloud_draw(void)
{
    const CloudService *service = current_service();

    if (g_owner == NULL || !g_visible) {
        return;
    }
    /* The status line. */
    draw_at((short)(g_r.status.left + 2),
            (short)(g_r.status.bottom - 3), g_status);

    /* The card pane: whichever view is active draws it. */
    if (g_view != NULL && g_view->draw != NULL) {
        g_view->draw(&g_r, &g_store, service, g_selected);
    }
}

static Boolean cloud_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (g_browser != NULL && PtInRect(local, &g_r.list)) {
        HandleControlClick(g_browser, local, event->modifiers, NULL);
        return true;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_popup) {
        short before = GetControlValue(g_popup);

        /* Popup CDEFs run their own action; -1L is the documented
           value, and now_pump_action would starve the wire less than
           the menu loop already does (nested-loops.md). */
        TrackControl(control, local, (ControlActionUPP)-1L);
        if (GetControlValue(g_popup) != before) {
            choose_service(GetControlValue(g_popup) - 1);
        }
        return true;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return control == g_refresh || control == g_save;
    }
    if (control == g_refresh) {
        ask_services();
        return true;
    }
    if (control == g_save) {
        if (g_view != NULL && g_view->click != NULL) {
            g_view->click(event, local);
        } else {
            ask_save();
        }
        return true;
    }
    return false;
}

static Boolean cloud_key(const EventRecord *event)
{
    ControlRef focus = NULL;

    if (g_browser == NULL || !g_visible) {
        return false;
    }
    if (GetKeyboardFocus(g_owner, &focus) != noErr || focus != g_browser) {
        return false;
    }
    if (g_view != NULL && g_view->key != NULL
        && g_view->key(event, g_selected)) {
        return true;
    }
    HandleControlKey(g_browser,
                     (SInt16)((event->message & keyCodeMask) >> 8),
                     (char)(event->message & charCodeMask),
                     event->modifiers);
    return true;
}

static void cloud_activate(Boolean active)
{
    if (g_browser == NULL) {
        return;
    }
    if (active) {
        ActivateControl(g_browser);
    } else {
        DeactivateControl(g_browser);
    }
}

static void cloud_idle(void)
{
    Boolean save_on;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    /* The page may have been opened before the connection finished; the
       first ask fires as soon as there is a wire to ask on. One flag
       check per pass, and only until it has happened once. */
    if (!g_asked_once && conn_is_connected()) {
        g_asked_once = true;
        ask_services();
    }
    if (g_view != NULL && g_view->idle != NULL) {
        g_view->idle(&g_r);
    }
    /* Show/hide is the cheap operation that is safe every pass; the
       rectangle repaints only when the answer changed. */
    save_on = action_applies();
    if (save_on != g_shown_save_on) {
        g_shown_save_on = save_on;
        show_control(g_save, g_visible && save_on);
        InvalWindowRect(g_owner, &g_r.save_btn);
    }
    if (strcmp(g_status, g_shown_status) != 0) {
        strcpy(g_shown_status, g_status);
        invalidate_status();
    }
}

static void cloud_status_text(char *out, long cap)
{
    const CloudService *service = current_service();

    /* ALWAYS write: the Workshop hands a stack buffer, and leaving it
       untouched drew a different garbage string every pass — watched
       on the PowerBook. The page's own news outranks the service line,
       because it is where errors land. */
    if (cap < 1) {
        return;
    }
    out[0] = '\0';
    if (g_loading) {
        snprintf(out, (size_t)cap, "Asking...");
    } else if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%.120s", g_status);
    } else if (service != NULL) {
        snprintf(out, (size_t)cap, "%.30s - %.60s", service->label,
                 service->detail[0] != '\0' ? service->detail
                                            : service->state);
    }
}

static const WorkshopModuleOps k_ops = {
    cloud_create,
    cloud_dispose,
    cloud_show,
    cloud_layout,
    cloud_draw,
    cloud_click,
    cloud_key,
    cloud_activate,
    cloud_idle,
    cloud_status_text
};

const WorkshopModuleOps *cloud_module_ops(void)
{
    return &k_ops;
}
