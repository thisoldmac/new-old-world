#include "files_module.h"

#include <stdio.h>
#include <string.h>

#include "files_browser_view.h"
#include "files_share_view.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"

/* Composition only: the browser view owns the remote half, the share
   view the local half, and this file owns the path row, the disclosure,
   and the routing between them. */

enum {
    kMargin = 12,
    kPathRowHeight = 28,
    kDisclosureHeight = 20,
    kShareHeight = 112,
    kStopWidth = 54,                  /* "Stop" in a small push button */
    kStopGap = 8                      /* button to the text beside it */
};

typedef struct {
    Rect path_row;
    Rect up_btn;
    Rect browser;
    Rect tri;
    Rect tri_label;
    Rect share;
    /* At the right end of the path row, where the item count normally
       sits. Nothing moves when it appears: the count and the progress
       line share the slot, because only one of them is ever the thing a
       person needs, and a row that reflows mid-transfer is a row whose
       Stop button moves under the pointer. */
    Rect stop_btn;
    Rect xfer_text;
} FilesRects;

static WindowRef g_owner;
static Rect g_body;
static FilesRects g_r;
static Boolean g_visible;
static Boolean g_expanded = true;
static Boolean g_browser_ok;

static ControlRef g_up;
static ControlRef g_tri;
static ControlRef g_stop;

/* Idle cache: Up dims at the root, and only repaints on a change. */
static short g_up_hilite = -1;

/* Whether Stop is currently on screen, and the step of the progress line
   last drawn. Both are caches against repainting per chunk. */
static Boolean g_stop_shown;
static long g_xfer_step = -1;

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
    SetRect(&r->stop_btn, (short)(right - kStopWidth),
            (short)(r->path_row.top + 2), right,
            (short)(r->path_row.top + 22));
    {
        /* The progress line takes the right-hand end of the row and
           leaves the path at least a readable stub. On a narrow window
           the path gives way first: which file is coming down and how
           far along it is are the facts that change, and the path is
           still legible in the list below. */
        short text_left = (short)(r->stop_btn.left - kStopGap - 210);
        short floor = (short)(r->up_btn.right + 90);

        if (text_left < floor) {
            text_left = floor;
        }
        SetRect(&r->xfer_text, text_left, r->path_row.top,
                (short)(r->stop_btn.left - kStopGap),
                (short)(r->path_row.top + 20));
    }

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
    if (g_stop != NULL) {
        MoveControl(g_stop, g_r.stop_btn.left, g_r.stop_btn.top);
    }
    files_browser_layout(&g_r.browser);
    files_share_layout(&g_r.share);
}

/* --- module ops --------------------------------------------------------- */

