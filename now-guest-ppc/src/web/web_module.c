#include "web_module.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "prefs.h"
#include "pump.h"
#include "web_model.h"
#include "web_port_dialog.h"
#include "web_proxy_ot.h"

enum {
    kMargin = 16,
    kLineHeight = 17
};

typedef struct {
    Rect group;
    Rect endpoint;
    Rect port_button;
    Rect direct_note;
    Rect relay_note;
} WebRects;

static WindowRef g_owner;
static Boolean g_visible;
static WebRects g_r;
static ControlRef g_group;
static ControlRef g_port;
static char g_status[128];

static void compute_rects(const Rect *body)
{
    short left = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short top = (short)(body->top + kMargin);
    short inner = (short)(left + 16);

    SetRect(&g_r.group, left, top, right, (short)(top + 126));
    SetRect(&g_r.endpoint, inner, (short)(top + 25),
            (short)(right - 130), (short)(top + 25 + kLineHeight));
    SetRect(&g_r.port_button, (short)(right - 118), (short)(top + 21),
            (short)(right - 12), (short)(top + 41));
    SetRect(&g_r.direct_note, inner, (short)(top + 58),
            (short)(right - 12), (short)(top + 58 + kLineHeight));
    SetRect(&g_r.relay_note, inner, (short)(top + 82),
            (short)(right - 12), (short)(top + 112));
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
    CopyCStringToPascal("Browser Proxy", text);
    g_group = now_control_new(owner, &g_r.group, text, false, 0, 0, 0,
                              kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Change Port\xC9", text);
    g_port = now_control_new(owner, &g_r.port_button, text, false, 0, 0, 1,
                             pushButProc, 0);
    if (g_group == NULL || g_port == NULL) return memFullErr;
    return noErr;
}

static void web_dispose(void)
{
    g_owner = NULL;
    g_group = g_port = NULL;
}

static void web_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_group, visible);
    show_control(g_port, visible);
}

static void web_layout(const Rect *body)
{
    compute_rects(body);
    move_control(g_group, &g_r.group);
    move_control(g_port, &g_r.port_button);
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

    if (g_owner == NULL || !g_visible) return;
    now_prefs_load(&prefs);
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    now_web_endpoint("127.0.0.1", prefs.web_proxy_port, value, sizeof value);
    snprintf(line, sizeof line, "HTTP proxy: %s", value);
    draw_line(&g_r.endpoint, line, truncEnd);
    draw_line(&g_r.direct_note,
              "Set the browser's HTTP proxy to this loopback address. It is not exposed on the LAN.",
              truncEnd);
    draw_line(&g_r.relay_note,
              "Pages travel over New Old World's existing connection. Choose browser and page compatibility on this Mac.",
              truncEnd);
}

static Boolean web_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    (void)event;
    if (!g_visible || FindControl(local, g_owner, &control) == 0) return false;
    if (control == g_port) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            NowPrefs prefs;
            unsigned short port;
            now_prefs_load(&prefs);
            port = prefs.web_proxy_port;
            if (now_web_edit_port(&port)) {
                prefs.web_proxy_port = port;
                if (now_prefs_save(&prefs) == noErr) {
                    char reason[96];
                    if (now_web_proxy_start(port, reason, sizeof reason) == 0) {
                        strcpy(g_status, "Proxy restarted on the new loopback port.");
                    } else {
                        strncpy(g_status, reason, sizeof g_status - 1);
                        g_status[sizeof g_status - 1] = '\0';
                    }
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
    if (g_port == NULL) return;
    if (active) ActivateControl(g_port); else DeactivateControl(g_port);
}

static void web_status(char *out, long cap)
{
    char live[128];
    const char *text;
    now_web_proxy_status(live, sizeof live);
    text = g_status[0] ? g_status : live;
    if (cap <= 0) return;
    strncpy(out, text, (size_t)cap - 1);
    out[cap - 1] = '\0';
}

static const WorkshopModuleOps k_ops = {
    web_create, web_dispose, web_show, web_layout, web_draw, web_click,
    NULL, web_activate, NULL, web_status, NULL
};

const WorkshopModuleOps *web_module_ops(void) { return &k_ops; }
