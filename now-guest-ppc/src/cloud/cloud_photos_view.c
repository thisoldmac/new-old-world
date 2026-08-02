#include "cloud_photos_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "cloud_list_view.h"
#include "cloud_preview.h"
#include "fileshare.h"
#include "pump.h"
#include "wire.h"

/* The photos view: cloud_list_view's card render until pixels arrive,
   then the pixels. The wire half (one pending ask, the bulk transfer,
   the settled one-shot delivery) lives in wire.c behind
   conn_set_cloud_preview_note; the pure decisions (ask depth, begin
   validation, pane fit) in cloud_preview.c where the host cc tests
   them. This file owns exactly one GWorld and the pixels' rectangle.

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
   share panel's bar discipline, one lane over. */

static WindowRef g_owner;
static Rect g_pane;                   /* photos_text: where pixels go */
static Boolean g_have_pane;
static Boolean g_shown;               /* page visible AND photos active */

static GWorldPtr g_world;             /* the ONE preview in memory */
static long g_world_w, g_world_h;
static char g_for_item[64];           /* whose pixels g_world holds */

static char g_want_item[64];          /* what the selection wants shown */
static Boolean g_fetching;            /* an ask is on the wire */
static Boolean g_reask;               /* want changed while fetching */
static char g_fail[96];               /* one line of why there is none */

/* The view's own controls: built invisible at page create, shown only
   while this view is the active one, moved by view_layout. The window
   owns their disposal (workshop rule); dispose only nulls the refs. */
static ControlRef g_size_popup;
static ControlRef g_dest_btn;
static ControlRef g_dl_bar;

