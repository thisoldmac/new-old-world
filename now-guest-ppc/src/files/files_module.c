#include "files_module.h"

#include <stdio.h>
#include <string.h>

#include "files_browser_view.h"
#include "files_layout.h"
#include "files_peer_label.h"
#include "files_run.h"
#include "files_share_view.h"
#include "files_status.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"
#include "workshop_scene_text.h"

/* Composition only: the browser view owns the remote half, the share
   view the local half, and this file owns the two headings, the path
   row, the seam between them, and the routing.

   THE PAGE IS TWO NAMED HALVES, both always on screen:

     Their Files - Maxbook Pro                                    heading
     [Up]  Macintosh HD:Lab:Reports          12 items    ([Stop])
     +---------------------------------------------------------+
     |  the other Mac's listing                                 |
     +---------------------------------------------------------+
     - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
     My Shared Folder        Maxbook Pro can browse everything in here.
     ... files_share_view.c from here down

   WHAT WAS HERE BEFORE, and why it is not any more. A disclosure
   triangle labelled "Shared from this Mac" hid the sharing SETTING and
   the two verbs - Send File, and where downloads land - under one
   heading that described only the first of them. Collapsing it to see
   more of the listing took away the only way to send a file, and the
   listing above it had no heading at all: a person learned it was the
   other Mac's files by noticing that the row below said "from this Mac"
   and reasoning by elimination.

   So: no triangle, both halves named, and the peer named in the heading
   through files_peer_label.c. The listing is what grows with the window
   (files_layout.c measures the bottom half upward from the bottom edge),
   which is the same pixels the triangle was buying, without taking a
   capability away to buy them. */

static WindowRef g_owner;
static Rect g_body;
static FilesLayoutRects g_r;
static Boolean g_visible;
static Boolean g_browser_ok;

static ControlRef g_up;
static ControlRef g_stop;

/* Idle cache: Up dims at the root, and only repaints on a change. */
static short g_up_hilite = -1;

/* Whether Stop is currently on screen, and the step of the progress line
   last drawn. Both are caches against repainting per chunk. */
static Boolean g_stop_shown;
static long g_xfer_step = -1;

/* The page's one status line. Four concerns write four channels; nobody
   destroys anybody else's news. files_status.h carries the argument. */
static FilesStatus g_status;

static void relayout(void)
{
    files_layout_compute(&g_body, &g_r);
    if (g_up != NULL) {
        MoveControl(g_up, g_r.up_btn.left, g_r.up_btn.top);
    }
    if (g_stop != NULL) {
        MoveControl(g_stop, g_r.stop_btn.left, g_r.stop_btn.top);
    }
    files_browser_layout(&g_r.browser);
    files_share_layout(&g_r);
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
    files_layout_compute(body, &g_r);
    g_up_hilite = -1;
    now_files_status_reset(&g_status);

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
    if (g_up == NULL || g_stop == NULL) {
        return memFullErr;
    }
    /* A missing Data Browser costs browsing, not the page: the share
       controls still work, and the pane says what is unavailable. */
    g_browser_ok = files_browser_create(owner, &g_r.browser);
    if (!files_share_create(owner, &g_r)) {
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
    /* Stop follows the transfer, not the page: leaving the page does not
       stop the file coming down, so the button comes back with the page
       if it is still arriving. The next idle pass re-derives it. */
    if (!visible) {
        show_control(g_stop, false);
        g_stop_shown = false;
    }
    g_xfer_step = -1;
    files_browser_show(visible);
    files_share_show(visible);
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
   it would abandon. The live repaint path calls this directly; the page
   walk below reaches the same run through files_run. */
static void draw_transfer_text(const PullView *pull)
{
    char line[160];

    now_pull_note(pull, line, sizeof line);
    files_run(NULL, &g_r.xfer, true, false, truncMiddle, line);
}

/* One walk over this file's own drawing, taken twice: a NULL writer
   draws it, a writer reports it. The share view's half is walked from
   describe_scene beside this one. */
static void files_content(const WorkshopSceneWriter *writer)
{
    char line[160];
    char peer[64];
    PullView pull;
    Boolean pulling = files_browser_pull(&pull);

    files_peer_label(peer, sizeof peer);
    now_files_their_heading(peer, line, sizeof line);
    files_run(writer, &g_r.their_heading, false, true, truncEnd, line);

    files_browser_path_text(line, sizeof line);
    files_run(writer, pulling ? &g_r.path_busy : &g_r.path, false, true,
              truncMiddle, line);

    if (pulling) {
        /* The count and the progress line share the slot; only one of
           them is the thing a person needs right now.
           truncMiddle, not truncEnd: the name is at the front and the
           percentage at the back, and losing either end would leave the
           half of the sentence that says nothing. */
        now_pull_note(&pull, line, sizeof line);
        files_run(writer, &g_r.xfer, true, false, truncMiddle, line);
    } else {
        files_browser_count_text(line, sizeof line);
        files_run(writer, &g_r.count, true, false, truncEnd, line);
    }

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneSeparator, "", &g_r.divider,
                           true);
    } else {
        DrawThemeSeparator(&g_r.divider, kThemeStateActive);
    }

    files_run(writer, &g_r.mine_heading, false, true, truncEnd,
              "My Shared Folder");
    now_files_share_caption(peer, line, sizeof line);
    files_run(writer, &g_r.mine_caption, true, false, truncEnd, line);

    if (!g_browser_ok) {
        Rect where;

        if (writer == NULL) {
            RGBColor black = { 0, 0, 0 };

            RGBForeColor(&black);
            FrameRect(&g_r.browser);
        } else {
            workshop_scene_add(writer, kWorkshopScenePanel, "", &g_r.browser,
                               true);
        }
        SetRect(&where, (short)(g_r.browser.left + 16),
                (short)((g_r.browser.top + g_r.browser.bottom) / 2 - 7),
                g_r.browser.right,
                (short)((g_r.browser.top + g_r.browser.bottom) / 2 + 7));
        files_run(writer, &where, false, false, truncEnd,
                  "Browsing is not available on this Mac.");
    }
}

