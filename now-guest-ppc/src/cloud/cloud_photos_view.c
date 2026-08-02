#include "cloud_photos_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "cloud_list_view.h"
#include "cloud_photo_size.h"
#include "cloud_preview_well.h"
#include "db_hilite.h"
#include "fileshare.h"
#include "pump.h"
#include "wire.h"

/* The photos view: cloud_list_view's card render until pixels arrive,
   then the pixels. The wire half (one pending ask, the bulk transfer,
   the settled one-shot delivery) lives in wire.c behind
   conn_set_cloud_preview_note; the pure decisions (ask depth, begin
   validation, pane fit) in cloud_preview.c where the host cc tests
   them. The GWorld, the fetch bookkeeping and the CopyBits landing
   live in cloud_preview_well.c, shared with the Contacts card's photo
   well — extracted from here (2026-08-02) so two views asking for a
   cloud.preview do not each keep their own bitmap on a 6MB partition,
   and do not each reinvent "only one ask in flight" on top of the
   wire's own rule that a second one is refused outright. This file
   owns the pane rectangle and asks the well on every selection change.

   Batching rule, kept on both edges: the preview arrives as ONE
   delivery (wire.c calls the hook once, on preview.end) and lands as
   ONE invalidation of the pane — nothing here repaints per bulk
   frame, because nothing here ever sees a bulk frame.

   The download furniture (2026-08-02) is this view's own: the Size
   pop-up (MENU 136, the services-popup recipe) that puts a token on
   the shell's cloud.get; the destination row — where a saved photo
   lands, shown always, changed by Choose... through the shared
   NavChooseFolder door and registered with the wire, which redirects
   the answering offer only (no contract change; wire.c's comment
   carries the sovereignty reasoning); and the download's moving bar
   and byte count, read every idle pass from the wire's own receive
   counters and repainted only when the shown value changes — the
   share panel's bar discipline, one lane over.

   The columns (2026-08-02) are this view's own Data Browser -- Name,
   Size (the entry's bytes when the host stated them, "--" when it did
   not; docs/icloud.md says why photos rows carry no size), Modified
   (LongDateString) -- occupying the same g_r.list rect the shell's
   shared two-column browser used to draw into, for the same reason
   Drive's does: RemoveDataBrowserTableViewColumn is not among the 22
   symbols spikes/databrowser proved exported on the PB1400c, so one
   control cannot wear two column sets. Unlike Drive this view keeps
   no row storage of its own -- its item_data reads the shell's shared
   CloudStore through the pointer CloudPhotosHost hands over once, and
   its selection notification is the SHELL's own UPP, reused verbatim,
   because these rows are (and must stay) the same store Save and the
   live search already index by the same 0-based-index/DataBrowserItemID
   convention. */

static WindowRef g_owner;
static Rect g_pane;                   /* photos_text: where pixels go */
static Boolean g_have_pane;
static Boolean g_shown;               /* page visible AND photos active */

/* The view's own controls: built invisible at page create, shown only
   while this view is the active one, moved by view_layout. The window
   owns their disposal (workshop rule); dispose only nulls the refs. */
static ControlRef g_size_popup;
static ControlRef g_dest_btn;
static ControlRef g_dl_bar;

/* This view's own Data Browser: Name/Size/Modified, occupying the
   list rect the shell's shared two-column browser otherwise would
   (see the file header). g_pbrowser_data_upp is owned here; the
   notification UPP is the shell's own, handed over at bind time and
   NOT disposed here. */
static ControlRef g_pbrowser;
static DataBrowserItemDataUPP g_pbrowser_data_upp;
static CloudPhotosHost g_host;

enum {
    kColName = 'name',
    kColSize = 'size',
    kColModified = 'modf'
};

enum {
    kCloudSizeMenuID = 136,
    kCloudSizeHostDefaultItem = 4,

