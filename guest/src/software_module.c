#include "software_module.h"

#include <stdio.h>
#include <string.h>

#include "software.h"
#include "software_layout.h"

/* Rung 3, first cut. The registration is live - the page appears,
   switches, and survives the prefs-format-14 migration - and it draws
   the real installed-software overview. The interactive Data Browser,
   the domain popup, live search, the launch/reveal buttons, and the
   idle-paced version trickle (now_software_read_version per row) land on
   top of this frame next; the pure geometry and the per-row version
   primitive they need are already in place and tested. */

static WindowRef g_owner;
static Rect g_body;
static SoftwareLayout g_lay;
static Boolean g_visible;
static short g_font;

static SoftwareRow g_overview[kSoftwareRowMax];
static int g_overview_count;

static void draw_row(short left, short y, const char *a, const char *b)
{
    Str255 text;

    MoveTo(left, y);
    CopyCStringToPascal(a, text);
    DrawString(text);
    if (b != NULL && b[0] != '\0') {
        MoveTo((short)(left + 168), y);
        CopyCStringToPascal(b, text);
        DrawString(text);
    }
}

static OSErr software_create(WindowRef owner, const Rect *body)
{
    Str255 geneva;

    g_owner = owner;
    g_body = *body;
    software_layout_compute(body, &g_lay);
    if (g_font == 0) {
        CopyCStringToPascal("Geneva", geneva);
        GetFNum(geneva, &g_font);
    }
    /* The overview is cheap (dozens of catalog reads, no fork opens) and
       needs no FSSpec, so the first cut can gather it once here. */
    g_overview_count = now_software_overview(g_overview, kSoftwareRowMax);
    return noErr;
}

static void software_dispose(void)
{
    /* No controls or UPPs owned yet. */
    g_owner = NULL;
}

static void software_show(Boolean visible)
{
    g_visible = visible;
}

static void software_layout(const Rect *body)
{
    g_body = *body;
    software_layout_compute(body, &g_lay);
}

static void software_draw(void)
{
    RGBColor black = { 0, 0, 0 };
    short left;
    short y;
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    RGBForeColor(&black);

    /* Frame the split so the page reads as the shape it will become. */
    FrameRect(&g_lay.list);
    FrameRect(&g_lay.detail);

    TextFont(g_font);
    TextSize(10);
    left = (short)(g_lay.list.left + 8);
    y = (short)(g_lay.list.top + 16);
    for (i = 0; i < g_overview_count; ++i) {
        draw_row(left, y, g_overview[i].name, g_overview[i].detail);
        y = (short)(y + 16);
    }

    TextSize(9);
    draw_row((short)(g_lay.detail.left + 10), (short)(g_lay.detail.top + 16),
             "Interactive list, search, and launch", NULL);
    draw_row((short)(g_lay.detail.left + 10), (short)(g_lay.detail.top + 30),
             "land on this frame next.", NULL);
}

static void software_activate(Boolean active)
{
    (void)active;
}

static void software_idle(void)
{
    /* The version trickle will live here, one now_software_read_version
       per pass. Nothing to do until the item list exists. */
}

static void software_status_text(char *out, long cap)
{
    /* Until the sweep-driven Applications count is live, report what the
       cheap overview knows: the folder-domain totals. */
    snprintf(out, (size_t)cap, "Installed software - %d categories",
             g_overview_count > 0 ? g_overview_count - 1 : 0);
}

static const WorkshopModuleOps k_ops = {
    software_create,
    software_dispose,
    software_show,
    software_layout,
    software_draw,
    NULL,                 /* click - none yet */
    NULL,                 /* key - none yet */
    software_activate,
    software_idle,
    software_status_text
};

const WorkshopModuleOps *software_module_ops(void)
{
    return &k_ops;
}
