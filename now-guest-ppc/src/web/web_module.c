#include "web_module.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "prefs.h"
#include "pump.h"
#include "web_model.h"
#include "web_port_dialog.h"

enum {
    kProfileMenuID = 139,
    kLensMenuID = 140,
    kMargin = 16,
    kLineHeight = 17
};

typedef struct {
    Rect group;
    Rect endpoint;
    Rect port_button;
    Rect profile;
    Rect lens;
    Rect start_url;
    Rect direct_note;
    Rect relay_note;
} WebRects;

static WindowRef g_owner;
static Boolean g_visible;
static WebRects g_r;
static ControlRef g_group;
static ControlRef g_port;
static ControlRef g_profile;
static ControlRef g_lens;
static char g_status[128];

static void compute_rects(const Rect *body)
{
    short left = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short top = (short)(body->top + kMargin);
    short inner = (short)(left + 16);

    SetRect(&g_r.group, left, top, right, (short)(top + 190));
    SetRect(&g_r.endpoint, inner, (short)(top + 25),
            (short)(right - 130), (short)(top + 25 + kLineHeight));
    SetRect(&g_r.port_button, (short)(right - 118), (short)(top + 21),
            (short)(right - 12), (short)(top + 41));
    SetRect(&g_r.profile, inner, (short)(top + 54),
            (short)(right - 12), (short)(top + 74));
    SetRect(&g_r.lens, inner, (short)(top + 82),
            (short)(right - 12), (short)(top + 102));
    SetRect(&g_r.start_url, inner, (short)(top + 116),
            (short)(right - 12), (short)(top + 116 + kLineHeight));
    SetRect(&g_r.direct_note, inner, (short)(top + 140),
            (short)(right - 12), (short)(top + 140 + kLineHeight));
    SetRect(&g_r.relay_note, inner, (short)(top + 158),
            (short)(right - 12), (short)(top + 176));
}

static void show_control(ControlRef control, Boolean visible)
{
    if (control == NULL) return;
    if (visible) ShowControl(control); else HideControl(control);
}

static void move_control(ControlRef control, const Rect *r)
{
    if (control == NULL) return;
    MoveControl(control, r->left, r->top);
    SizeControl(control, (SInt16)(r->right - r->left),
                (SInt16)(r->bottom - r->top));
}

static ControlRef make_popup(const Rect *bounds, const char *title,
                             short menu_id, short title_width)
{
    Str255 text;
    CopyCStringToPascal(title, text);
    return now_control_new(g_owner, bounds, text, false,
                           popupTitleLeftJust, menu_id, title_width,
                           popupMenuProc, 0);
}

static void load_controls(void)
{
    NowPrefs prefs;
    now_prefs_load(&prefs);
    SetControlValue(g_profile,
        (short)now_web_profile_sanitize(prefs.web_profile));
    SetControlValue(g_lens, (short)now_web_lens_sanitize(prefs.web_lens));
}

static void invalidate_words(void)
{
    if (g_owner != NULL) InvalWindowRect(g_owner, &g_r.group);
}

static OSErr web_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    g_owner = owner;
    g_status[0] = '\0';
    compute_rects(body);
    CopyCStringToPascal("Direct Host Listener", text);
    g_group = now_control_new(owner, &g_r.group, text, false, 0, 0, 0,
                              kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Change Port\xC9", text);
    g_port = now_control_new(owner, &g_r.port_button, text, false, 0, 0, 1,
                             pushButProc, 0);
    g_profile = make_popup(&g_r.profile, "Browser:", kProfileMenuID, 58);
    g_lens = make_popup(&g_r.lens, "View:", kLensMenuID, 58);
    if (g_group == NULL || g_port == NULL || g_profile == NULL
        || g_lens == NULL) return memFullErr;
    load_controls();
    return noErr;
}

static void web_dispose(void)
{
    g_owner = NULL;
    g_group = g_port = g_profile = g_lens = NULL;
}

