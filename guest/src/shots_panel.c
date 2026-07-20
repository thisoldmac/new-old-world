#include "shots_panel.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "screenshot.h"
#include "wire.h"

enum {
    kPanelWidth = 336,
    kPanelHeight = 304,
    kDepthMenuID = 130,
    kChunkMenuID = 131,
    kPaceMenuID = 132
};

static WindowRef g_window = NULL;
static ControlRef g_depth_popup;
static ControlRef g_chunk_popup;
static ControlRef g_pace_popup;
static ControlRef g_pack_check;
static ControlRef g_predictive_check;
static ControlRef g_interlace_check;
static ControlRef g_shoot_button;
static ControlRef g_send_button;
static ControlRef g_stream_button;
static Boolean g_stream_shown_active;
static char g_stat1[96];
static char g_stat2[96];
static char g_stat3[96];

static const short k_depths[6] = { 1, 2, 4, 8, 16, 32 };
static const short k_chunks[6] = { 1, 2, 4, 8, 16, 32 };
static const short k_paces[5] = { 0, 2, 5, 10, 20 };

static short item_for(const short *table, int n, short value, short fallback)
{
    int i;

    for (i = 0; i < n; ++i) {
        if (table[i] == value) {
            return (short)(i + 1);
        }
    }
    return fallback;
}

static void load_controls_from_prefs(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    SetControlValue(g_depth_popup,
                    item_for(k_depths, 6, prefs.shot_depth, 4));
    SetControlValue(g_chunk_popup,
                    item_for(k_chunks, 6, prefs.chunk_kb, 4));
    SetControlValue(g_pace_popup,
                    item_for(k_paces, 5, prefs.pace_ms, 1));
    SetControlValue(g_pack_check, prefs.shot_pack ? 1 : 0);
    SetControlValue(g_predictive_check, prefs.predictive ? 1 : 0);
    SetControlValue(g_interlace_check, prefs.interlace ? 1 : 0);
}

static void save_controls_to_prefs(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.shot_depth = k_depths[GetControlValue(g_depth_popup) - 1];
    prefs.chunk_kb = k_chunks[GetControlValue(g_chunk_popup) - 1];
    prefs.pace_ms = k_paces[GetControlValue(g_pace_popup) - 1];
    prefs.shot_pack = GetControlValue(g_pack_check) != 0;
    prefs.predictive = GetControlValue(g_predictive_check) != 0;
    prefs.interlace = GetControlValue(g_interlace_check) != 0;
    now_prefs_save(&prefs);
}

static void invalidate_stats(void)
{
    Rect r;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &r);
    r.top = (short)(r.bottom - 76);
    InvalWindowRect(g_window, &r);
}

static void take_screenshot(void)
{
    ShotStats stats;
    char err[96];
    NowPrefs prefs;

    now_prefs_load(&prefs);
    snprintf(g_stat1, sizeof g_stat1, "Capturing...");
    g_stat2[0] = '\0';
    g_stat3[0] = '\0';
    invalidate_stats();
    shots_panel_draw();

    if (now_screenshot(prefs.shot_depth, 1, true, &stats,
                       err, sizeof err) != 0) {
        snprintf(g_stat1, sizeof g_stat1, "Failed: %.80s", err);
        g_stat2[0] = '\0';
        g_stat3[0] = '\0';
    } else {
        snprintf(g_stat1, sizeof g_stat1,
                 "%dx%d - %d-bit - raw %ld KB - PICT %ld KB",
                 stats.width, stats.height, stats.depth,
                 stats.raw_bytes / 1024, stats.pict_bytes / 1024);
        snprintf(g_stat2, sizeof g_stat2,
                 "capture %ld ms - encode %ld ms", stats.capture_ms,
                 stats.encode_ms);
        snprintf(g_stat3, sizeof g_stat3, "Saved: %.28s", stats.saved_name);
    }
    invalidate_stats();
}

/* Keeps the stream button's title honest against the wire's state; cheap
   enough to run every draw. */
static void refresh_stream_button(void)
{
    Str255 text;
    Boolean active = now_wire_stream_active();

    if (g_stream_button == NULL || active == g_stream_shown_active) {
        return;
    }
    g_stream_shown_active = active;
    CopyCStringToPascal(active ? "Stop Streaming" : "Stream to Host", text);
    SetControlTitle(g_stream_button, text);
}

static void stream_to_host(void)
{
    char err[96];

    if (now_wire_stream_active()) {
        now_wire_stream_stop();
    } else if (now_wire_stream_request(err, sizeof err) != 0) {
        snprintf(g_stat3, sizeof g_stat3, "%.90s", err);
        invalidate_stats();
    }
    refresh_stream_button();
}

/* Offers the screen to the host. Progress lands back through
   shots_panel_note as the wire works the transfer. */
static void send_to_host(void)
{
    char err[96];

    g_stat1[0] = '\0';
    g_stat2[0] = '\0';
    if (now_wire_offer_shot(err, sizeof err) != 0) {
        snprintf(g_stat3, sizeof g_stat3, "%.90s", err);
        invalidate_stats();
    }
}

void shots_panel_note(const char *line)
{
    if (g_window == NULL) {
        return;
    }
    snprintf(g_stat3, sizeof g_stat3, "%.90s", line);
    invalidate_stats();
}

