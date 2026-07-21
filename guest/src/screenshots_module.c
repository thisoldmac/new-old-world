#include "screenshots_module.h"

#include <stdio.h>
#include <string.h>

#include "prefs.h"
#include "pump.h"
#include "screenshot.h"
#include "wire.h"

/* now_screenshot takes the local PICT, now_wire_offer_shot and the
   stream request/stop reach the peer, and prefs holds every setting.
   The preview well is fed by now_screenshot_preview(); chunk and pacing
   live under the Advanced Transport disclosure rather than taking top
   billing - they matter on real classic network hardware, but not
   often. */

enum {
    kMargin = 12,
    kWellW = 320,
    kWellH = 240,
    kDepthMenuID = 130,
    kChunkMenuID = 131,
    kPaceMenuID = 132
};

typedef struct {
    Rect well;
    Rect caption;         /* one line under the well */
    Rect group;           /* the Capture group box */
    Rect depth;
    Rect pack;
    Rect streaming_label;
    Rect predictive;
    Rect interlace;
    Rect rate_line;
    Rect tri;             /* the Advanced Transport triangle */
    Rect tri_label;
    Rect chunk;
    Rect pace;
    Rect take_btn;
    Rect send_btn;
    Rect stream_btn;
} ShotRects;

static WindowRef g_owner;
static Rect g_body;
static ShotRects g_r;
static Boolean g_visible;

static ControlRef g_depth;
static ControlRef g_pack;
static ControlRef g_predictive;
static ControlRef g_interlace;
static ControlRef g_tri;
static ControlRef g_chunk;
static ControlRef g_pace;
static ControlRef g_take;
static ControlRef g_send;
static ControlRef g_stream;

static Boolean g_expanded;
static ShotStats g_last;
static Boolean g_have_shot;
static char g_status[120];

/* Idle caches: repaint or retitle only on change. */
static char g_shown_peer[24];
static Boolean g_shown_connected;
static Boolean g_shown_streaming;
static long g_shown_rate = -2;

static const short k_depths[6] = { 1, 2, 4, 8, 16, 32 };
static const short k_chunks[6] = { 1, 2, 4, 8, 16, 32 };
static const short k_paces[5] = { 0, 2, 5, 10, 20 };

static short item_for(const short *table, int n, short value,
                      short fallback)
{
    int i;

    for (i = 0; i < n; ++i) {
        if (table[i] == value) {
            return (short)(i + 1);
        }
    }
    return fallback;
}

static void compute_rects(const Rect *body, ShotRects *r)
{
    short x0 = (short)(body->left + kMargin);
    short y0 = (short)(body->top + 8);
    short col = (short)(x0 + kWellW + 16);
    short right = (short)(body->right - kMargin);
    short gy = y0;
    short buttons_y = (short)(body->bottom - 32);

    SetRect(&r->well, x0, y0, (short)(x0 + kWellW), (short)(y0 + kWellH));
    SetRect(&r->caption, x0, (short)(r->well.bottom + 4),
            (short)(x0 + kWellW), (short)(r->well.bottom + 20));

    SetRect(&r->group, col, gy, right, (short)(gy + 168));
    SetRect(&r->depth, (short)(col + 10), (short)(gy + 18),
            (short)(right - 12), (short)(gy + 38));
    SetRect(&r->pack, (short)(col + 12), (short)(gy + 46),
            (short)(right - 12), (short)(gy + 62));
    SetRect(&r->streaming_label, (short)(col + 12), (short)(gy + 70),
            (short)(right - 12), (short)(gy + 84));
    SetRect(&r->predictive, (short)(col + 12), (short)(gy + 88),
            (short)(right - 12), (short)(gy + 104));
    SetRect(&r->interlace, (short)(col + 12), (short)(gy + 108),
            (short)(right - 12), (short)(gy + 124));
    SetRect(&r->rate_line, (short)(col + 12), (short)(gy + 132),
            (short)(right - 12), (short)(gy + 148));

    SetRect(&r->tri, col, (short)(r->group.bottom + 12),
            (short)(col + 12), (short)(r->group.bottom + 24));
    SetRect(&r->tri_label, (short)(col + 18), (short)(r->group.bottom + 10),
            right, (short)(r->group.bottom + 26));
    SetRect(&r->chunk, (short)(col + 10), (short)(r->tri.bottom + 6),
            (short)(right - 12), (short)(r->tri.bottom + 26));
    SetRect(&r->pace, (short)(col + 10), (short)(r->tri.bottom + 32),
            (short)(right - 12), (short)(r->tri.bottom + 52));

    SetRect(&r->take_btn, x0, buttons_y, (short)(x0 + 130),
            (short)(buttons_y + 20));
    SetRect(&r->send_btn, (short)(x0 + 140), buttons_y,
            (short)(x0 + 290), (short)(buttons_y + 20));
    SetRect(&r->stream_btn, (short)(x0 + 300), buttons_y,
            (short)(x0 + 450), (short)(buttons_y + 20));
}

