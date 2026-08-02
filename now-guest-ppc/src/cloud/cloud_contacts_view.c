#include "cloud_contacts_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_contacts_card.h"
#include "cloud_filter.h"
#include "cloud_preview_well.h"
#include "db_hilite.h"

/* The Contacts card, drawn in the classic Address Book's own shape:
   a photo well top-left (cloud_contacts_card_layout), the name beside
   it in the large system font, then a right-aligned label column,
   values starting at a fixed left margin, phone rows grouped together
   and email rows grouped after them (cloud_contacts_card.h decides
   which is which and in what order -- this file only draws). No Save
   button: cloud.get on contacts is refused not-listable by the
   contract (x-cloud, contacts), and cloud_module.c's action_applies()
   already knows to keep the button hidden for this service, so there
   is nothing here to click.

   The LIST is this view's own Data Browser -- see the header for why
   -- built and disposed the way cloud_drive_view.c's own is. */

enum {
    kLabelColWidth = 72,       /* label column width, right edge to text */
    kColGap = 10,              /* between the label column and values */
    kRowHeight = 14,
    kGroupGap = 8,             /* extra space where the row kind changes */

    kColName = 'cnnm',
    kColCompany = 'ccmp'
};

static WindowRef g_owner;
static ControlRef g_browser;
static const CloudStore *g_store_ref;
static CloudContactsHost g_host;

/* Where the well last drew -- cached on every layout/select/draw the
   same redundant way cloud_photos_view.c caches its pane, so whichever
   of those ran most recently is what a late well settlement
   invalidates (draw() can run before layout() on a fresh page, the
   same comment photos' view_draw carries). */
static Rect g_well_rect;
static Boolean g_have_well;