static void files_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    files_content(NULL);
    files_browser_draw();
    files_share_draw();
}

static void files_describe_scene(const WorkshopSceneWriter *writer)
{
    /* Both halves' hand-drawing, and only that. The listing is a
       DataBrowser and the controls are controls; both are already
       Control Manager facts that control_kind.c hands over, and
       repeating them here would double them.

       The share view's runs are described HERE rather than left out, the
       way they were: a helper file's drawing is invisible to the source
       gate, so "Sharing: Macintosh HD:Lab:" was on screen and absent
       from every scene the host read. */
    if (g_owner == NULL) {
        return;
    }
    files_content(writer);
    files_share_content(writer);
}

/* Edit>Copy: the same walk, pointed at a buffer.

   What lands on the clipboard is by construction what the page
   describes, which is by construction what it drew - the headings, the
   path, the count or the transfer line, what is shared and where files
   land. NOT the listing: those rows are the DataBrowser's drawing, not
   this page's, and a file is taken out of that list by dragging it, not
   by copying a sentence describing it. */
static long files_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    files_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
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
        InvalWindowRect(g_owner, &g_r.xfer);
        return;
    }
    GetClip(saved_clip);
    ClipRect(&g_r.xfer);
    EraseRect(&g_r.xfer);
    if (pulling) {
        draw_transfer_text(&pull);
        g_xfer_step = now_pull_step(&pull);
    } else {
        /* The slot goes back to the item count, which is the other half
           of files_content and not worth duplicating here. */
        g_xfer_step = -1;
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
        InvalWindowRect(g_owner, &g_r.count);
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
    /* The listing changed the path row's words - a folder arrived, a
       count settled - and the row is this file's pixels. */
    if (files_browser_chrome_changed()) {
        Rect row = g_r.path;

        row.right = g_r.count.right;
        InvalWindowRect(g_owner, &row);
    }
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
            InvalWindowRect(g_owner, &g_r.xfer);
            InvalWindowRect(g_owner, &g_r.count);
        }
        return;
    }
    if (now_pull_step(&pull) != g_xfer_step) {
        g_xfer_step = now_pull_step(&pull);
        InvalWindowRect(g_owner, &g_r.xfer);
    }
}

/* Every concern writes its own channel; files_status.c decides which one
   a person reads. Composed here rather than in the views because this is
   the file that knows there is one placard. */
static void files_status_text(char *out, long cap)
{
    char line[kFilesStatusMax];
    PullView pull;

    line[0] = '\0';
    if (files_browser_pull(&pull)) {
        now_pull_note(&pull, line, sizeof line);
    }
    now_files_status_set(&g_status, kFilesStatusTransfer, line);

    files_share_status(line, sizeof line);
    now_files_status_set(&g_status, kFilesStatusShare, line);

    files_browser_note_text(line, sizeof line);
    now_files_status_set(&g_status, kFilesStatusBrowse, line);

    if (conn_is_connected()) {
        line[0] = '\0';
    } else {
        char peer[64];

        files_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "Not connected - %.40s is unreachable.",
                 peer);
    }
    now_files_status_set(&g_status, kFilesStatusLink, line);

    now_files_status_text(&g_status, out, cap);
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
    files_describe_scene,
    files_copy_text
};

const WorkshopModuleOps *files_module_ops(void)
{
    return &k_ops;
}