    /* fitN box sizes (contract's CloudGet.size, docs/icloud.md): the
       ones MENU 136 offers today. Load-bearing alongside the menu's
       item order — item 2 is fit1024, item 3 is fit640. */
    kFit1024W = 1024, kFit1024H = 768,
    kFit640W = 640, kFit640H = 480
};

/* The chosen destination. Unset means the share root — the wire is
   told nothing and behavior is byte-identical to before the chooser
   existed. The label is recomputed only on create/show/choose, never
   on the idle path (now_files_root_name reads preferences, and idle
   work must be free). */
static Boolean g_dest_set;
static short g_dest_vref;
static long g_dest_dir;
static char g_dest_path[160];         /* full display path, truncated
                                         to the row at draw time */

/* Idle caches: the bar and its byte line repaint only on change. */
static Boolean g_bar_shown;
static short g_bar_value = -1;
static char g_dl_line[48];
static Rect g_dl_text_rect;           /* where the byte line last drew */

/* --- this view's own Data Browser: Name/Size/Modified ------------------- */

static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const CloudRow *row;
    CFStringRef text = NULL;
    char buf[64];

    (void)browser;
    if (changeValue || g_host.store == NULL || item < 1
        || item > (DataBrowserItemID)g_host.store->row_count) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &g_host.store->rows[item - 1];
    switch (property) {
    case kColName:
        text = CFStringCreateWithCString(NULL, row->title,
                                         kCFStringEncodingMacRoman);
        break;
    case kColSize:
        /* Photos rows never state bytes (docs/icloud.md: PHAssetResource
           has no public size property short of downloading the asset,
           which a listing must not do) — "--" is the honest answer,
           never an invented one. */
        if (row->bytes <= 0) {
            strcpy(buf, "--");
        } else if (row->bytes < 1024) {
            snprintf(buf, sizeof buf, "%ld bytes", row->bytes);
        } else if (row->bytes < 1024L * 1024L) {
            snprintf(buf, sizeof buf, "%ld K", row->bytes / 1024);
        } else {
            snprintf(buf, sizeof buf, "%ld.%ld MB",
                     row->bytes / (1024L * 1024L),
                     (row->bytes % (1024L * 1024L)) / (105L * 1024L));
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
               2^31 in 1972 through the signed API
               (classic-datestring-clamps-past-1972). */
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

static OSStatus add_column(DataBrowserPropertyID id, const char *title,
                           UInt16 width,
                           DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn
        | (id == kColName ? kDataBrowserListViewSelectionColumn : 0);
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.titleOffset = 0;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnFontStyle.flags = 0;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(g_pbrowser, &col, at);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    if (err == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(g_pbrowser, id, width);
    }
    return err;
}

ControlRef cloud_photos_view_browser(void)
{
    return g_pbrowser;
}

void cloud_photos_view_bind(const CloudPhotosHost *host)
{
    if (host != NULL) {
        g_host = *host;
    } else {
        memset(&g_host, 0, sizeof g_host);
    }
}

/* --- the Size popup's per-selection labels ------------------------------ */

static MenuRef size_menu(void)
{
    MenuRef menu = NULL;
    Size got = 0;

    /* Same GetControlData-then-GetMenuHandle fallback as the shell's
       services popup (cloud_module.c's popup_menu): the classic
       popupMenuProc CDEF puts the menu in the hierarchical list, which
       is where GetControlData finds it under CarbonLib; GetMenuHandle
       is the fallback for older paths. */
    if (g_size_popup != NULL
        && GetControlData(g_size_popup, kControlEntireControl,
                          kControlPopupButtonMenuHandleTag,
                          sizeof menu, (Ptr)&menu, &got) == noErr
        && got == (Size)sizeof menu && menu != NULL) {
        return menu;
    }
    return GetMenuHandle(kCloudSizeMenuID);
}

static void set_item(MenuRef menu, short item, const char *text)
{
    Str255 s;

    CopyCStringToPascal(text, s);
    SetMenuItemText(menu, item, s);
}

/* Rebuilds items 1-3 for the given entry's stated width/height (both 0
   = unstated): the real resolution for Original, and each fitN box's
   computed result (cloud_photo_fit — aspect-preserving, never
   upscaling: a photo already smaller than a box shows its own size).
   Falls back to the literal fit-box wording — MENU 136's own resource
   text — when there is nothing to compute, which covers both "no
   selection" and "this entry never stated its dimensions". Item 4
   (Host default) never changes. */
static void rebuild_size_menu(long width, long height)
{
    MenuRef menu = size_menu();
    char buf[32];
    long fw, fh;

    if (menu == NULL) {
        return;
    }
    if (width <= 0 || height <= 0) {
        set_item(menu, 1, "Original");
        set_item(menu, 2, "Fit 1024x768");
        set_item(menu, 3, "Fit 640x480");
        return;
    }
    snprintf(buf, sizeof buf, "%ld x %ld", width, height);
    set_item(menu, 1, buf);
    cloud_photo_fit(width, height, kFit1024W, kFit1024H, &fw, &fh);
    snprintf(buf, sizeof buf, "%ld x %ld", fw, fh);
    set_item(menu, 2, buf);
    cloud_photo_fit(width, height, kFit640W, kFit640H, &fw, &fh);
    snprintf(buf, sizeof buf, "%ld x %ld", fw, fh);
    set_item(menu, 3, buf);
}

static void invalidate_pane(void)
{
    if (g_owner != NULL && g_have_pane
        && g_pane.right > g_pane.left && g_pane.bottom > g_pane.top) {
        InvalWindowRect(g_owner, &g_pane);
    }
}

/* The well's settle callback: rebound on every selection change, so
   this fires only for an ask THIS view still cares about (an outgoing
   selection's late answer notifies whichever view asked next, not
   this one — cloud_preview_well.c's whole reason for rebinding). */
static void note_changed(void)
{
    invalidate_pane();
}

/* --- the destination ---------------------------------------------------- */

/* Recomputes the label from whichever folder a save would actually
   land in. Reads preferences (the share root) or climbs the catalog,
   so it runs on create/show/choose only — never from idle. */
static void refresh_dest_path(void)
{
    if (g_dest_set) {
        if (now_files_dir_path(g_dest_vref, g_dest_dir, g_dest_path,
                               sizeof g_dest_path)) {
            return;
        }
        /* The folder stopped being nameable (volume gone?): fall back
           to the share, which is also where the offer would land now. */
        g_dest_set = false;
        now_wire_cloud_get_destination(false, 0, 0);
    }
    now_files_root_name(g_dest_path, sizeof g_dest_path);
}

static void choose_dest(void)
{
    char why[128];
    short vref;
    long dir;
    short root_vref;
    long root_dir;
    int rc;

    rc = now_files_choose_folder("Choose where saved photos land",
                                 &vref, &dir, why, sizeof why);
    if (rc == 0) {
        return;                       /* cancelled: nothing changes */
    }
    if (rc < 0) {
        /* The why draws where the destination draws — it is about the
           destination — and the next choose or page show replaces it. */
        snprintf(g_dest_path, sizeof g_dest_path, "%.120s", why);
        if (g_owner != NULL && g_shown) {
            InvalWindowRect(g_owner, &g_dl_text_rect);
        }
        return;
    }
    /* Choosing the share root clears the override rather than setting
       an equal one: unset is the wire's "land in the share" and keeps
       that path byte-identical to before the chooser existed. */
    if (now_files_share_root(&root_vref, &root_dir) == kFilesOK
        && root_vref == vref && root_dir == dir) {
        g_dest_set = false;
        now_wire_cloud_get_destination(false, 0, 0);
    } else {
        g_dest_set = true;
        g_dest_vref = vref;
        g_dest_dir = dir;
        now_wire_cloud_get_destination(true, vref, dir);
    }
    refresh_dest_path();
}

/* --- ops ---------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    Rect seed;
    Str255 text;
    DataBrowserCallbacks callbacks;

    g_owner = owner;
    /* The wire's ONE cloud.preview hook is registered once, for the
       shared well, from cloud_create() (cloud_preview_well_init) — not
       per view, since only one hook can ever be live. */
    g_dest_set = false;
    now_wire_cloud_get_destination(false, 0, 0);
    refresh_dest_path();
    g_bar_shown = false;
    g_bar_value = -1;
    g_dl_line[0] = '\0';
    SetRect(&g_dl_text_rect, 0, 0, 0, 0);

    /* Built invisible against a seed rect; view_layout places them
       when this view first goes on stage (the drive browser's rule:
       stale geometry hidden is fine, stale geometry shown never
       happens because layout runs before show). */
    SetRect(&seed, 0, 0, 10, 10);
    text[0] = 0;
    g_size_popup = NewControl(owner, &seed, text, false,
                              popupTitleLeftJust, kCloudSizeMenuID, 0,
                              popupMenuProc, 0);
    if (g_size_popup != NULL) {
        SetControlMaximum(g_size_popup, kCloudSizeHostDefaultItem);
        SetControlValue(g_size_popup, kCloudSizeHostDefaultItem);
    }
    CopyCStringToPascal("Choose...", text);
    g_dest_btn = NewControl(owner, &seed, text, false, 0, 0, 1,
                            pushButProc, 0);
    /* Native determinate bar, the share panel's recipe verbatim
       (metal-verified there): scaled 0..1000 by cloud_dl_bar_value. */
    text[0] = 0;
    g_dl_bar = NewControl(owner, &seed, text, false, 0, 0, 1000,
                          kControlProgressBarProc, 0);
    /* A missing control degrades that control, not the page: the ask
       still works at the host default, a save still lands in the
       share, the byte line still draws. */

    /* This view's own Data Browser (see the file header): built the
       same defensive way Drive's is — a failure here degrades this
       control alone, never the page. Needs g_host.notify_upp already
       bound (cloud_photos_view_bind, called by cloud_create before
       this op). */
    if (CreateDataBrowserControl(owner, &seed, kDataBrowserListView,
                                 &g_pbrowser) != noErr) {
        g_pbrowser = NULL;
    } else {
        g_pbrowser_data_upp = NewDataBrowserItemDataUPP(item_data);
        if (g_pbrowser_data_upp == NULL || g_host.notify_upp == NULL) {
            if (g_pbrowser_data_upp != NULL) {
                DisposeDataBrowserItemDataUPP(g_pbrowser_data_upp);
                g_pbrowser_data_upp = NULL;
            }
            DisposeControl(g_pbrowser);
            g_pbrowser = NULL;
        } else {
            memset(&callbacks, 0, sizeof callbacks);
            callbacks.version = kDataBrowserLatestCallbacks;
            InitDataBrowserCallbacks(&callbacks);
            callbacks.u.v1.itemDataCallback = g_pbrowser_data_upp;
            callbacks.u.v1.itemNotificationCallback = g_host.notify_upp;
            SetDataBrowserCallbacks(g_pbrowser, &callbacks);
            add_column(kColName, "Name", 160, 0);
            add_column(kColSize, "Size", 64, 1);
            add_column(kColModified, "Modified", 90, 2);
            SetDataBrowserListViewHeaderBtnHeight(g_pbrowser, 16);
            SetDataBrowserHasScrollBars(g_pbrowser, false, true);
            now_browser_fill_hilite(g_pbrowser);
            SetDataBrowserSortProperty(g_pbrowser, kColName);
            HideControl(g_pbrowser);
        }
    }
    return noErr;
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

static void view_show(Boolean visible)
{
    g_shown = visible;
    show_control(g_size_popup, visible);
    show_control(g_dest_btn, visible);
    show_control(g_dl_bar, visible && g_bar_shown);
    if (visible) {
        /* The share root may have moved while another page had the
           stage; one preferences read on a show is not idle work. */
        refresh_dest_path();
    }
}

static void view_layout(const CloudLayout *r)
{
    g_pane = r->photos_text;
    g_have_pane = true;
    g_dl_text_rect = r->dl_text;
    if (g_size_popup != NULL) {
        MoveControl(g_size_popup, r->size_popup.left, r->size_popup.top);
        SizeControl(g_size_popup,
                    (SInt16)(r->size_popup.right - r->size_popup.left),
                    (SInt16)(r->size_popup.bottom - r->size_popup.top));
    }
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
    /* r->list is exactly the rect the shell's shared browser used to
       occupy in list mode (this view never turns on drive_mode's
       full-width layout) — same geometry, different control. */
    if (g_pbrowser != NULL) {
        MoveControl(g_pbrowser, r->list.left, r->list.top);
        SizeControl(g_pbrowser, (SInt16)(r->list.right - r->list.left),
                    (SInt16)(r->list.bottom - r->list.top));
    }
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

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    const char *item = (selected >= 0 && selected < store->row_count)
        ? store->rows[selected].item : "";

    /* draw() may run before layout() on a fresh page; the layout the
       shell passes is current either way. */
    g_pane = r->photos_text;
    g_have_pane = true;
    g_dl_text_rect = r->dl_text;

    /* The view's own furniture rows: where a save lands, and — while
       bytes move — how far they have got. The bar draws itself. */
    draw_small_line(&r->dest_row, "Save into: ", g_dest_path, true);
    if (g_dl_line[0] != '\0') {
        draw_small_line(&r->dl_text, "", g_dl_line, false);
    }

    if (selected >= 0 && item[0] != '\0'
        && cloud_preview_well_ready("photos", item)) {
        cloud_preview_well_draw(g_owner, &g_pane);
        return;                       /* the preview replaces the card */
    }
    if (selected >= 0 && item[0] != '\0'
        && cloud_preview_well_fetching("photos", item)) {
        /* Between the ask and the pixels the pane says so — drawn
           state, not a repaint loop: the transition into fetching and
           the settled answer each invalidate exactly once. */
        Str255 text;

        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        MoveTo((short)(g_pane.left), (short)(g_pane.top + 12));
        CopyCStringToPascal("Loading preview...", text);
        DrawString(text);
        return;
    }
    if (selected >= 0 && item[0] != '\0') {
        const char *fail = cloud_preview_well_fail("photos", item);

        if (fail[0] != '\0') {
            Str255 text;

            /* The why REPLACES the card: both start at the pane's
               first line, and two texts on one baseline is mush. The
               card comes back with the next selection or preview. */
            UseThemeFont(kThemeSmallSystemFont, smSystemScript);
            MoveTo((short)(g_pane.left), (short)(g_pane.top + 12));
            CopyCStringToPascal(fail, text);
            DrawString(text);
            return;
        }
    }
    {
        /* The generic card draws into the photos pane, not the full
           detail_text: the furniture rows below are live controls and
           card text under a control is the overlap nothing repaints. */
        CloudLayout card_r = *r;

        card_r.detail_text = r->photos_text;
        cloud_list_view_draw_card(&card_r, store, service, selected);
    }
}

static Boolean view_control_click(ControlRef control,
                                  const EventRecord *event, Point local)
{
    (void)event;
    if (control != NULL && control == g_size_popup) {
        /* Popup CDEFs run their own action; -1L is the documented
           value (nested-loops.md carries the menu-loop caveat). The
           value is read at Save time; nothing to do on the pick. */
        TrackControl(control, local, (ControlActionUPP)-1L);
        return true;
    }
    if (control != NULL && control == g_dest_btn) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            choose_dest();
            if (g_owner != NULL && g_shown) {
                /* One row changed; repaint it, not the pane. */
                InvalWindowRect(g_owner, &g_dl_text_rect);
            }
        }
        return true;
    }
    return false;
}

