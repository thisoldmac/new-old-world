#include "share_panel.h"

#include <stdio.h>
#include <string.h>

#include "fileshare.h"
#include "host_browser.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"
#include "build_stamp.h"

enum {
    kPanelWidth = 470,
    kPanelHeight = 188,
    kBarLeft = 16,
    kBarTop = 108,
    kBarBottom = 120,
    kBarWidth = kPanelWidth - 32
};

static WindowRef g_window = NULL;
static ControlRef g_choose_button;
static ControlRef g_boot_check;
static ControlRef g_send_button;
static ControlRef g_browse_button;
static char g_note[128];
/* What the last send did, so the line survives the transfer ending. */
static Boolean g_send_was_active;
/* Last state pushed into the Send button, so it is only redrawn on a
   change; and the last bar width drawn, so a repaint is only asked for
   when a pixel would actually differ. */
static short g_send_hilite = -1;
static short g_bar_filled = -1;

/* Whether the share is the boot volume changes only when the checkbox
   is clicked, so it is read from preferences THEN — never on the idle
   path, where a file read every event-loop pass starved the very
   transfer this panel exists to show. */
static void sync_share_controls(void)
{
    NowPrefs prefs;

    if (g_window == NULL) {
        return;
    }
    now_prefs_load(&prefs);
    SetControlValue(g_boot_check, prefs.share_boot ? 1 : 0);
    HiliteControl(g_choose_button, prefs.share_boot ? 255 : 0);
}

/* Send is off when there is nothing to send to, or a send is already
   under way. HiliteControl REDRAWS whatever it is passed, so calling it
   on every pass is a flicker loop — it is called only on a change. */
static void sync_send_control(void)
{
    short want;

    if (g_window == NULL) {
        return;
    }
    want = (conn_is_connected()
            && now_wire_send_state(NULL, NULL, NULL, 0) == kSendNothing)
        ? 0 : 255;
    if (want != g_send_hilite) {
        g_send_hilite = want;
        HiliteControl(g_send_button, want);
        /* Browsing needs a connection too, but not an idle wire: a
           listing is control-plane and works mid-transfer. */
        HiliteControl(g_browse_button, conn_is_connected() ? 0 : 255);
    }
}

static void draw_send_progress(void);

static void invalidate(void)
{
    Rect r;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &r);
    InvalWindowRect(g_window, &r);
}

/* Just the status line and the bar. A moving transfer must not repaint
   the whole window: on this machine that is the difference between a
   bar that advances and an event loop with no time left to send. */
static void invalidate_status(void)
{
    Rect r;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    SetRect(&r, 12, 86, kPanelWidth - 12, 124);
    InvalWindowRect(g_window, &r);
}

/* The status line the send narrates into. */
void share_panel_note(const char *line)
{
    if (g_window == NULL) {
        return;
    }
    snprintf(g_note, sizeof g_note, "%.120s", line);
    invalidate_status();
}

/* Called every event-loop pass, so it must cost nearly nothing when
   nothing is happening: two in-memory reads and, at most, an ask to
   repaint 38 rows of pixels when the bar would actually look different.
   No file access, no unconditional drawing. */
void share_panel_idle(void)
{
    long sent = 0, total = 0;
    SendPhase phase;
    Boolean sending;
    short filled;

    if (g_window == NULL) {
        return;
    }
    sync_send_control();
    phase = now_wire_send_state(&sent, &total, NULL, 0);
    sending = (phase != kSendNothing);
    filled = (phase == kSendSending && total > 0)
        ? (short)(kBarWidth * sent / total) : 0;

    if (sending != g_send_was_active || filled != g_bar_filled) {
        g_bar_filled = filled;
        invalidate_status();
    }
    g_send_was_active = sending;
}

