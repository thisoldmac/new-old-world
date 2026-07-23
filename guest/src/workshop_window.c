#include "workshop_window.h"

#include <stdio.h>
#include <string.h>

#include "census_module.h"
#include "connection_module.h"
#include "console_module.h"
#include "files_module.h"
#include "logs_module.h"
#include "processes_module.h"
#include "screenshots_module.h"
#include "software_module.h"
#include "prefs.h"
#include "workshop_layout.h"
#include "workshop_sidebar.h"
#include "wire.h"

static WindowRef g_window;
static WorkshopLayout g_lay;
static WorkshopModuleID g_selected = kWorkshopScreenshots;
static Boolean g_active;
/* Header readout cache; idle repaints the header only when the peer's
   name actually changes. */
static char g_shown_peer[40];

/* Modules register here as they move in. A NULL slot draws the honest
   placeholder instead, naming where the feature still lives. */
static const WorkshopModuleOps *g_ops[kWorkshopModuleCount + 1];
static Boolean g_created[kWorkshopModuleCount + 1];

static const struct {
    const char *title;
    const char *blurb;
    const char *pending;
} k_module_info[kWorkshopModuleCount + 1] = {
    { NULL, NULL, NULL },
    { "Screenshots",
      "Capture this Mac, send a still, or stream its screen.",
      "Screenshots still lives in its own window (Windows menu)." },
    { "Files",
      "Browse the other Mac's share and choose what this Mac exposes.",
      "Files still lives in File Sharing and the peer browser windows." },
    { "Console",
      "Commands run on this PowerBook. Only declared commands are available.",
      "Console still lives in its own window (Windows menu)." },
    { "Processes",
      "Everything running on this Mac. Quit asks politely and never forces.",
      "Processes has not moved in yet." },
    { "Hardware",
      "A passive census of this Mac. Probes run on request, never at idle.",
      "Hardware census is not built into this window yet." },
    { "Software",
      "What is installed on this Mac, and starting it. Applications sweep "
      "the disk; the rest read the System Folder.",
      "Software has not moved in yet." },
    { "Logs",
      "This launch's event log. Toggle whether it also reaches the disk.",
      "Logs has not moved in yet." },
    { "Connection",
      "This Mac dials the other Mac and keeps one persistent connection.",
      "Connection is still a dialog (Windows menu)." }
};

static const WorkshopModuleOps *selected_ops(void)
{
    return g_ops[g_selected];
}

static void invalidate_pane(void)
{
    if (g_window == NULL) {
        return;
    }
    InvalWindowRect(g_window, &g_lay.header);
    InvalWindowRect(g_window, &g_lay.body);
    InvalWindowRect(g_window, &g_lay.status);
}

static void compute_layout(void)
{
    Rect content;

    GetWindowPortBounds(g_window, &content);
    workshop_layout_compute(&content, &g_lay);
}

/* Standard bounds: the spec's content size, centered, clamped to the
   desktop so the title bar and grow box stay reachable at 640x480. */
static void standard_bounds(Rect *bounds)
{
    Rect screen;
    RgnHandle desktop = GetGrayRgn();
    short w = kWorkshopStdContentW;
    short h = kWorkshopStdContentH;
    short left;
    short top;

    if (desktop != NULL) {
        GetRegionBounds(desktop, &screen);
    } else {
        SetRect(&screen, 0, 20, 800, 600);
    }
    if (screen.right - screen.left - 12 < w) {
        w = (short)(screen.right - screen.left - 12);
    }
    if (screen.bottom - screen.top - 32 < h) {
        h = (short)(screen.bottom - screen.top - 32);
    }
    if (w < kWorkshopMinContentW) {
        w = kWorkshopMinContentW;
    }
    if (h < kWorkshopMinContentH) {
        h = kWorkshopMinContentH;
    }
    left = (short)(screen.left + (screen.right - screen.left - w) / 2);
    top = (short)(screen.top + 24
                  + (screen.bottom - screen.top - 24 - h) / 3);
    SetRect(bounds, left, top, (short)(left + w), (short)(top + h));
}

static void on_sidebar_select(WorkshopModuleID module)
{
    workshop_select_module(module);
}

static void ensure_module_created(WorkshopModuleID module)
{
    if (g_ops[module] != NULL && !g_created[module]
        && g_ops[module]->create != NULL) {
        g_created[module] =
            g_ops[module]->create(g_window, &g_lay.body) == noErr;
    }
}

/* A restored rectangle is only used when it still fits the desktop and
   the minimum size; anything else falls back to the standard bounds. */
static Boolean restorable_bounds(const Rect *r)
{
    Rect screen;
    RgnHandle desktop = GetGrayRgn();

    if (r->right - r->left < kWorkshopMinContentW
        || r->bottom - r->top < kWorkshopMinContentH) {
        return false;
    }
    if (desktop == NULL) {
        return true;
    }
    GetRegionBounds(desktop, &screen);
    return r->left >= screen.left - 8 && r->top >= screen.top + 12
        && r->left + 64 < screen.right && r->top < screen.bottom - 64;
}

