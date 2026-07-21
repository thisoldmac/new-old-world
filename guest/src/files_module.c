#include "files_module.h"

#include <stdio.h>
#include <string.h>

#include "files_browser_view.h"
#include "files_share_view.h"
#include "pump.h"
#include "wire.h"

/* Composition only: the browser view owns the remote half, the share
   view the local half, and this file owns the path row, the disclosure,
   and the routing between them. */

enum {
    kMargin = 12,
    kPathRowHeight = 28,
    kDisclosureHeight = 20,
    kShareHeight = 112
};

typedef struct {
    Rect path_row;
    Rect up_btn;
    Rect browser;
    Rect tri;
    Rect tri_label;
    Rect share;
} FilesRects;

static WindowRef g_owner;
static Rect g_body;
static FilesRects g_r;
static Boolean g_visible;
static Boolean g_expanded = true;
static Boolean g_browser_ok;

static ControlRef g_up;
static ControlRef g_tri;

/* Idle cache: Up dims at the root, and only repaints on a change. */
static short g_up_hilite = -1;

static void compute_rects(const Rect *body, FilesRects *r)
{
    short x0 = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short share_top;
    short tri_top;

    SetRect(&r->path_row, x0, (short)(body->top + 6), right,
            (short)(body->top + 6 + kPathRowHeight));
    SetRect(&r->up_btn, x0, (short)(r->path_row.top + 2),
            (short)(x0 + 44), (short)(r->path_row.top + 22));

    if (g_expanded) {
        share_top = (short)(body->bottom - 6 - kShareHeight);
    } else {
        share_top = (short)(body->bottom - 6);
    }
    tri_top = (short)(share_top - kDisclosureHeight);
    SetRect(&r->browser, x0, r->path_row.bottom, right,
            (short)(tri_top - 4));
    SetRect(&r->tri, x0, (short)(tri_top + 4), (short)(x0 + 12),
            (short)(tri_top + 16));
    SetRect(&r->tri_label, (short)(x0 + 18), (short)(tri_top + 2), right,
            (short)(tri_top + 18));
    SetRect(&r->share, x0, share_top, right, (short)(body->bottom - 6));
}

static void relayout(void)
{
    compute_rects(&g_body, &g_r);
    if (g_up != NULL) {
        MoveControl(g_up, g_r.up_btn.left, g_r.up_btn.top);
    }
    if (g_tri != NULL) {
        MoveControl(g_tri, g_r.tri.left, g_r.tri.top);
    }
    files_browser_layout(&g_r.browser);
    files_share_layout(&g_r.share);
}

/* --- module ops --------------------------------------------------------- */

static OSErr files_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    g_expanded = true;
    compute_rects(body, &g_r);
    g_up_hilite = -1;

    CopyCStringToPascal("Up", text);
    g_up = NewControl(owner, &g_r.up_btn, text, false, 0, 0, 1,
                      pushButProc, 0);
    text[0] = 0;
    g_tri = NewControl(owner, &g_r.tri, text, false, 1, 0, 1,
                       kControlTriangleAutoToggleProc, 0);
    if (g_up == NULL || g_tri == NULL) {
        return memFullErr;
    }
    /* A missing Data Browser costs browsing, not the page: the share
       controls still work, and the pane says what is unavailable. */
    g_browser_ok = files_browser_create(owner, &g_r.browser);
    if (!files_share_create(owner, &g_r.share)) {
        return memFullErr;
    }
    return noErr;
}

static void files_dispose(void)
{
    files_share_dispose();
    files_browser_dispose();
    g_owner = NULL;
    g_up = NULL;
    g_tri = NULL;
}

static void show_control(ControlRef control, Boolean visible)
{
    if (control == NULL) {
        return;
    }
    if (visible) {
        ShowControl(control);
    } else {
        HideControl(control);
    }
}

static void files_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_up, visible);
    show_control(g_tri, visible);
    files_browser_show(visible);
    files_share_show(visible && g_expanded);
}

static void files_layout(const Rect *body)
{
    g_body = *body;
    relayout();
}

static void files_draw(void)
{
    Str255 text;
    char line[160];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    files_browser_path_text(line, sizeof line);
    MoveTo((short)(g_r.up_btn.right + 10), (short)(g_r.path_row.top + 16));
    CopyCStringToPascal(line, text);
    TruncString((short)(g_r.path_row.right - g_r.up_btn.right - 110), text,
                truncMiddle);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    files_browser_count_text(line, sizeof line);
    CopyCStringToPascal(line, text);
    TruncString(96, text, truncEnd);
    MoveTo((short)(g_r.path_row.right - StringWidth(text)),
           (short)(g_r.path_row.top + 16));
    DrawString(text);

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    MoveTo(g_r.tri_label.left, (short)(g_r.tri_label.top + 12));
    CopyCStringToPascal("Shared from this Mac", text);
    DrawString(text);

    if (!g_browser_ok) {
        RGBColor black = { 0, 0, 0 };

        RGBForeColor(&black);
        FrameRect(&g_r.browser);
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        MoveTo((short)(g_r.browser.left + 16),
               (short)((g_r.browser.top + g_r.browser.bottom) / 2));
        CopyCStringToPascal("Browsing is not available on this Mac.",
                            text);
        DrawString(text);
    }
    files_browser_draw();
    if (g_expanded) {
        files_share_draw();
    }
}

static Boolean files_click(const EventRecord *event, Point local)
{
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (g_up != NULL && PtInRect(local, &g_r.up_btn)) {
        if (TrackControl(g_up, local, now_pump_action()) != 0) {
            files_browser_go_up();
        }
        return true;
    }
    if (g_tri != NULL && PtInRect(local, &g_r.tri)) {
        if (TrackControl(g_tri, local, now_pump_action()) != 0) {
            g_expanded = GetControlValue(g_tri) != 0;
            files_share_show(g_visible && g_expanded);
            relayout();
            InvalWindowRect(g_owner, &g_body);
        }
        return true;
    }
    if (files_browser_click(event, local)) {
        return true;
    }
    return files_share_click(event, local);
}

static Boolean files_key(const EventRecord *event)
{
    return files_browser_key(event);
}

static void files_activate(Boolean active)
{
    if (g_up != NULL) {
        if (active) {
            ActivateControl(g_up);
            g_up_hilite = -1;         /* re-derive the at-root dimming */
        } else {
            DeactivateControl(g_up);
        }
    }
    if (g_tri != NULL) {
        if (active) {
            ActivateControl(g_tri);
        } else {
            DeactivateControl(g_tri);
        }
    }
    files_browser_activate(active);
    files_share_activate(active);
}

static void files_idle(void)
{
    short want;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    files_browser_idle();
    files_share_idle();
    want = files_browser_at_root() ? 255 : 0;
    if (want != g_up_hilite && g_up != NULL) {
        g_up_hilite = want;
        HiliteControl(g_up, want);
    }
}

static void files_status_text(char *out, long cap)
{
    files_share_status(out, cap);
    if (out[0] != '\0') {
        return;
    }
    files_browser_note_text(out, cap);
    if (out[0] != '\0') {
        return;
    }
    if (!conn_is_connected()) {
        snprintf(out, (size_t)cap,
                 "Not connected - the other Mac's share is unreachable.");
        return;
    }
    snprintf(out, (size_t)cap, "Ready.");
}

static const WorkshopModuleOps k_ops = {
    files_create,
    files_dispose,
    files_show,
    files_layout,
    files_draw,
    files_click,
    files_key,
    files_activate,
    files_idle,
    files_status_text
};

const WorkshopModuleOps *files_module_ops(void)
{
    return &k_ops;
}