static OSErr files_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    /* What makes the Stop button real: without a canceller registered,
       now_pull_can_stop() is false and the button never appears. The
       primitive lives in wire.c because g_get is private to it. */
    now_pull_set_canceller(now_wire_get_cancel);

    g_owner = owner;
    g_body = *body;
    g_expanded = true;
    compute_rects(body, &g_r);
    g_up_hilite = -1;

    CopyCStringToPascal("Up", text);
    g_up = now_control_new(owner, &g_r.up_btn, text, false, 0, 0, 1,
                      pushButProc, 0);
    /* Created hidden and shown only while a transfer is live. A Stop
       button standing over a quiet pane is a control whose meaning a
       person has to work out; one that appears when a file starts coming
       down says what it is for by appearing. */
    CopyCStringToPascal("Stop", text);
    g_stop = now_control_new(owner, &g_r.stop_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    g_stop_shown = false;
    g_xfer_step = -1;
    text[0] = 0;
    g_tri = now_control_new(owner, &g_r.tri, text, false, 1, 0, 1,
                       kControlTriangleAutoToggleProc, 0);
    if (g_up == NULL || g_tri == NULL || g_stop == NULL) {
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
    g_stop = NULL;
    g_stop_shown = false;
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
    /* Stop follows the transfer, not the page: leaving the page does not
       stop the file coming down, so the button comes back with the page
       if it is still arriving. The next idle pass re-derives it. */
    if (!visible) {
        show_control(g_stop, false);
        g_stop_shown = false;
    }
    g_xfer_step = -1;
    files_browser_show(visible);
    files_share_show(visible && g_expanded);
}

static void files_layout(const Rect *body)
{
    g_body = *body;
    relayout();
}

/* The progress line, right-aligned into the slot beside Stop. Drawn on
   its own rather than only through the status placard: the placard is at
   the far bottom of the window, and a person deciding whether to press
   Stop should not have to look somewhere else to find out what pressing
   it would abandon. */
static void draw_transfer_text(const PullView *pull)
{
    Str255 text;
    char line[160];
    short room = (short)(g_r.xfer_text.right - g_r.xfer_text.left);

    now_pull_note(pull, line, sizeof line);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    CopyCStringToPascal(line, text);
    /* truncMiddle, not truncEnd: the name is at the front and the
       percentage at the back, and losing either end would leave the
       half of the sentence that says nothing. */
    TruncString(room, text, truncMiddle);
    MoveTo((short)(g_r.xfer_text.right - StringWidth(text)),
           (short)(g_r.path_row.top + 16));
    DrawString(text);
}

static void files_draw(void)
{
    Str255 text;
    char line[160];
    PullView pull;
    Boolean pulling = files_browser_pull(&pull);
    short path_right = pulling ? (short)(g_r.xfer_text.left - 6)
                               : (short)(g_r.path_row.right - 100);

    if (g_owner == NULL || !g_visible) {
        return;
    }
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    files_browser_path_text(line, sizeof line);
    MoveTo((short)(g_r.up_btn.right + 10), (short)(g_r.path_row.top + 16));
    CopyCStringToPascal(line, text);
    TruncString((short)(path_right - g_r.up_btn.right - 10), text,
                truncMiddle);
    DrawString(text);

    if (pulling) {
        /* The count and the progress line share the slot; only one of
           them is the thing a person needs right now. */
        draw_transfer_text(&pull);
    } else {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        files_browser_count_text(line, sizeof line);
        CopyCStringToPascal(line, text);
        TruncString(96, text, truncEnd);
        MoveTo((short)(g_r.path_row.right - StringWidth(text)),
               (short)(g_r.path_row.top + 16));
        DrawString(text);
    }

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

/* Show or hide Stop and repaint the progress line, NOW rather than on
   the next update event.
   ------------------------------------------------------------------
   This is the repaint trap this codebase walked into earlier today, in
   its other direction. There, a synchronous three-second probe queued
   "Measuring..." and the paint landed at the same moment as the answer,
   so nobody saw it. Here nothing blocks - the pull is asynchronous end
   to end (docs/guest-transfer-cancel.md) - so a queued paint WOULD in
   fact land before the first byte. It is still drawn directly, for a
   different reason: the button and the line are the answer to a click,
   and a control that appears on the pass after the click it belongs to
   is a control a person has already decided is not there.

   Called from the click and key paths, both of which run with the
   window's port already reachable, and it restores the clip it found. */
static void paint_transfer_now(void)
{
    PullView pull;
    Boolean pulling;
    Boolean want_stop;
    RgnHandle saved_clip;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    pulling = files_browser_pull(&pull);
    want_stop = now_pull_can_stop(&pull);

    if (g_stop != NULL && want_stop != g_stop_shown) {
        g_stop_shown = want_stop;
        if (want_stop) {
            ShowControl(g_stop);      /* draws it there and then */
        } else {
            HideControl(g_stop);
        }
    }

    SetPortWindowPort(g_owner);
    saved_clip = NewRgn();
    if (saved_clip == NULL) {
        /* No region to put the clip back with: leave the port alone and
           let the update path do it. */
        InvalWindowRect(g_owner, &g_r.path_row);
        return;
    }
    GetClip(saved_clip);
    ClipRect(&g_r.xfer_text);
    EraseRect(&g_r.xfer_text);
    if (pulling) {
        draw_transfer_text(&pull);
        g_xfer_step = now_pull_step(&pull);
    } else {
        /* The slot goes back to the item count, which is the other half
           of files_draw and not worth duplicating here. */
        g_xfer_step = -1;
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
        InvalWindowRect(g_owner, &g_r.path_row);
        return;
    }
    SetClip(saved_clip);
    DisposeRgn(saved_clip);
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
    if (g_stop != NULL && g_stop_shown && PtInRect(local, &g_r.stop_btn)) {
        if (TrackControl(g_stop, local, now_pump_action()) != 0) {
            char err[128];

            /* No confirmation. Stopping a fetch you started is not
               destructive - a pull is never resumable, so the temp is
               deleted and nothing was ever going to appear under the
               real name (wire.c get_begin) - and a Stop that opens a
               dialog is a Stop that costs another decision at exactly
               the moment a person wanted fewer of them. confirm.c is
               for the choices that lose something. */
            err[0] = '\0';
            if (!files_browser_stop_pull(err, sizeof err)
                && err[0] != '\0') {
                files_browser_note(err);
            }
            paint_transfer_now();
        }
        return true;
    }
    if (files_browser_click(event, local)) {
        /* A double-click in the list may have started a pull. The Stop
           button belongs to that click, not to the pass after it. */
        if (files_browser_pull_began()) {
            paint_transfer_now();
        }
        return true;
    }
    return files_share_click(event, local);
}

static Boolean files_key(const EventRecord *event)
{
    Boolean handled = files_browser_key(event);

    /* Return on a selection opens too, and deserves the same button in
       the same keystroke. */
    if (handled && files_browser_pull_began()) {
        paint_transfer_now();
    }
    return handled;
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
    if (g_stop != NULL) {
        if (active) {
            ActivateControl(g_stop);
        } else {
            DeactivateControl(g_stop);
        }
    }
    files_browser_activate(active);
    files_share_activate(active);
}

static void files_idle(void)
{
    short want;
    PullView pull;
    Boolean pulling;
    Boolean want_stop;

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

    /* The transfer row. A pull that started somewhere other than a click
       here - or that ended on its own - lands through this path, and so
       does every percent of a running one. Repainting is gated on
       now_pull_step, so a MacTCP transfer that delivers a chunk per
       event-loop pass costs one paint per whole percent, not thousands. */
    pulling = files_browser_pull(&pull);
    want_stop = now_pull_can_stop(&pull);
    if (g_stop != NULL && want_stop != g_stop_shown) {
        g_stop_shown = want_stop;
        if (want_stop) {
            ShowControl(g_stop);
        } else {
            HideControl(g_stop);
        }
    }
    if (!pulling) {
        if (g_xfer_step != -1) {
            g_xfer_step = -1;         /* put the item count back */
            InvalWindowRect(g_owner, &g_r.path_row);
        }
        return;
    }
    if (now_pull_step(&pull) != g_xfer_step) {
        g_xfer_step = now_pull_step(&pull);
        InvalWindowRect(g_owner, &g_r.path_row);
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
    files_status_text,
    NULL
};

const WorkshopModuleOps *files_module_ops(void)
{
    return &k_ops;
}