/* The token the shell's cloud.get carries: the popup's current pick
   through cloud_model's item map, NULL (omit the field, host default)
   when the popup never got built. */
static const char *view_save_size(void)
{
    if (g_size_popup == NULL) {
        return NULL;
    }
    return cloud_size_token(GetControlValue(g_size_popup));
}

/* Every pass while photos is on stage: two in-memory reads, control
   and pixel updates only when a shown value actually changed — the
   share panel's idle discipline, one lane over. */
static void view_idle(const CloudLayout *r)
{
    long received = 0, expected = 0;
    Boolean from_get = false;
    Boolean moving = false;
    char line[48];
    int value = -1;

    if (now_wire_receive_active(&received, &expected, &from_get,
                                NULL, 0)
        && from_get) {
        value = cloud_dl_bar_value(received, expected);
        moving = value >= 0;
        cloud_dl_bytes_line(received, expected, line, sizeof line);
    } else {
        line[0] = '\0';
    }
    if (moving != g_bar_shown) {
        g_bar_shown = moving;
        show_control(g_dl_bar, g_shown && moving);
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
        if (g_owner != NULL && g_shown) {
            Rect row = r->dl_text;

            InvalWindowRect(g_owner, &row);
        }
    }
}

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

static void view_select(const CloudLayout *r, const CloudStore *store,
                        int selected)
{
    long ww, wh;

    g_pane = r->photos_text;
    g_have_pane = true;
    ww = g_pane.right - g_pane.left;
    wh = g_pane.bottom - g_pane.top;
    /* Every selection change asks the well to evict whatever it held:
       one preview in memory, never yesterday's photo behind today's
       card — the well's own rule now, kept for both views. */
    if (selected >= 0 && selected < store->row_count
        && store->rows[selected].item[0] != '\0') {
        cloud_preview_well_select("photos", store->rows[selected].item,
                                  ww, wh, note_changed);
        rebuild_size_menu(store->rows[selected].width,
                          store->rows[selected].height);
    } else {
        cloud_preview_well_select("photos", NULL, 0, 0, NULL);
        rebuild_size_menu(0, 0);
    }
    invalidate_pane();
}