static void set_status(const char *text)
{
    snprintf(g_status, sizeof g_status, "%s", text);
    if (g_owner != NULL) {
        Rect content;

        GetWindowPortBounds(g_owner, &content);
        content.top = (short)(content.bottom - 23);
        InvalWindowRect(g_owner, &content);
    }
}

static void load_controls_from_prefs(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    SetControlValue(g_depth, item_for(k_depths, 6, prefs.shot_depth, 4));
    SetControlValue(g_chunk, item_for(k_chunks, 6, prefs.chunk_kb, 4));
    SetControlValue(g_pace, item_for(k_paces, 5, prefs.pace_ms, 1));
    SetControlValue(g_pack, prefs.shot_pack ? 1 : 0);
    SetControlValue(g_predictive, prefs.predictive ? 1 : 0);
    SetControlValue(g_interlace, prefs.interlace ? 1 : 0);
}

static void save_controls_to_prefs(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.shot_depth = k_depths[GetControlValue(g_depth) - 1];
    prefs.chunk_kb = k_chunks[GetControlValue(g_chunk) - 1];
    prefs.pace_ms = k_paces[GetControlValue(g_pace) - 1];
    prefs.shot_pack = GetControlValue(g_pack) != 0;
    prefs.predictive = GetControlValue(g_predictive) != 0;
    prefs.interlace = GetControlValue(g_interlace) != 0;
    now_prefs_save(&prefs);
}

static void take_screenshot(void)
{
    char err[96];
    char line[120];
    NowPrefs prefs;

    now_prefs_load(&prefs);
    set_status("Capturing...");
    if (now_screenshot(prefs.shot_depth, 1, true, &g_last, err,
                       sizeof err) != 0) {
        g_have_shot = false;
        snprintf(line, sizeof line, "Failed: %.90s", err);
        set_status(line);
        return;
    }
    g_have_shot = true;
    snprintf(line, sizeof line,
             "capture %ld ms - encode %ld ms - PICT %ld KB - Saved: %.28s",
             g_last.capture_ms, g_last.encode_ms,
             g_last.pict_bytes / 1024, g_last.saved_name);
    set_status(line);
    if (g_owner != NULL) {
        Rect r = g_r.well;

        r.bottom = g_r.caption.bottom;
        InvalWindowRect(g_owner, &r);
    }
}

/* --- module ops --------------------------------------------------------- */

static ControlRef make_popup(const Rect *bounds, const char *title,
                             short menu_id, short title_width)
{
    Str255 text;

    CopyCStringToPascal(title, text);
    /* classic popup CDEF: value = title justification, min = MENU id,
       max = title width in pixels */
    return NewControl(g_owner, bounds, text, false, popupTitleLeftJust,
                      menu_id, title_width, popupMenuProc, 0);
}