static void web_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_group, visible);
    show_control(g_port, visible);
    show_control(g_profile, visible);
    show_control(g_lens, visible);
    if (visible) load_controls();
}

static void web_layout(const Rect *body)
{
    compute_rects(body);
    move_control(g_group, &g_r.group);
    move_control(g_port, &g_r.port_button);
    move_control(g_profile, &g_r.profile);
    move_control(g_lens, &g_r.lens);
}

static void draw_line(const Rect *r, const char *line, TruncCode trunc)
{
    Str255 text;
    MoveTo(r->left, (short)(r->top + 12));
    CopyCStringToPascal(line, text);
    TruncString((short)(r->right - r->left), text, trunc);
    DrawString(text);
}

static void web_draw(void)
{
    NowPrefs prefs;
    char line[220];
    char value[180];
    NowWebProfile profile;
    NowWebLens lens;

    if (g_owner == NULL || !g_visible) return;
    now_prefs_load(&prefs);
    profile = now_web_profile_sanitize(prefs.web_profile);
    lens = now_web_lens_sanitize(prefs.web_lens);
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    now_web_endpoint(prefs.host, prefs.web_proxy_port, value, sizeof value);
    snprintf(line, sizeof line, "HTTP proxy: %s", value);
    draw_line(&g_r.endpoint, line, truncEnd);
    now_web_start_url(prefs.host, prefs.web_proxy_port, profile, lens,
                      value, sizeof value);
    snprintf(line, sizeof line, "Start page: %s", value);
    draw_line(&g_r.start_url, line, truncMiddle);
    draw_line(&g_r.direct_note,
              "Address comes from Connection: QEMU uses 10.0.2.2; hardware uses the host Mac's LAN address.",
              truncEnd);
    draw_line(&g_r.relay_note,
              "Guest-local relay is unavailable until Open Transport target tests prove it.",
              truncEnd);
}

static void save_popup_settings(void)
{
    NowPrefs prefs;
    now_prefs_load(&prefs);
    prefs.web_profile =
        (short)now_web_profile_sanitize(GetControlValue(g_profile));
    prefs.web_lens = (short)now_web_lens_sanitize(GetControlValue(g_lens));
    if (now_prefs_save(&prefs) != noErr) {
        strcpy(g_status, "The Web settings could not be remembered.");
    } else {
        strcpy(g_status, "Saved. The displayed start URL carries this browser and view.");
    }
    invalidate_words();
}

static Boolean web_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    (void)event;
    if (!g_visible || FindControl(local, g_owner, &control) == 0) return false;
    if (control == g_profile || control == g_lens) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            save_popup_settings();
        }
        return true;
    }
    if (control == g_port) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            NowPrefs prefs;
            unsigned short port;
            now_prefs_load(&prefs);
            port = prefs.web_proxy_port;
            if (now_web_edit_port(&port)) {
                prefs.web_proxy_port = port;
                if (now_prefs_save(&prefs) == noErr) {
                    strcpy(g_status, "Port saved. Use the same port in the host Web module.");
                } else {
                    strcpy(g_status, "The proxy port could not be remembered.");
                }
                invalidate_words();
            }
        }
        return true;
    }
    return false;
}

static void web_activate(Boolean active)
{
    ControlRef controls[] = { g_port, g_profile, g_lens };
    short i;
    for (i = 0; i < 3; ++i) {
        if (controls[i] == NULL) continue;
        if (active) ActivateControl(controls[i]); else DeactivateControl(controls[i]);
    }
}

static void web_status(char *out, long cap)
{
    const char *text = g_status[0] ? g_status
        : "Direct mode reaches the host; no guest loopback relay is claimed.";
    if (cap <= 0) return;
    strncpy(out, text, (size_t)cap - 1);
    out[cap - 1] = '\0';
}

static const WorkshopModuleOps k_ops = {
    web_create, web_dispose, web_show, web_layout, web_draw, web_click,
    NULL, web_activate, NULL, web_status, NULL
};

const WorkshopModuleOps *web_module_ops(void) { return &k_ops; }