static ControlRef make_popup(const Rect *bounds, const char *title,
                             short menu_id)
{
    Str255 text;

    CopyCStringToPascal(title, text);
    /* classic popup CDEF: value = title justification, min = MENU id,
       max = title width in pixels */
    return NewControl(g_window, bounds, text, true, popupTitleLeftJust,
                      menu_id, 64, popupMenuProc, 0);
}

void shots_panel_open(void)
{
    Rect bounds;
    Str255 text;
    NowPrefs prefs;

    if (g_window != NULL) {
        SelectWindow(g_window);
        return;
    }
    now_prefs_load(&prefs);
    if (prefs.panel_rect.right - prefs.panel_rect.left >= kPanelWidth) {
        bounds = prefs.panel_rect;
        bounds.right = (short)(bounds.left + kPanelWidth);
        bounds.bottom = (short)(bounds.top + kPanelHeight);
    } else {
        SetRect(&bounds, 60, 80, 60 + kPanelWidth, 80 + kPanelHeight);
    }
    CreateNewWindow(kDocumentWindowClass,
                    kWindowCloseBoxAttribute | kWindowCollapseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return;
    }
    CopyCStringToPascal("Screenshots", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window,
                             kThemeBrushDocumentWindowBackground, true);

    SetRect(&bounds, 16, 14, 320, 36);
    g_depth_popup = make_popup(&bounds, "Depth:", kDepthMenuID);
    SetRect(&bounds, 16, 44, 320, 66);
    g_chunk_popup = make_popup(&bounds, "Chunk:", kChunkMenuID);
    SetRect(&bounds, 16, 74, 320, 96);
    g_pace_popup = make_popup(&bounds, "Pacing:", kPaceMenuID);
    SetRect(&bounds, 16, 106, 320, 124);
    CopyCStringToPascal("Compress on wire (PackBits)", text);
    g_pack_check = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                              checkBoxProc, 0);
    SetRect(&bounds, 16, 128, 172, 146);
    CopyCStringToPascal("Predictive capture", text);
    g_predictive_check = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                    checkBoxProc, 0);
    SetRect(&bounds, 178, 128, 320, 146);
    CopyCStringToPascal("Interlace", text);
    g_interlace_check = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                   checkBoxProc, 0);
    SetRect(&bounds, 16, 162, 172, 186);
    CopyCStringToPascal("Take Screenshot", text);
    g_shoot_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                pushButProc, 0);
    SetRect(&bounds, 184, 162, 320, 186);
    CopyCStringToPascal("Send to Host", text);
    g_send_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                               pushButProc, 0);
    SetRect(&bounds, 16, 192, 172, 216);
    CopyCStringToPascal("Stream to Host", text);
    g_stream_button = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                                 pushButProc, 0);
    g_stream_shown_active = false;

    load_controls_from_prefs();
    g_stat1[0] = '\0';
    g_stat2[0] = '\0';
    g_stat3[0] = '\0';
    ShowWindow(g_window);
    SelectWindow(g_window);
}

void shots_panel_close(Boolean note_in_prefs)
{
    NowPrefs prefs;
    Rect bounds;

    if (g_window == NULL) {
        return;
    }
    if (note_in_prefs) {
        now_prefs_load(&prefs);
        GetWindowBounds(g_window, kWindowContentRgn, &bounds);
        prefs.panel_rect = bounds;
        prefs.panel_open = false;
        now_prefs_save(&prefs);
    }
    DisposeWindow(g_window);
    g_window = NULL;
}

Boolean shots_panel_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef shots_panel_ref(void)
{
    return g_window;
}

void shots_panel_draw(void)
{
    Rect bounds;
    Str255 text;
    short y;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    refresh_stream_button();
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    DrawControls(g_window);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    y = (short)(bounds.bottom - 58);
    if (g_stat1[0] != '\0') {
        MoveTo(16, y);
        CopyCStringToPascal(g_stat1, text);
        DrawString(text);
    }
    if (g_stat2[0] != '\0') {
        MoveTo(16, (short)(y + 16));
        CopyCStringToPascal(g_stat2, text);
        DrawString(text);
    }
    if (g_stat3[0] != '\0') {
        MoveTo(16, (short)(y + 32));
        CopyCStringToPascal(g_stat3, text);
        DrawString(text);
    }
}

void shots_panel_click(Point local)
{
    ControlRef control = NULL;

    if (FindControl(local, g_window, &control) == 0 || control == NULL) {
        return;
    }
    if (control == g_depth_popup || control == g_chunk_popup
        || control == g_pace_popup) {
        TrackControl(control, local, (ControlActionUPP)-1L);
        save_controls_to_prefs();
        return;
    }
    if (TrackControl(control, local, NULL) == 0) {
        return;
    }
    if (control == g_pack_check || control == g_predictive_check
        || control == g_interlace_check) {
        SetControlValue(control, !GetControlValue(control));
        save_controls_to_prefs();
    } else if (control == g_shoot_button) {
        take_screenshot();
    } else if (control == g_send_button) {
        send_to_host();
    } else if (control == g_stream_button) {
        stream_to_host();
    }
}