static const CloudViewOps k_ops = {
    view_create,
    view_show,
    view_layout,
    view_draw,
    NULL,                              /* click: the shell's ask_save() */
    NULL,                              /* key: generic HandleControlKey */
    view_idle,
    NULL,                              /* reset_for_service: ask_rows(1) */
    view_row_matches,
    view_select,
    view_control_click,
    view_save_size
};

const CloudViewOps *cloud_photos_view_ops(void)
{
    return &k_ops;
}

void cloud_photos_view_dispose(void)
{
    /* The well itself is a separate object with its own dispose
       (cloud_preview_well_dispose, called from cloud_dispose): this
       view only stops asking it, which _select(NULL) already does. */
    cloud_preview_well_select("photos", NULL, 0, 0, NULL);
    now_wire_cloud_get_destination(false, 0, 0);
    g_owner = NULL;
    g_have_pane = false;
    g_shown = false;
    g_dest_set = false;
    /* The window owns g_size_popup/g_dest_btn/g_dl_bar's disposal; only
       their refs die here (docs/adding-a-workshop-module.md, what you
       own and what you do not). g_pbrowser is different, the same way
       Drive's browser is: it owns an item-data UPP of its own, so it
       must go BEFORE that UPP rather than wait for DisposeWindow — the
       control's own disposal fires item notifications through it
       (files_browser_view.c's dispose order,
       carbon-upp-is-not-a-cast-on-cfm). The shared notify_upp
       (g_host.notify_upp) still fires safely here too: cloud_module.c
       disposes it only after this call returns. */
    if (g_pbrowser != NULL) {
        DisposeControl(g_pbrowser);
        g_pbrowser = NULL;
    }
    if (g_pbrowser_data_upp != NULL) {
        DisposeDataBrowserItemDataUPP(g_pbrowser_data_upp);
        g_pbrowser_data_upp = NULL;
    }
    memset(&g_host, 0, sizeof g_host);
    g_size_popup = NULL;
    g_dest_btn = NULL;
    g_dl_bar = NULL;
    g_bar_shown = false;
    g_bar_value = -1;
    g_dl_line[0] = '\0';
}
