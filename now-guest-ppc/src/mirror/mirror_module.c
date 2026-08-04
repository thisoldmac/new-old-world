#include "mirror_module.h"

#include <stdio.h>
#include <string.h>

#include "mirror_layout.h"
#include "mirror_probe.h"

static WindowRef g_owner;
static Rect g_body;
static MirrorLayout g_layout;
static MirrorFacts g_facts;
static Boolean g_visible;
static UInt32 g_next_poll;

enum { kMirrorPollTicks = 60 };

static void draw_line(const Rect *where, const char *text)
{
    Str255 ptext;

    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, ptext);
    TruncString((short)(where->right - where->left), ptext, truncEnd);
    DrawString(ptext);
}

static void draw_row(const Rect *where, const char *label, const char *value)
{
    Rect left = *where;
    Rect right = *where;

    left.right = (short)(where->left + kMirrorLabelWidth);
    right.left = left.right;
    draw_line(&left, label);
    draw_line(&right, value);
}

static void draw_heading(const Rect *where, const char *text)
{
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    draw_line(where, text);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

static OSErr mirror_create(WindowRef owner, const Rect *body)
{
    g_owner = owner;
    g_body = *body;
    now_mirror_layout_compute(body, &g_layout);
    now_mirror_probe(&g_facts);
    g_next_poll = TickCount() + kMirrorPollTicks;
    return noErr;
}

static void mirror_dispose(void)
{
    g_owner = NULL;
    g_visible = false;
}

static void mirror_show(Boolean visible)
{
    g_visible = visible;
}

static void mirror_layout(const Rect *body)
{
    g_body = *body;
    now_mirror_layout_compute(body, &g_layout);
}

static void mirror_draw(void)
{
    char value[180];
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_heading(&g_layout.heading, "NOW Extension");
    now_mirror_lifecycle_text(&g_facts, value, (long)sizeof value);
    draw_row(&g_layout.lifecycle_rows[0], "Lifecycle", value);
    if (g_facts.lifecycle == kMirrorLifecycleActive
        || g_facts.lifecycle == kMirrorLifecycleDegraded
        || g_facts.lifecycle == kMirrorLifecycleWrongVersion) {
        snprintf(value, sizeof value, "%lu.%lu", g_facts.resident_major,
                 g_facts.resident_minor);
    } else {
        strcpy(value, "-");
    }
    draw_row(&g_layout.lifecycle_rows[1], "Resident version", value);
    snprintf(value, sizeof value, "cap %lu, requested %lu, active %lu",
             g_facts.capabilities, g_facts.requested_bits,
             g_facts.active_bits);
    draw_row(&g_layout.lifecycle_rows[2], "Plane bits", value);
    snprintf(value, sizeof value, "%s",
             g_facts.has_build_identity ? "Exact build identity available"
                                        : "Build identity unavailable");
    draw_row(&g_layout.lifecycle_rows[3], "Build", value);

    draw_heading(&g_layout.plane_heading, "Mirror planes");
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        now_mirror_plane_value(&g_facts, (MirrorPlane)i, value,
                               (long)sizeof value);
        draw_row(&g_layout.plane_rows[i],
                 now_mirror_plane_name((MirrorPlane)i), value);
    }
    for (i = 0; i < kMirrorNoteLines; ++i) {
        draw_line(&g_layout.note[i], now_mirror_note(i));
    }
}

static Boolean mirror_click(const EventRecord *event, Point local)
{
    (void)event;
    (void)local;
    return false;
}

static void mirror_activate(Boolean active)
{
    (void)active;
}

static void mirror_idle(void)
{
    MirrorFacts latest;

    if (g_owner == NULL || !g_visible
        || (long)(TickCount() - g_next_poll) < 0) {
        return;
    }
    g_next_poll = TickCount() + kMirrorPollTicks;
    now_mirror_probe(&latest);
    if (memcmp(&latest, &g_facts, sizeof latest) != 0) {
        g_facts = latest;
        InvalWindowRect(g_owner, &g_body);
    }
}

static void mirror_status(char *out, long cap)
{
    now_mirror_status_text(&g_facts, out, cap);
}

static const WorkshopModuleOps k_ops = {
    mirror_create,
    mirror_dispose,
    mirror_show,
    mirror_layout,
    mirror_draw,
    mirror_click,
    NULL,
    mirror_activate,
    mirror_idle,
    mirror_status,
    NULL
};

const WorkshopModuleOps *mirror_module_ops(void)
{
    return &k_ops;
}