/* --- the list: own control, own UPPs, reading the shell's store ------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const CloudRow *row;
    CFStringRef text = NULL;

    (void)browser;
    if (changeValue || g_store_ref == NULL || item < 1
        || item > (DataBrowserItemID)g_store_ref->row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_store_ref->rows[item - 1];
    switch (property) {
    case kColName:
        text = CFStringCreateWithCString(NULL, row->title,
                                         kCFStringEncodingMacRoman);
        break;
    case kColCompany:
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
    /* A rebuild's own Remove/Add fires notifications nobody asked
       for; the shell's identical guard on its own browser is the
       reason this one exists (see the header). */
    if (g_host.in_rebuild != NULL && g_host.in_rebuild()) {
        return;
    }
    if (message == kDataBrowserItemSelected) {
        if (g_host.row_selected != NULL) {
            g_host.row_selected((int)item - 1);
        }
    } else if (message == kDataBrowserItemDeselected) {
        if (g_host.row_selected != NULL) {
            g_host.row_selected(-1);
        }
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
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn;
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

void cloud_contacts_view_bind(const CloudContactsHost *host,
                              const CloudStore *store)
{
    if (host != NULL) {
        g_host = *host;
    } else {
        memset(&g_host, 0, sizeof g_host);
    }
    g_store_ref = store;
}

ControlRef cloud_contacts_view_browser(void)
{
    return g_browser;
}

void cloud_contacts_view_dispose(void)
{
    /* The Data Browser goes BEFORE its UPPs: disposal fires item
       notifications through them (files_browser_view.c and the
       finding carbon-upp-is-not-a-cast-on-cfm carry the full story). */
    if (g_browser != NULL) {
        DisposeControl(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    cloud_preview_well_select("contacts", NULL, 0, 0, NULL);
    g_owner = NULL;
    g_store_ref = NULL;
    g_have_well = false;
    memset(&g_host, 0, sizeof g_host);
}

/* --- the card's furniture: well, name, rows ---------------------------- */

static void draw_left(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

/* Right-aligned so the label column reads the way the classic Address
   Book's card does: "   home:" ending flush above "   work:". */
static void draw_label(short right_edge, short y, const char *label)
{
    Str255 t;
    short w;

    CopyCStringToPascal(label, t);
    w = StringWidth(t);
    MoveTo((short)(right_edge - w), y);
    DrawString(t);
}

/* today's value if it parses as a recognisable long date, rendered
   through LongDateString in the reader's own machine's date format --
   the whole reason cloud_contacts_card.h hands back components rather
   than this file trying to reformat English text itself. False (line
   left undrawn by the caller) if it is not a date this can read. */
static Boolean draw_date_value(short x, short y, const char *value)
{
    int year, month, day;
    LongDateRec rec;
    LongDateTime ldt;
    Str255 when;

    if (!cloud_contacts_parse_long_date(value, &year, &month, &day)) {
        return false;
    }
    memset(&rec, 0, sizeof rec);
    rec.ld.era = 0;
    rec.ld.year = (short)year;
    rec.ld.month = (short)month;
    rec.ld.day = (short)day;
    rec.ld.hour = 0;
    rec.ld.minute = 0;
    rec.ld.second = 0;
    rec.ld.dayOfWeek = 1;      /* LongDateToSeconds derives the real one */
    LongDateToSeconds(&rec, &ldt);
    LongDateString(&ldt, longDate, when, NULL);
    MoveTo(x, y);
    DrawString(when);
    return true;
}

/* A generic person silhouette, hand-drawn in gray: a head and
   shoulders inside the well, clipped to it so a small well never
   bleeds a stray pixel past its frame. Drawn guest-side rather than as
   a resource because a resource's pixels cannot be proven by a host-cc
   test the way this function's geometry can be read by eye in the
   source -- the same reasoning that keeps the rest of this page's
   furniture hand-drawn QuickDraw rather than PICTs. */
static void draw_person_silhouette(const Rect *well)
{
    RGBColor gray = { 0x9999, 0x9999, 0x9999 };
    RGBColor black = { 0, 0, 0 };
    RgnHandle saved_clip;
    Rect r = *well;
    Rect head, body;
    short w, h;

    InsetRect(&r, 2, 2);
    if (r.right <= r.left || r.bottom <= r.top) {
        return;
    }
    saved_clip = NewRgn();
    if (saved_clip != NULL) {
        GetClip(saved_clip);
        ClipRect(&r);
    }
    EraseRect(&r);
    w = (short)(r.right - r.left);
    h = (short)(r.bottom - r.top);
    RGBForeColor(&gray);
    /* The head: a circle in the well's upper third. */
    SetRect(&head, (short)(r.left + w / 3), (short)(r.top + h / 8),
            (short)(r.right - w / 3), (short)(r.top + h / 8 + h / 3));
    PaintOval(&head);
    /* The shoulders: a wide oval rising from the bottom edge, its top
       half clipped away by the well itself. */
    SetRect(&body, (short)(r.left + w / 8), (short)(r.bottom - h / 3),
            (short)(r.right - w / 8), (short)(r.bottom + h / 4));
    PaintOval(&body);
    RGBForeColor(&black);
    if (saved_clip != NULL) {
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
    }
}

/* The well's settle callback: rebound on every select() call, so this
   fires only for an ask THIS view still cares about (cloud_preview_
   well.c's whole reason for rebinding — cloud_photos_view.c's
   note_changed carries the same one-line body). */
static void note_changed(void)
{
    if (g_owner != NULL && g_have_well) {
        InvalWindowRect(g_owner, &g_well_rect);
    }
}

static void draw_well(const Rect *well, const char *item)
{
    FrameRect(well);
    if (item[0] != '\0' && cloud_preview_well_ready("contacts", item)) {
        cloud_preview_well_draw(g_owner, well);
        return;
    }
    /* Loading, refused (most contacts: "no photo" -- x-cloud,
       contacts), or nothing asked yet -- all three read the same way
       to a person looking at the well: there is no picture to show
       right now. */
    draw_person_silhouette(well);
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    CloudContactsCardLayout cl;

    cloud_contacts_card_layout(&r->detail_text, &cl);
    g_well_rect = cl.well;
    g_have_well = true;

    if (service != NULL && strcmp(service->state, "serving") != 0) {
        short y = (short)(r->detail_text.top + 12);

        draw_left(r->detail_text.left, y, service->label);
        if (service->detail[0] != '\0') {
            draw_left(r->detail_text.left, (short)(y + 16),
                      service->detail);
        }
        return;
    }
    if (selected < 0 || selected >= store->row_count) {
        if (store->row_count > 0) {
            draw_left(r->detail_text.left,
                      (short)(r->detail_text.top + 12),
                      "Select a name to see its card.");
        }
        return;
    }

    /* The well and the name draw as soon as a row is selected --
       cloud.preview and cloud.card are two independent asks (the
       shell's ask_card and this view's own select op, below), so the
       photo need not wait for the card rows to arrive or vice versa. */
    draw_well(&cl.well, store->rows[selected].item);
    UseThemeFont(kThemeSystemFont, smSystemScript);
    draw_left(cl.name_left, cl.name_baseline, store->rows[selected].title);

    if (store->card_count > 0) {
        short label_right = (short)(r->detail_text.left + kLabelColWidth);
        short value_left = (short)(label_right + kColGap);
        short y = cl.rows_top;
        int order[kCloudMaxCardRows];
        int n, i;
        CloudContactsRowKind last_kind = kCloudContactsRowOther;
        Boolean first = true;

        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        n = cloud_contacts_order_card(store->card, store->card_count, order);
        for (i = 0; i < n && y < r->detail_text.bottom; ++i) {
            const CloudCardRow *row = &store->card[order[i]];
            CloudContactsRowKind kind = cloud_contacts_classify_row(row);
            char value[136];

            if (!first && kind != last_kind) {
                y = (short)(y + kGroupGap);
                if (y >= r->detail_text.bottom) {
                    break;
                }
            }
            first = false;
            last_kind = kind;

            draw_label(label_right, y, row->label);
            if (!draw_date_value(value_left, y, row->value)) {
                snprintf(value, sizeof value, "%.128s", row->value);
                draw_left(value_left, y, value);
            }
            y = (short)(y + kRowHeight);
        }
    }
}

/* --- selection: the shell's ask_card runs off row_selected, above;
   this view's own reaction is the preview well ask --------------------- */

static void view_select(const CloudLayout *r, const CloudStore *store,
                        int selected)
{
    CloudContactsCardLayout cl;
    long ww, wh;

    cloud_contacts_card_layout(&r->detail_text, &cl);
    g_well_rect = cl.well;
    g_have_well = true;
    ww = cl.well.right - cl.well.left;
    wh = cl.well.bottom - cl.well.top;
    if (selected >= 0 && selected < store->row_count
        && store->rows[selected].item[0] != '\0') {
        cloud_preview_well_select("contacts", store->rows[selected].item,
                                  ww, wh, note_changed);
    } else {
        cloud_preview_well_select("contacts", NULL, 0, 0, NULL);
    }
    note_changed();                   /* the switch itself may need to
                                          replace a stale well (a fresh
                                          selection whose photo has not
                                          arrived yet must clear
                                          whatever the last one drew) */
}

/* The name list is the shell's shared rows too (title = display name,
   subtitle = whatever the host chose to show under it) — same
   predicate cloud_list_view.c uses, same reason: the two fields the
   Data Browser already shows. */
static Boolean view_row_matches(int index, const CloudStore *store,
                                const char *needle)
{
    const CloudRow *row;

    if (store == NULL || index < 0 || index >= store->row_count) {
        return false;
    }
    row = &store->rows[index];
    return cloud_filter_matches_either(row->title, row->subtitle, needle);
}

/* --- ops ---------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    DataBrowserCallbacks callbacks;
    Rect start = { 0, 0, 0, 0 };      /* layout() places it before it
                                         is ever shown */

    g_owner = owner;
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
    add_column(kColName, "Name", 130, 0);
    add_column(kColCompany, "Company", 100, 1);
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    now_browser_fill_hilite(g_browser);
    HideControl(g_browser);
    return noErr;
}

static void view_layout(const CloudLayout *r)
{
    CloudContactsCardLayout cl;

    cloud_contacts_card_layout(&r->detail_text, &cl);
    g_well_rect = cl.well;
    g_have_well = true;
    if (g_browser == NULL) {
        return;
    }
    MoveControl(g_browser, r->list.left, r->list.top);
    SizeControl(g_browser, (SInt16)(r->list.right - r->list.left),
                (SInt16)(r->list.bottom - r->list.top));
}

static const CloudViewOps k_ops = {
    view_create,
    NULL,                              /* show: the shell owns which
                                          browser is on stage */
    view_layout,
    view_draw,
    NULL,                              /* click: no button is ever shown */
    NULL,                              /* key: generic HandleControlKey */
    NULL,                              /* idle: nothing to watch */
    NULL,                              /* reset_for_service: ask_rows(1) */
    view_row_matches,
    view_select,
    NULL,                              /* control_click: no own controls */
    NULL                               /* save_size: host default */
};

const CloudViewOps *cloud_contacts_view_ops(void)
{
    return &k_ops;
}