Boolean workshop_open(void)
{
    Rect bounds;
    Str255 title;
    NowPrefs prefs;

    if (g_window != NULL) {
        SelectWindow(g_window);
        return true;
    }
    g_ops[kWorkshopScreenshots] = screenshots_module_ops();
    g_ops[kWorkshopFiles] = files_module_ops();
    g_ops[kWorkshopConsole] = console_module_ops();
    g_ops[kWorkshopProcesses] = processes_module_ops();
    g_ops[kWorkshopHardware] = census_module_ops();
    g_ops[kWorkshopSoftware] = software_module_ops();
    g_ops[kWorkshopLogs] = logs_module_ops();
    g_ops[kWorkshopConnection] = connection_module_ops();
    now_prefs_load(&prefs);
    if (restorable_bounds(&prefs.workshop_rect)) {
        bounds = prefs.workshop_rect;
    } else {
        standard_bounds(&bounds);
    }
    CreateNewWindow(kDocumentWindowClass, kWindowStandardDocumentAttributes,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return false;
    }
    CopyCStringToPascal("New Old World", title);
    SetWTitle(g_window, title);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);
    /* No root control on this window, on purpose. A root control turns
       the group-box controls into embedders, and an embedded control
       only receives clicks when HIToolbox's standard Carbon Event
       handler routes them - which this WaitNextEvent app does not
       install (same reason as confirm.c's kWindowStandardHandler ban).
       With a root control the "Other Mac" group swallowed clicks to its
       popup, checkbox and button; without it the controls are flat
       siblings the classic Control Manager hit-tests directly. It also
       did not make edit-text usable - text entry lives in a real
       DIALOG (conn_edit_dialog.c), which has its own window and its own
       Dialog-Manager text handling. */
    compute_layout();
    if (!workshop_sidebar_create(g_window, &g_lay, on_sidebar_select)) {
        DisposeWindow(g_window);
        g_window = NULL;
        workshop_sidebar_dispose();
        return false;
    }
    g_shown_peer[0] = '\0';
    g_selected = kWorkshopScreenshots;
    if (prefs.workshop_module >= 1
        && prefs.workshop_module <= kWorkshopModuleCount
        && prefs.workshop_module != (short)g_selected) {
        workshop_select_module((WorkshopModuleID)prefs.workshop_module);
    } else {
        ensure_module_created(g_selected);
        if (g_created[g_selected] && g_ops[g_selected]->show != NULL) {
            g_ops[g_selected]->show(true);
        }
        workshop_sidebar_set_selection(g_selected);
    }
    ShowWindow(g_window);
    SelectWindow(g_window);
    return true;
}

void workshop_close(void)
{
    int i;

    if (g_window == NULL) {
        return;
    }
    /* The session rides in the prefs file, like the old windows'. */
    {
        NowPrefs prefs;
        Rect bounds;

        now_prefs_load(&prefs);
        GetWindowBounds(g_window, kWindowContentRgn, &bounds);
        prefs.workshop_rect = bounds;
        prefs.workshop_module = (short)g_selected;
        now_prefs_save(&prefs);
    }
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        if (g_created[i] && g_ops[i] != NULL && g_ops[i]->dispose != NULL) {
            g_ops[i]->dispose();
        }
        g_created[i] = false;
    }
    DisposeWindow(g_window);          /* takes the controls with it */
    g_window = NULL;
    workshop_sidebar_dispose();       /* after, never before */
}

Boolean workshop_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef workshop_ref(void)
{
    return g_window;
}

void workshop_select_module(WorkshopModuleID module)
{
    const WorkshopModuleOps *old_ops;

    if (g_window == NULL || (int)module < 1
        || (int)module > kWorkshopModuleCount) {
        return;
    }
    workshop_sidebar_set_selection(module);
    if (module == g_selected) {
        return;
    }
    old_ops = selected_ops();
    if (old_ops != NULL && g_created[g_selected]
        && old_ops->show != NULL) {
        old_ops->show(false);
    }
    g_selected = module;
    ensure_module_created(module);
    if (g_ops[module] != NULL && g_created[module]
        && g_ops[module]->show != NULL) {
        g_ops[module]->show(true);
    }
    invalidate_pane();
}

static void draw_header(void)
{
    Str255 text;
    char peer[40];
    short right_edge = (short)(g_lay.header.right - 12);

    DrawThemePlacard(&g_lay.header,
                     g_active ? kThemeStateActive : kThemeStateInactive);
    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    MoveTo((short)(g_lay.header.left + 12), (short)(g_lay.header.top + 16));
    CopyCStringToPascal(k_module_info[g_selected].title, text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_lay.header.left + 12), (short)(g_lay.header.top + 31));
    CopyCStringToPascal(k_module_info[g_selected].blurb, text);
    TruncString((short)(right_edge - g_lay.header.left - 90), text,
                truncEnd);
    DrawString(text);

    if (conn_is_connected()) {
        conn_peer_label(peer, sizeof peer);
        CopyCStringToPascal(peer, text);
        TruncString(120, text, truncEnd);
        MoveTo((short)(right_edge - StringWidth(text)),
               (short)(g_lay.header.top + 16));
        DrawString(text);
    }
}

