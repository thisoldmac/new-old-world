#include "share_panel.h"

#include <stdio.h>
#include <string.h>

#include "fileshare.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"
#include "build_stamp.h"

enum {
    kPanelWidth = 400,
    kPanelHeight = 188
};

static WindowRef g_window = NULL;
static ControlRef g_choose_button;
static ControlRef g_boot_check;
static ControlRef g_send_button;
static char g_note[128];
/* What the last send did, so the line survives the transfer ending. */
static Boolean g_send_was_active;

/* Controls that cannot do anything are shown as unable to, rather than
   accepting a click and failing quietly. Re-synced every idle pass,
   because the connection can drop while the window sits there. */
static void sync_controls(void)
{
    NowPrefs prefs;

    if (g_window == NULL) {
        return;
    }
    now_prefs_load(&prefs);
    SetControlValue(g_boot_check, prefs.share_boot ? 1 : 0);
    HiliteControl(g_choose_button, prefs.share_boot ? 255 : 0);
    HiliteControl(g_send_button,
                  (conn_is_connected()
                   && now_wire_send_state(NULL, NULL, NULL, 0) == kSendNothing)
                      ? 0 : 255);
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

/* The status line the send narrates into. */
void share_panel_note(const char *line)
{
    if (g_window == NULL) {
        return;
    }
    snprintf(g_note, sizeof g_note, "%.120s", line);
    invalidate();
}

/* Called every event-loop pass: keeps the buttons honest about what
   they can do, and repaints while a file is moving so the bar advances
   instead of the window looking hung. */
void share_panel_idle(void)
{
    Boolean sending;

    if (g_window == NULL) {
        return;
    }
    sync_controls();
    sending = now_wire_send_state(NULL, NULL, NULL, 0) != kSendNothing;
    if (sending || g_send_was_active) {
        invalidate();
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

    SetRect(&bounds, kPanelWidth - 130, kPanelHeight - 36,
            kPanelWidth - 16, kPanelHeight - 12);
    CopyCStringToPascal("Choose Folder...", text);
    g_choose_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                 pushButProc, 0);

    {
        char peer[24];
        char label[64];

        conn_peer_label(peer, sizeof peer);
        snprintf(label, sizeof label, "Send to %.20s...", peer);
        SetRect(&bounds, 16, kPanelHeight - 36, 156, kPanelHeight - 12);
        CopyCStringToPascal(label, text);
        g_send_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                   pushButProc, 0);
    }
    sync_controls();
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

    if (phase == kSendNothing) {
        return;
    }
    SetRect(&bar, 16, 108, kPanelWidth - 16, 120);
    FrameRect(&bar);
    InsetRect(&bar, 1, 1);
    if (phase == kSendSending && total > 0) {
        long width = (bar.right - bar.left);
        long filled = (long)((double)width * (double)sent / (double)total);

        if (filled > 0) {
            Rect done = bar;

            if (filled > width) {
                filled = width;
            }
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
        sync_controls();
        invalidate();
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
