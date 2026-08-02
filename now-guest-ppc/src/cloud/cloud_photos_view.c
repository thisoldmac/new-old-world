#include "cloud_photos_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "cloud_list_view.h"
#include "cloud_preview_well.h"
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
   share panel's bar discipline, one lane over. */

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
    } else {
        cloud_preview_well_select("photos", NULL, 0, 0, NULL);
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
