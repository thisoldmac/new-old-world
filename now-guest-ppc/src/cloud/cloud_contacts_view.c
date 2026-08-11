#include "cloud_contacts_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_contacts_card.h"
#include "cloud_filter.h"
#include "cloud_preview_well.h"
#include "control_kind.h"
#include "db_hilite.h"

/* The Contacts card, drawn in the classic Address Book's own shape:
   a photo well top-left (cloud_contacts_card_layout), the name beside
   it in the large system font with the organization under it in the
   small one, then one TITLED GROUP BOX per section -- Phone, Email,
   Address, Other -- each holding its own label/value rows.
   cloud_contacts_card.h decides which row belongs in which box and
   where every box goes; this file only places the controls and draws.
   No Save button: cloud.get on contacts is refused not-listable by
   the contract (x-cloud, contacts), and cloud_module.c's
   action_applies() already knows to keep the button hidden for this
   service, so there is nothing here to click.

   The boxes are a FIXED POOL of four (kCloudContactsMaxSections, the
   whole kind set), created once at view_create and thereafter only
   retitled, moved and shown or hidden. Nothing is created or disposed
   per selection: a contact's section set changes on every click, and
   NewControl/DisposeControl on that seam is a heap churn the PB1400c
   pays for in exactly the redraw storm docs/guest-ui-start-here.md
   warns about. A NULL pool member (NewControl failed) costs that one
   box's FRAME and nothing else -- the rows inside it still draw.

   The rows themselves stay hand-drawn text: they are content, not
   controls, and a static text control per value would be sixteen more
   manager-owned things to damage.

   The LIST is this view's own Data Browser -- see the header for why
   -- built and disposed the way cloud_drive_view.c's own is. */

enum {
    kColName = 'cnnm',
    kColCompany = 'ccmp'
};

static WindowRef g_owner;
static ControlRef g_browser;
static const CloudStore *g_store_ref;
static CloudContactsHost g_host;

/* The group-box pool and what each member currently SHOWS -- the
   change gate. Mutating a manager-owned control repaints it, so a box
   is retitled/moved/shown only when the thing it displays differs
   from what it already displays. */
static ControlRef g_box[kCloudContactsMaxSections];
static const char *g_box_title[kCloudContactsMaxSections];
static Rect g_box_rect[kCloudContactsMaxSections];
static Boolean g_box_on[kCloudContactsMaxSections];

/* The card pane, cached on every layout/select/draw the same
   redundant way g_well_rect is, and the last answer the pool was
   synced against (see sync_boxes). */
