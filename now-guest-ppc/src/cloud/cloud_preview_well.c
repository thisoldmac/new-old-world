#include "cloud_preview_well.h"

#include <stdio.h>
#include <string.h>

#include "cloud_preview.h"
#include "wire.h"

static GWorldPtr g_world;             /* the ONE preview in memory,
                                          shared across every view */
static long g_world_w, g_world_h;
static char g_for_service[24];        /* whose pixels g_world holds */
static char g_for_item[64];

static char g_want_service[24];       /* what the current selection
                                          wants shown */
static char g_want_item[64];
static long g_want_w, g_want_h;
static Boolean g_fetching;            /* an ask is on the wire */
static Boolean g_reask;               /* want changed while fetching */
static char g_fail[96];               /* one line of why there is none,
                                          for g_want_service/g_want_item */

static CloudPreviewWellNote g_note;   /* the CURRENT owner's callback;
                                          rebound on every _select */

static void evict(void)
{
    if (g_world != NULL) {
        DisposeGWorld(g_world);
        g_world = NULL;
    }
    g_for_service[0] = '\0';
    g_for_item[0] = '\0';
    g_fail[0] = '\0';
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

    if (g_want_item[0] == '\0') {
        return;
    }
    if (g_want_w < 16 || g_want_h < 16) {
        return;                       /* no honest pane to fill */
    }
    if (now_wire_cloud_preview(g_want_service, g_want_item, g_want_w,
                               g_want_h,
                               cloud_preview_ask_depth(screen_depth()),
                               err, sizeof err) != 0) {
        if (g_fetching) {
            /* One in flight already: remember, re-ask when it lands. */
            g_reask = true;
        } else {
            snprintf(g_fail, sizeof g_fail, "%.90s", err);
            if (g_note != NULL) {
                g_note();
            }
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

/* The wire's one settled answer. Success or failure, the well changes
   once, here, and the CURRENT owner (if any) is told once. */
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
        strncpy(g_for_service, g_want_service, sizeof g_for_service - 1);
        g_for_service[sizeof g_for_service - 1] = '\0';
        strncpy(g_for_item, g_want_item, sizeof g_for_item - 1);
        g_for_item[sizeof g_for_item - 1] = '\0';
    } else {
        strcpy(g_fail, "Not enough memory for the preview");
    }
    if (g_note != NULL) {
        g_note();
    }
}

void cloud_preview_well_init(void)
{
    conn_set_cloud_preview_note(note_preview);
}

void cloud_preview_well_dispose(void)
{
    conn_set_cloud_preview_note(NULL);
    evict();
    g_want_service[0] = '\0';
    g_want_item[0] = '\0';
    g_want_w = g_want_h = 0;
    g_fetching = false;
    g_reask = false;
    g_note = NULL;
}

void cloud_preview_well_select(const char *service, const char *item,
                               long ww, long wh, CloudPreviewWellNote note)
{
    /* Every selection change evicts: one preview in memory, and never
       yesterday's picture behind today's card -- Photos' original
       rule, now the well's own regardless of who is asking. */
    evict();
    g_note = note;
    if (item != NULL && item[0] != '\0' && service != NULL) {
        strncpy(g_want_service, service, sizeof g_want_service - 1);
        g_want_service[sizeof g_want_service - 1] = '\0';
        strncpy(g_want_item, item, sizeof g_want_item - 1);
        g_want_item[sizeof g_want_item - 1] = '\0';
        g_want_w = ww;
        g_want_h = wh;
        try_ask();
    } else {
        g_want_service[0] = '\0';
        g_want_item[0] = '\0';
        g_reask = false;
    }
}

Boolean cloud_preview_well_ready(const char *service, const char *item)
{
    return (Boolean)(g_world != NULL && service != NULL && item != NULL
                     && strcmp(g_for_service, service) == 0
                     && strcmp(g_for_item, item) == 0);
}

Boolean cloud_preview_well_fetching(const char *service, const char *item)
{
    return (Boolean)(g_fetching && service != NULL && item != NULL
                     && strcmp(g_want_service, service) == 0
                     && strcmp(g_want_item, item) == 0);
}

const char *cloud_preview_well_fail(const char *service, const char *item)
{
    if (g_fail[0] == '\0' || service == NULL || item == NULL) {
        return "";
    }
    if (strcmp(g_want_service, service) != 0
        || strcmp(g_want_item, item) != 0) {
        return "";
    }
    return g_fail;
}

void cloud_preview_well_draw(WindowRef owner, const Rect *dst_pane)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    PixMapHandle pix;
    long ww, wh, dw, dh;
    Rect src, dst;

    if (g_world == NULL || owner == NULL || dst_pane == NULL) {
        return;
    }
    ww = dst_pane->right - dst_pane->left;
    wh = dst_pane->bottom - dst_pane->top;
    pix = GetGWorldPixMap(g_world);
    if (pix == NULL || !LockPixels(pix)) {
        return;
    }
    SetRect(&src, 0, 0, (short)g_world_w, (short)g_world_h);
    cloud_preview_fit(g_world_w, g_world_h, ww, wh, &dw, &dh);
    SetRect(&dst, 0, 0, (short)dw, (short)dh);
    OffsetRect(&dst, (short)(dst_pane->left + (ww - dw) / 2),
              (short)(dst_pane->top + (wh - dh) / 2));
    EraseRect(dst_pane);
    /* Fore black / back white before CopyBits, or QuickDraw colorizes
       the blit with whatever the port wore last. */
    RGBForeColor(&black);
    RGBBackColor(&white);
    CopyBits((BitMap *)*pix, GetPortBitMapForCopyBits(GetWindowPort(owner)),
             &src, &dst, srcCopy, NULL);
    FrameRect(&dst);
    UnlockPixels(pix);
}