static OSErr shots_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    compute_rects(body, &g_r);
    g_status[0] = '\0';
    g_shown_peer[0] = '\0';
    g_shown_connected = false;
    g_shown_streaming = false;
    g_shown_rate = -2;

    g_depth = make_popup(&g_r.depth, "Depth:", kDepthMenuID, 48);
    CopyCStringToPascal("Compress on wire (PackBits)", text);
    g_pack = NewControl(owner, &g_r.pack, text, false, 0, 0, 1,
                        checkBoxProc, 0);
    CopyCStringToPascal("Predictive capture", text);
    g_predictive = NewControl(owner, &g_r.predictive, text, false, 0, 0, 1,
                              checkBoxProc, 0);
    CopyCStringToPascal("Interlaced fields", text);
    g_interlace = NewControl(owner, &g_r.interlace, text, false, 0, 0, 1,
                             checkBoxProc, 0);
    text[0] = 0;
    g_tri = NewControl(owner, &g_r.tri, text, false, 0, 0, 1,
                       kControlTriangleAutoToggleProc, 0);
    g_chunk = make_popup(&g_r.chunk, "Chunk:", kChunkMenuID, 52);
    g_pace = make_popup(&g_r.pace, "Pacing:", kPaceMenuID, 52);
    CopyCStringToPascal("Take Screenshot", text);
    g_take = NewControl(owner, &g_r.take_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    CopyCStringToPascal("Send", text);
    g_send = NewControl(owner, &g_r.send_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    CopyCStringToPascal("Start Streaming", text);
    g_stream = NewControl(owner, &g_r.stream_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    if (g_depth == NULL || g_pack == NULL || g_predictive == NULL
        || g_interlace == NULL || g_tri == NULL || g_chunk == NULL
        || g_pace == NULL || g_take == NULL || g_send == NULL
        || g_stream == NULL) {
        return memFullErr;
    }
    g_expanded = false;
    load_controls_from_prefs();
    return noErr;
}

static void shots_dispose(void)
{
    g_owner = NULL;
    g_depth = NULL;
    g_pack = NULL;
    g_predictive = NULL;
    g_interlace = NULL;
    g_tri = NULL;
    g_chunk = NULL;
    g_pace = NULL;
    g_take = NULL;
    g_send = NULL;
    g_stream = NULL;
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

static void shots_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_depth, visible);
    show_control(g_pack, visible);
    show_control(g_predictive, visible);
    show_control(g_interlace, visible);
    show_control(g_tri, visible);
    show_control(g_chunk, visible && g_expanded);
    show_control(g_pace, visible && g_expanded);
    show_control(g_take, visible);
    show_control(g_send, visible);
    show_control(g_stream, visible);
}

static void move_control(ControlRef control, const Rect *r)
{
    if (control == NULL) {
        return;
    }
    MoveControl(control, r->left, r->top);
    SizeControl(control, (SInt16)(r->right - r->left),
                (SInt16)(r->bottom - r->top));
}

static void shots_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    move_control(g_depth, &g_r.depth);
    move_control(g_pack, &g_r.pack);
    move_control(g_predictive, &g_r.predictive);
    move_control(g_interlace, &g_r.interlace);
    move_control(g_tri, &g_r.tri);
    move_control(g_chunk, &g_r.chunk);
    move_control(g_pace, &g_r.pace);
    move_control(g_take, &g_r.take_btn);
    move_control(g_send, &g_r.send_btn);
    move_control(g_stream, &g_r.stream_btn);
}

static void draw_preview_well(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    Rect src;
    GWorldPtr preview = now_screenshot_preview(&src);
    Str255 text;

    GetBackColor(&saved_back);
    RGBForeColor(&black);
    FrameRect(&g_r.well);
    if (preview == NULL) {
        Rect inner = g_r.well;

        InsetRect(&inner, 1, 1);
        EraseRect(&inner);
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        MoveTo((short)(g_r.well.left + 16),
               (short)((g_r.well.top + g_r.well.bottom) / 2));
        CopyCStringToPascal("No screenshot yet.", text);
        DrawString(text);
        return;
    }
    {
        PixMapHandle pixels = GetGWorldPixMap(preview);
        long sw = src.right - src.left;
        long sh = src.bottom - src.top;
        long ww = g_r.well.right - g_r.well.left - 2;
        long wh = g_r.well.bottom - g_r.well.top - 2;
        long dw = ww;
        long dh;
        Rect dst;
        Rect inner = g_r.well;

        if (sw <= 0 || sh <= 0 || pixels == NULL || !LockPixels(pixels)) {
            return;
        }
        dh = sh * dw / sw;
        if (dh > wh) {
            dh = wh;
            dw = sw * dh / sh;
        }
        InsetRect(&inner, 1, 1);
        EraseRect(&inner);
        SetRect(&dst, 0, 0, (short)dw, (short)dh);
        OffsetRect(&dst, (short)(inner.left + (ww - dw) / 2),
                   (short)(inner.top + (wh - dh) / 2));
        RGBForeColor(&black);
        RGBBackColor(&white);
        CopyBits((BitMap *)*pixels,
                 GetPortBitMapForCopyBits(GetWindowPort(g_owner)),
                 &src, &dst, srcCopy, NULL);
        RGBBackColor(&saved_back);
        UnlockPixels(pixels);
    }
}

