#include "cloud_photos_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"
#include "cloud_list_view.h"
#include "cloud_preview.h"
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
   frame, because nothing here ever sees a bulk frame. */

static WindowRef g_owner;
static Rect g_pane;                   /* detail_text: where pixels go */
static Boolean g_have_pane;

static GWorldPtr g_world;             /* the ONE preview in memory */
static long g_world_w, g_world_h;
static char g_for_item[64];           /* whose pixels g_world holds */

static char g_want_item[64];          /* what the selection wants shown */
static Boolean g_fetching;            /* an ask is on the wire */
static Boolean g_reask;               /* want changed while fetching */
static char g_fail[96];               /* one line of why there is none */

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

/* --- ops ---------------------------------------------------------------- */

static OSErr view_create(WindowRef owner)
{
    g_owner = owner;
    conn_set_cloud_preview_note(note_preview);
    return noErr;
}

static void view_layout(const CloudLayout *r)
{
    g_pane = r->detail_text;
    g_have_pane = true;
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    /* draw() may run before layout() on a fresh page; the layout the
       shell passes is current either way. */
    g_pane = r->detail_text;
    g_have_pane = true;

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
    if (g_fail[0] != '\0' && selected >= 0) {
        Str255 text;

        /* The why REPLACES the card: both start at the pane's first
           line, and two texts on one baseline is mush. The card comes
           back with the next selection or preview. */
        MoveTo((short)(g_pane.left), (short)(g_pane.top + 12));
        CopyCStringToPascal(g_fail, text);
        DrawString(text);
        return;
    }
    cloud_list_view_draw_card(r, store, service, selected);
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
    g_pane = r->detail_text;
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
    NULL,                              /* show: nothing hidden here */
    view_layout,
    view_draw,
    NULL,                              /* click: the shell's ask_save() */
    NULL,                              /* key: generic HandleControlKey */
    NULL,                              /* idle: the wire hook drives us */
    NULL,                              /* reset_for_service: ask_rows(1) */
    view_row_matches,
    view_select
};

const CloudViewOps *cloud_photos_view_ops(void)
{
    return &k_ops;
}

void cloud_photos_view_dispose(void)
{
    conn_set_cloud_preview_note(NULL);
    evict();
    g_want_item[0] = '\0';
    g_fetching = false;
    g_reask = false;
    g_owner = NULL;
    g_have_pane = false;
}