void share_panel_open(void)
{
    Rect bounds;
    Str255 text;

    if (g_window != NULL) {
        SelectWindow(g_window);
        return;
    }
    SetRect(&bounds, 80, 100, 80 + kPanelWidth, 100 + kPanelHeight);
    CreateNewWindow(kDocumentWindowClass, kWindowCloseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return;
    }
    CopyCStringToPascal("File Sharing", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window,
                             kThemeBrushDocumentWindowBackground, true);

    SetRect(&bounds, 16, 62, kPanelWidth - 16, 80);
    CopyCStringToPascal("Share entire boot volume", text);
    g_boot_check = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                              checkBoxProc, 0);

    SetRect(&bounds, kPanelWidth - 134, kPanelHeight - 36,
            kPanelWidth - 16, kPanelHeight - 12);
    CopyCStringToPascal("Choose Folder...", text);
    g_choose_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                 pushButProc, 0);

    {
        char peer[24];
        char label[64];

        conn_peer_label(peer, sizeof peer);
        snprintf(label, sizeof label, "Send to %.14s...", peer);
        SetRect(&bounds, 16, kPanelHeight - 36, 160, kPanelHeight - 12);
        CopyCStringToPascal(label, text);
        g_send_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                   pushButProc, 0);

        snprintf(label, sizeof label, "Browse %.14s...", peer);
        SetRect(&bounds, 168, kPanelHeight - 36, 306, kPanelHeight - 12);
        CopyCStringToPascal(label, text);
        g_browse_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                     pushButProc, 0);
    }
    sync_share_controls();
    sync_send_control();
    g_note[0] = '\0';
    ShowWindow(g_window);
    SelectWindow(g_window);
}

void share_panel_close(void)
{
    if (g_window == NULL) {
        return;
    }
    DisposeWindow(g_window);
    g_window = NULL;
}

Boolean share_panel_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef share_panel_ref(void)
{
    return g_window;
}

void share_panel_draw(void)
{
    Rect bounds;
    Str255 text;
    char root[160];

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    DrawControls(g_window);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);

    {
        char peer[24];
        char line[96];

        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line,
                 "%.20s can browse this folder and everything inside it:",
                 peer);
        MoveTo(16, 26);
        CopyCStringToPascal(line, text);
        DrawString(text);
    }

    now_files_root_name(root, sizeof root);
    MoveTo(16, 50);
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    if (strlen(root) > 250) {
        root[250] = '\0';
    }
    CopyCStringToPascal(root, text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo(16, kPanelHeight - 52);
    CopyCStringToPascal(now_build_stamp(), text);
    DrawString(text);

    MoveTo(16, 100);
    if (g_note[0] != '\0') {
        CopyCStringToPascal(g_note, text);
    } else if (!conn_is_connected()) {
        CopyCStringToPascal("Not connected - nothing can reach this folder.",
                            text);
    } else {
        CopyCStringToPascal("Nothing outside it is reachable over the wire.",
                            text);
    }
    DrawString(text);
    draw_send_progress();
}

/* A bar for the bytes actually gone. Drawn only while a send is in
   flight: a permanent empty bar reads as a broken one. */
static void draw_send_progress(void)
{
    Rect bar;
    long sent = 0, total = 0;
    SendPhase phase = now_wire_send_state(&sent, &total, NULL, 0);

    /* Only once bytes are moving. An empty bar sitting at zero while
       the host has not answered yet says "stuck" when the truth is
       "waiting" — the status line above already says which. */
    if (phase != kSendSending) {
        return;
    }
    SetRect(&bar, kBarLeft, kBarTop, kBarLeft + kBarWidth, kBarBottom);
    FrameRect(&bar);
    InsetRect(&bar, 1, 1);
    if (total > 0) {
        long filled = (long)kBarWidth * sent / total;

        if (filled > bar.right - bar.left) {
            filled = bar.right - bar.left;
        }
        if (filled > 0) {
            Rect done = bar;

            done.right = (short)(done.left + filled);
            PaintRect(&done);
        }
    }
}

void share_panel_click(Point local)
{
    ControlRef control = NULL;

    if (FindControl(local, g_window, &control) == 0 || control == NULL) {
        return;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return;
    }
    if (control == g_choose_button) {
        char why[128];
        int rc = now_files_choose_root(why, sizeof why);

        if (rc > 0) {
            g_note[0] = '\0';
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "Not shared: %.100s", why);
        }
        invalidate();
    } else if (control == g_boot_check) {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        prefs.share_boot = !prefs.share_boot;
        if (now_prefs_save(&prefs) != noErr) {
            snprintf(g_note, sizeof g_note, "Could not save that setting");
        } else {
            g_note[0] = '\0';
        }
        sync_share_controls();
        invalidate();
    } else if (control == g_browse_button) {
        host_browser_open();
    } else if (control == g_send_button) {
        FSSpec spec;
        char why[128];
        int rc = now_files_pick_file(&spec, why, sizeof why);

        if (rc > 0 && now_wire_send_file(&spec, why, sizeof why) < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        } else if (rc > 0) {
            g_note[0] = '\0';
        }
        invalidate();
    }
}