static void shots_draw(void)
{
    Str255 text;
    char line[96];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    draw_preview_well();

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    if (g_have_shot) {
        snprintf(line, sizeof line, "%d x %d", g_last.width,
                 g_last.height);
        MoveTo(g_r.caption.left, (short)(g_r.caption.top + 12));
        CopyCStringToPascal(line, text);
        DrawString(text);
        snprintf(line, sizeof line, "%d-bit", g_last.depth);
        CopyCStringToPascal(line, text);
        MoveTo((short)(g_r.caption.right - StringWidth(text)),
               (short)(g_r.caption.top + 12));
        DrawString(text);
    }

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    MoveTo(g_r.streaming_label.left, (short)(g_r.streaming_label.top + 11));
    CopyCStringToPascal("Streaming", text);
    DrawString(text);
    MoveTo(g_r.tri_label.left, (short)(g_r.tri_label.top + 12));
    CopyCStringToPascal("Advanced Transport", text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    {
        long ms = now_wire_stream_interval_ms();

        if (ms < 0) {
            snprintf(line, sizeof line, "Rate: Automatic");
        } else if (ms == 0) {
            snprintf(line, sizeof line, "Rate: as fast as the wire");
        } else {
            snprintf(line, sizeof line, "Rate: at most one per %ld ms",
                     ms);
        }
        MoveTo(g_r.rate_line.left, (short)(g_r.rate_line.top + 11));
        CopyCStringToPascal(line, text);
        DrawString(text);
    }
}

static Boolean shots_click(const EventRecord *event, Point local)
{
    ControlRef control;
    SInt16 part;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    /* FindControlUnderMouse, not FindControl: the window has a root
       control now, and FindControl does not understand embedding. */
    control = FindControlUnderMouse(local, g_owner, &part);
    if (control == NULL) {
        return false;
    }
    if (control == g_depth || control == g_chunk || control == g_pace) {
        TrackControl(control, local, (ControlActionUPP)-1L);
        save_controls_to_prefs();
        return true;
    }
    if (control == g_tri) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            g_expanded = GetControlValue(g_tri) != 0;
            show_control(g_chunk, g_visible && g_expanded);
            show_control(g_pace, g_visible && g_expanded);
            {
                Rect r = g_r.chunk;

                r.bottom = g_r.pace.bottom;
                InsetRect(&r, -4, -4);
                InvalWindowRect(g_owner, &r);
            }
        }
        return true;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return control == g_pack || control == g_predictive
            || control == g_interlace || control == g_take
            || control == g_send || control == g_stream;
    }
    if (control == g_pack || control == g_predictive
        || control == g_interlace) {
        SetControlValue(control, !GetControlValue(control));
        save_controls_to_prefs();
        return true;
    }
    if (control == g_take) {
        take_screenshot();
        return true;
    }
    if (control == g_send) {
        char err[96];

        if (now_wire_offer_shot(err, sizeof err) != 0) {
            set_status(err);
        }
        return true;
    }
    if (control == g_stream) {
        char err[96];

        if (now_wire_stream_active()) {
            now_wire_stream_stop();
        } else if (now_wire_stream_request(err, sizeof err) != 0) {
            set_status(err);
        }
        return true;
    }
    return false;
}

static Boolean shots_key(const EventRecord *event)
{
    (void)event;
    return false;                     /* nothing here takes typing */
}

static void shots_activate(Boolean active)
{
    ControlRef controls[10];
    int i;

    controls[0] = g_depth;
    controls[1] = g_pack;
    controls[2] = g_predictive;
    controls[3] = g_interlace;
    controls[4] = g_tri;
    controls[5] = g_chunk;
    controls[6] = g_pace;
    controls[7] = g_take;
    controls[8] = g_send;
    controls[9] = g_stream;
    for (i = 0; i < 10; ++i) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
}

static void shots_idle(void)
{
    char peer[24];
    Boolean connected;
    Boolean streaming;
    long rate;
    Str255 text;
    char title[64];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    connected = conn_is_connected();
    streaming = now_wire_stream_active();
    conn_peer_label(peer, sizeof peer);

    if (connected != g_shown_connected
        || strcmp(peer, g_shown_peer) != 0
        || streaming != g_shown_streaming) {
        g_shown_connected = connected;
        g_shown_streaming = streaming;
        strcpy(g_shown_peer, peer);
        /* Peer actions dim when there is no peer; local capture and the
           settings stay usable. */
        HiliteControl(g_send, connected ? 0 : 255);
        HiliteControl(g_stream, (connected || streaming) ? 0 : 255);
        snprintf(title, sizeof title, "Send to %.20s", peer);
        CopyCStringToPascal(title, text);
        SetControlTitle(g_send, text);
        if (streaming) {
            CopyCStringToPascal("Stop Streaming", text);
        } else {
            CopyCStringToPascal("Start Streaming", text);
        }
        SetControlTitle(g_stream, text);
    }
    rate = now_wire_stream_interval_ms();
    if (rate != g_shown_rate) {
        g_shown_rate = rate;
        InvalWindowRect(g_owner, &g_r.rate_line);
    }
}

static void shots_status_text(char *out, long cap)
{
    if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        snprintf(out, (size_t)cap, "Ready.");
    }
}

static const WorkshopModuleOps k_ops = {
    shots_create,
    shots_dispose,
    shots_show,
    shots_layout,
    shots_draw,
    shots_click,
    shots_key,
    shots_activate,
    shots_idle,
    shots_status_text
};

const WorkshopModuleOps *screenshots_module_ops(void)
{
    return &k_ops;
}

void screenshots_module_note(const char *line)
{
    if (g_owner == NULL) {
        return;
    }
    set_status(line);
}