static void draw_status(void)
{
    Str255 text;
    char line[120];
    const WorkshopModuleOps *ops = selected_ops();

    DrawThemePlacard(&g_lay.status,
                     g_active ? kThemeStateActive : kThemeStateInactive);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_lay.status.left + 10), (short)(g_lay.status.top + 15));
    if (ops != NULL && g_created[g_selected] && ops->status_text != NULL) {
        ops->status_text(line, sizeof line);
    } else {
        strcpy(line, "Nothing to report yet.");
    }
    CopyCStringToPascal(line, text);
    TruncString((short)(g_lay.grow_safe.left - g_lay.status.left - 14),
                text, truncEnd);
    DrawString(text);
}

static void draw_placeholder_body(void)
{
    Str255 text;

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_lay.body.left + 16), (short)(g_lay.body.top + 28));
    CopyCStringToPascal(k_module_info[g_selected].pending, text);
    TruncString((short)(g_lay.body.right - g_lay.body.left - 32), text,
                truncEnd);
    DrawString(text);
    MoveTo((short)(g_lay.body.left + 16), (short)(g_lay.body.top + 44));
    CopyCStringToPascal("It moves into the Workshop in a later arc.", text);
    DrawString(text);
}

void workshop_draw(void)
{
    Rect content;
    RgnHandle visible;
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &content);
    EraseRect(&content);

    draw_header();
    draw_status();

    DrawControls(g_window);
    visible = NewRgn();
    if (visible != NULL) {
        GetPortVisibleRegion(GetWindowPort(g_window), visible);
        UpdateControls(g_window, visible);
        DisposeRgn(visible);
    }

    /* Module text goes over the controls: group-box interiors are the
       module's canvas, so labels and values land after the frames. */
    if (ops != NULL && g_created[g_selected] && ops->draw != NULL) {
        ops->draw();
    } else {
        draw_placeholder_body();
    }
    workshop_sidebar_draw();

    /* The grow icon, without the scroll-bar delimiter lines DrawGrowIcon
       would run up both edges: clip it to the corner. */
    visible = NewRgn();
    if (visible != NULL) {
        GetClip(visible);
        ClipRect(&g_lay.grow_safe);
        DrawGrowIcon(g_window);
        SetClip(visible);
        DisposeRgn(visible);
    }
}

void workshop_click(const EventRecord *event)
{
    Point local = event->where;
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GlobalToLocal(&local);
    if (ops != NULL && g_created[g_selected] && ops->click != NULL
        && ops->click(event, local)) {
        return;
    }
    workshop_sidebar_click(event, local);
}

Boolean workshop_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    const WorkshopModuleOps *ops = selected_ops();

    if (g_window == NULL) {
        return false;
    }
    if (ops != NULL && g_created[g_selected] && ops->key != NULL
        && ops->key(event)) {
        return true;
    }
    if (c == '\t') {
        AdvanceKeyboardFocus(g_window);
        return true;
    }
    return workshop_sidebar_key(event);
}

void workshop_activate(Boolean active)
{
    Rect content;

    if (g_window == NULL) {
        return;
    }
    g_active = active;
    workshop_sidebar_activate(active);
    if (g_created[g_selected] && g_ops[g_selected] != NULL
        && g_ops[g_selected]->activate != NULL) {
        g_ops[g_selected]->activate(active);
    }
    /* Placards and the grow icon change with activation. */
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &content);
    InvalWindowRect(g_window, &content);
}

void workshop_idle(void)
{
    char peer[40];
    char status[120];
    static char shown_status[120];
    const WorkshopModuleOps *ops;
    int i;

    if (g_window == NULL) {
        return;
    }
    workshop_sidebar_idle();
    peer[0] = '\0';
    if (conn_is_connected()) {
        conn_peer_label(peer, sizeof peer);
    }
    if (strcmp(peer, g_shown_peer) != 0) {
        strcpy(g_shown_peer, peer);
        InvalWindowRect(g_window, &g_lay.header);
    }
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        if (g_created[i] && g_ops[i] != NULL && g_ops[i]->idle != NULL) {
            g_ops[i]->idle();
        }
    }
    /* The status placard mirrors the selected module's line; repaint
       only on change, and only the placard. */
    ops = selected_ops();
    if (ops != NULL && g_created[g_selected] && ops->status_text != NULL) {
        ops->status_text(status, sizeof status);
        if (strcmp(status, shown_status) != 0) {
            strcpy(shown_status, status);
            InvalWindowRect(g_window, &g_lay.status);
        }
    }
}

void workshop_resized(void)
{
    Rect content;
    int i;

    if (g_window == NULL) {
        return;
    }
    compute_layout();
    workshop_sidebar_layout(&g_lay);
    for (i = 1; i <= kWorkshopModuleCount; ++i) {
        if (g_created[i] && g_ops[i] != NULL && g_ops[i]->layout != NULL) {
            g_ops[i]->layout(&g_lay.body);
        }
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &content);
    InvalWindowRect(g_window, &content);
}