static Rect g_pane;
static Boolean g_have_pane;
static Boolean g_shown;
static int g_sel = -1;

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
        /* Hand the shell the INDEX rather than clearing here: the
           Data Browser fires Deselected(old) around Selected(new),
           and only the shell knows whether `item` is still the
           current selection (its own g_selected) -- see the header. */
        if (g_host.row_deselected != NULL) {
            g_host.row_deselected((int)item - 1);
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
    int i;

    /* The Data Browser goes BEFORE its UPPs: disposal fires item
       notifications through them (files_browser_view.c and the
       finding carbon-upp-is-not-a-cast-on-cfm carry the full story). */
    if (g_browser != NULL) {
        now_control_dispose(g_browser);
        g_browser = NULL;
    }
    dispose_callbacks();
    for (i = 0; i < kCloudContactsMaxSections; ++i) {
        if (g_box[i] != NULL) {
            now_control_dispose(g_box[i]);
            g_box[i] = NULL;
        }
        g_box_title[i] = NULL;
        g_box_on[i] = false;
        memset(&g_box_rect[i], 0, sizeof g_box_rect[i]);
    }
    cloud_preview_well_select("contacts", NULL, 0, 0, NULL);
    g_owner = NULL;
    g_store_ref = NULL;
    g_have_well = false;
    g_have_pane = false;
    g_shown = false;
    g_sel = -1;
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

/* Left-aligned, clipped to a column width: inside a group box a value
   that runs past the frame reads as a drawing bug, not as a long
   address. truncEnd rather than truncMiddle -- the front of a street
   address or an email local part is the half worth keeping. */
static void draw_fitted(short x, short y, short width, const char *s)
{
    Str255 t;

    if (width <= 0) {
        return;
    }
    CopyCStringToPascal(s, t);
    TruncString(width, t, truncEnd);
    MoveTo(x, y);
    DrawString(t);
}

/* today's value if it parses as a recognisable long date, rendered
   through LongDateString in the reader's own machine's date format --
   the whole reason cloud_contacts_card.h hands back components rather
   than this file trying to reformat English text itself. False (line
   left undrawn by the caller) if it is not a date this can read. */
static Boolean draw_date_value(short x, short y, short width,
                               const char *value)
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
    if (width <= 0) {
        return true;                   /* recognised, no room to draw */
    }
    TruncString(width, when, truncEnd);
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

/* --- the group-box pool ------------------------------------------------

   One sync per SETTLED answer, not one per event-loop pass: the key
   below is everything a box shows (which contact's card, how many
   rows it has, where the pane is, whether the page is on stage), and
   an unchanged key returns before any geometry is computed at all. On
   a real change each pool member is compared field by field, so a
   card that gains a row does not re-title three boxes that did not
   move. This is the idle-work rule and the manager-owned-control rule
   in one place (docs/guest-ui-start-here.md). */

typedef struct {
    Rect pane;
    char item[64];
    int count;
    int sel;
    Boolean shown;
} BoxKey;

static BoxKey g_key;
static Boolean g_key_valid;

static void sync_boxes(void)
{
    BoxKey key;
    CloudContactsCardLayout cl;
    Boolean changed = false;
    int i;

    if (!g_have_pane) {
        return;
    }
    memset(&key, 0, sizeof key);
    key.pane = g_pane;
    key.shown = g_shown;
    key.sel = g_sel;
    if (g_store_ref != NULL) {
        key.count = g_store_ref->card_count;
        strncpy(key.item, g_store_ref->card_item, sizeof key.item - 1);
    }
    if (g_key_valid && memcmp(&key, &g_key, sizeof key) == 0) {
        return;
    }
    g_key = key;
    g_key_valid = true;

    memset(&cl, 0, sizeof cl);
    if (g_shown && g_sel >= 0 && g_store_ref != NULL) {
        cloud_contacts_card_layout(&g_pane, g_store_ref->card,
                                   g_store_ref->card_count, &cl);
    }
    for (i = 0; i < kCloudContactsMaxSections; ++i) {
        Boolean want = (Boolean)(i < cl.section_count);

        if (g_box[i] == NULL) {
            continue;                  /* this frame is missing; the
                                          rows inside it still draw */
        }
        if (!want) {
            if (g_box_on[i]) {
                HideControl(g_box[i]);
                g_box_on[i] = false;
                changed = true;
            }
            continue;
        }
        if (g_box_title[i] != cl.sections[i].title) {
            Str255 t;

            CopyCStringToPascal(cl.sections[i].title, t);
            SetControlTitle(g_box[i], t);
            g_box_title[i] = cl.sections[i].title;
            changed = true;
        }
        if (!EqualRect(&g_box_rect[i], &cl.sections[i].box)) {
            const Rect *b = &cl.sections[i].box;

            MoveControl(g_box[i], b->left, b->top);
            SizeControl(g_box[i], (SInt16)(b->right - b->left),
                        (SInt16)(b->bottom - b->top));
            g_box_rect[i] = *b;
            changed = true;
        }
        if (!g_box_on[i]) {
            ShowControl(g_box[i]);
            g_box_on[i] = true;
            changed = true;
        }
    }
    /* A box that moved, appeared or vanished disturbed the hand-drawn
       rows around it -- one invalidation of the pane, once, for the
       whole settled change. */
    if (changed && g_owner != NULL) {
        InvalWindowRect(g_owner, &g_pane);
    }
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    CloudContactsCardLayout cl;

    g_pane = r->detail_text;
    g_have_pane = true;
    cloud_contacts_card_layout(&r->detail_text, store->card,
                               store->card_count, &cl);
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
    {
        short name_width = (short)(r->detail_text.right - cl.name_left);

        UseThemeFont(kThemeSystemFont, smSystemScript);
        draw_fitted(cl.name_left, cl.name_baseline, name_width,
                    store->rows[selected].title);
        if (store->rows[selected].subtitle[0] != '\0') {
            /* The organization, one small row under the name -- the
               same field the list's Company column shows, because the
               card and the list must not disagree about it. */
            UseThemeFont(kThemeSmallSystemFont, smSystemScript);
            draw_fitted(cl.name_left, cl.org_baseline, name_width,
                        store->rows[selected].subtitle);
        }
    }

    /* The rows, inside whichever boxes sync_boxes has placed. Nothing
       is drawn for a card that has not arrived: the well and the name
       stand alone rather than under four empty frames. */
    if (cl.section_count > 0) {
        int s, i;

        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        for (s = 0; s < cl.section_count; ++s) {
            const CloudContactsSection *sec = &cl.sections[s];
            short label_x = cloud_contacts_section_label_x(sec);
            short value_x = cloud_contacts_section_value_x(sec);
            short label_w = (short)(value_x - label_x - 4);
            short value_w = (short)(sec->box.right
                                    - kCloudContactsBoxInset - value_x);

            for (i = 0; i < sec->count; ++i) {
                const CloudCardRow *row =
                    &store->card[cl.order[sec->first + i]];
                short y = cloud_contacts_section_baseline(sec, i);
                char value[136];

                draw_fitted(label_x, y, label_w, row->label);
                if (!draw_date_value(value_x, y, value_w, row->value)) {
                    snprintf(value, sizeof value, "%.128s", row->value);
                    draw_fitted(value_x, y, value_w, value);
                }
            }
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

    /* The well and the name are all this seam needs, and the card for
       the NEW selection has not arrived yet either way -- so no rows
       are passed and no sections are computed here. sync_boxes does
       that off g_sel on the next idle pass. */
    cloud_contacts_card_layout(&r->detail_text, NULL, 0, &cl);
    g_pane = r->detail_text;
    g_have_pane = true;
    g_sel = selected;
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
    Rect box_start = { 0, 0, 16, 16 };
    int i;

    g_owner = owner;
    /* The whole pool, once, invisible: the section set changes on
       every selection and creating controls on that seam is what this
       pool exists to avoid. A NULL member here costs one frame; the
       page still renders (the software_module degrade). */
    for (i = 0; i < kCloudContactsMaxSections; ++i) {
        Str255 empty;

        empty[0] = 0;
        g_box[i] = now_control_new(owner, &box_start, empty, false, 0, 0, 1,
                                   kControlGroupBoxTextTitleProc, 0);
        g_box_title[i] = NULL;
        g_box_on[i] = false;
        memset(&g_box_rect[i], 0, sizeof g_box_rect[i]);
    }
    if (CreateDataBrowserControl(owner, &start, kDataBrowserListView,
                                 &g_browser) != noErr) {
        g_browser = NULL;             /* the shell says so; no hard fail */
        return noErr;
    }
    /* The scene's list of this window's controls is what this
       application remembered making, not a FindControl sweep - so a
       browser made by a constructor with no procID still has to be
       recorded, or it goes missing from the mirror. */
    now_control_adopt(owner, g_browser, kNowControlProcDataBrowser);
    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    g_data_upp = NewDataBrowserItemDataUPP(item_data);
    g_notify_upp = NewDataBrowserItemNotificationUPP(item_notify);
    if (g_data_upp == NULL || g_notify_upp == NULL) {
        now_control_dispose(g_browser);
        g_browser = NULL;
        dispose_callbacks();
        return noErr;
    }
    callbacks.u.v1.itemDataCallback = g_data_upp;
    callbacks.u.v1.itemNotificationCallback = g_notify_upp;
    if (SetDataBrowserCallbacks(g_browser, &callbacks) != noErr
        || add_column(kColName, "Name", 130, 0) != noErr
        || add_column(kColCompany, "Company", 100, 1) != noErr) {
        now_control_dispose(g_browser);
        g_browser = NULL;
        dispose_callbacks();
        return noErr;
    }
    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    now_browser_fill_hilite(g_browser);
    HideControl(g_browser);
    return noErr;
}

/* The page went on or off stage. The pool follows it off immediately
   -- a group box left visible over another service's page is chrome
   that page never asked for -- and back on through sync_boxes, which
   is the only thing that knows which of the four belong to the
   contact currently shown. */
static void view_show(Boolean visible)
{
    int i;

    g_shown = visible;
    if (!visible) {
        for (i = 0; i < kCloudContactsMaxSections; ++i) {
            if (g_box[i] != NULL && g_box_on[i]) {
                HideControl(g_box[i]);
                g_box_on[i] = false;
            }
        }
        /* The key still describes the state the pool is now NOT in;
           forget it so the next show re-places every box. */
        g_key_valid = false;
        return;
    }
    sync_boxes();
}

static void view_idle(const CloudLayout *r)
{
    (void)r;                           /* the pane comes from
                                          layout/draw/select, all of
                                          which run before any idle
                                          pass that could matter */
    sync_boxes();
}

static void view_layout(const CloudLayout *r)
{
    CloudContactsCardLayout cl;

    cloud_contacts_card_layout(&r->detail_text, NULL, 0, &cl);
    g_pane = r->detail_text;
    g_have_pane = true;
    g_well_rect = cl.well;
    g_have_well = true;
    sync_boxes();                      /* a grow moves every box; the
                                          key's pane field is what
                                          says so */
    if (g_browser == NULL) {
        return;
    }
    MoveControl(g_browser, r->list.left, r->list.top);
    SizeControl(g_browser, (SInt16)(r->list.right - r->list.left),
                (SInt16)(r->list.bottom - r->list.top));
}

static const CloudViewOps k_ops = {
    view_create,
    view_show,                         /* the shell owns which BROWSER
                                          is on stage; the section
                                          boxes are this view's own */
    view_layout,
    view_draw,
    NULL,                              /* click: no button is ever shown */
    NULL,                              /* key: generic HandleControlKey */
    view_idle,                         /* the section boxes, change-gated */
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