enum {
    kCloudSizeMenuID = 136,
    kCloudSizeHostDefaultItem = 4
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

static void evict(void)
{
    if (g_world != NULL) {
        DisposeGWorld(g_world);
        g_world = NULL;
    }
    g_for_item[0] = '\0';
    g_fail[0] = '\0';
}

static void invalidate_pane(void)
{
    if (g_owner != NULL && g_have_pane
        && g_pane.right > g_pane.left && g_pane.bottom > g_pane.top) {
        InvalWindowRect(g_owner, &g_pane);
    }
}

/* The screen's actual depth, the way the screenshots module reads it;
   1 when there is somehow no screen, because a 1-bit ask is always
   drawable. */
static long screen_depth(void)
{
    GDHandle device = GetMainDevice();

    if (device == NULL || (**device).gdPMap == NULL) {
        return 1;
    }
    return (**(**device).gdPMap).pixelSize;
}

static void try_ask(void)
{
    char err[96];
    long w, h;

    if (g_want_item[0] == '\0' || !g_have_pane) {
        return;
    }
    w = g_pane.right - g_pane.left;
    h = g_pane.bottom - g_pane.top;
    if (w < 16 || h < 16) {
        return;                       /* no honest pane to fill */
    }
    if (now_wire_cloud_preview("photos", g_want_item, w, h,
                               cloud_preview_ask_depth(screen_depth()),
                               err, sizeof err) != 0) {
        if (g_fetching) {
            /* One in flight already: remember, re-ask when it lands. */
            g_reask = true;
        } else {
            snprintf(g_fail, sizeof g_fail, "%.90s", err);
            invalidate_pane();
        }
        return;
    }
    g_fetching = true;
}

/* Builds the one GWorld from the delivered rows. NULL colour table on
   purpose: at depth 8 that is the classic system table, which is the
   contract's whole reason no palette travels; at 1 it is black and
   white. Returns false (leaving no world) on any failure. */
static Boolean world_from(const NowCloudPreviewPixels *pixels)
{
    Rect bounds;
    PixMapHandle pix;
    long dst_row, copy, row;
    Ptr base;

    SetRect(&bounds, 0, 0, (short)pixels->width, (short)pixels->height);
    if (NewGWorld(&g_world, (short)pixels->depth, &bounds, NULL, NULL,
                  useTempMem) != noErr || g_world == NULL) {
        g_world = NULL;
        return false;
    }
    pix = GetGWorldPixMap(g_world);
    if (pix == NULL || !LockPixels(pix)) {
        DisposeGWorld(g_world);
        g_world = NULL;
        return false;
    }
    dst_row = (**pix).rowBytes & 0x3FFF;
    base = GetPixBaseAddr(pix);
    copy = pixels->row_bytes < dst_row ? pixels->row_bytes : dst_row;
    for (row = 0; row < pixels->height; ++row) {
        memcpy(base + row * dst_row,
               pixels->pixels + row * pixels->row_bytes, (size_t)copy);
    }
    UnlockPixels(pix);
    g_world_w = pixels->width;
    g_world_h = pixels->height;
    return true;
}

/* The wire's one settled answer. Success or failure, the pane changes
   once, here. */
static void note_preview(const NowCloudPreviewPixels *pixels,
                         const char *fail_reason)
{
    g_fetching = false;
    if (g_reask || g_want_item[0] == '\0') {
        /* The selection moved on while this one was arriving: what
           landed is already evicted by contract, and the ask that
           matters is the new one. (Re-asking from a wire hook is the
           listing's own auto-page pattern.) */
        g_reask = false;
        try_ask();
        return;
    }
    evict();
    if (pixels == NULL) {
        snprintf(g_fail, sizeof g_fail, "%.90s",
                 fail_reason != NULL ? fail_reason : "No preview");
    } else if (world_from(pixels)) {
        strncpy(g_for_item, g_want_item, sizeof g_for_item - 1);
        g_for_item[sizeof g_for_item - 1] = '\0';
    } else {
        strcpy(g_fail, "Not enough memory for the preview");
    }
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

    g_owner = owner;
    conn_set_cloud_preview_note(note_preview);
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
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

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

    if (g_world != NULL && selected >= 0 && selected < store->row_count
        && strcmp(store->rows[selected].item, g_for_item) == 0) {
        PixMapHandle pix = GetGWorldPixMap(g_world);
        long ww = g_pane.right - g_pane.left;
        long wh = g_pane.bottom - g_pane.top;
        long dw, dh;
        Rect dst;

        if (pix != NULL && LockPixels(pix)) {
            Rect src;

            SetRect(&src, 0, 0, (short)g_world_w, (short)g_world_h);
            cloud_preview_fit(g_world_w, g_world_h, ww, wh, &dw, &dh);
            SetRect(&dst, 0, 0, (short)dw, (short)dh);
            OffsetRect(&dst, (short)(g_pane.left + (ww - dw) / 2),
                       (short)(g_pane.top + (wh - dh) / 2));
            EraseRect(&g_pane);
            /* Fore black / back white before CopyBits, or QuickDraw
               colorizes the blit with whatever the port wore last. */
            RGBForeColor(&black);
            RGBBackColor(&white);
            CopyBits((BitMap *)*pix,
                     GetPortBitMapForCopyBits(GetWindowPort(g_owner)),
                     &src, &dst, srcCopy, NULL);
            FrameRect(&dst);
            UnlockPixels(pix);
            return;                   /* the preview replaces the card */
        }
    }
    if (g_fetching && selected >= 0) {
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
    if (g_fail[0] != '\0' && selected >= 0) {
        Str255 text;

        /* The why REPLACES the card: both start at the pane's first
           line, and two texts on one baseline is mush. The card comes
           back with the next selection or preview. */
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        MoveTo((short)(g_pane.left), (short)(g_pane.top + 12));
        CopyCStringToPascal(g_fail, text);
        DrawString(text);
        return;
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
    /* Every selection change evicts: one preview in memory, and never
       yesterday's photo behind today's card. */
    evict();
    g_pane = r->photos_text;
    g_have_pane = true;
    if (selected >= 0 && selected < store->row_count
        && store->rows[selected].item[0] != '\0') {
        strncpy(g_want_item, store->rows[selected].item,
                sizeof g_want_item - 1);
        g_want_item[sizeof g_want_item - 1] = '\0';
        try_ask();
    } else {
        g_want_item[0] = '\0';
        g_reask = false;
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
    conn_set_cloud_preview_note(NULL);
    now_wire_cloud_get_destination(false, 0, 0);
    evict();
    g_want_item[0] = '\0';
    g_fetching = false;
    g_reask = false;
    g_owner = NULL;
    g_have_pane = false;
    g_shown = false;
    g_dest_set = false;
    /* The window owns the controls' disposal; only the refs die here
       (docs/adding-a-workshop-module.md, what you own and what you do
       not). */
    g_size_popup = NULL;
    g_dest_btn = NULL;
    g_dl_bar = NULL;
    g_bar_shown = false;
    g_bar_value = -1;
    g_dl_line[0] = '\0';
}
