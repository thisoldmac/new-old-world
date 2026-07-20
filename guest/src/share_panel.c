#include "share_panel.h"

#include <stdio.h>
#include <string.h>

#include "fileshare.h"
#include "pump.h"
#include "wire.h"
#include "build_stamp.h"

enum {
    kPanelWidth = 400,
    kPanelHeight = 148
};

static WindowRef g_window = NULL;
static ControlRef g_choose_button;
static char g_note[128];

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

    SetRect(&bounds, kPanelWidth - 130, kPanelHeight - 36,
            kPanelWidth - 16, kPanelHeight - 12);
    CopyCStringToPascal("Choose Folder...", text);
    g_choose_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                 pushButProc, 0);
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
    MoveTo(16, 96);
    CopyCStringToPascal(now_build_stamp(), text);
    DrawString(text);

    MoveTo(16, 74);
    if (g_note[0] != '\0') {
        CopyCStringToPascal(g_note, text);
    } else {
        CopyCStringToPascal("Nothing outside it is reachable over the wire.",
                            text);
    }
    DrawString(text);
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
    }
}
