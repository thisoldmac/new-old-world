#include "files_share_view.h"

#include <stdio.h>
#include <string.h>

#include "fileshare.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"

/* Layout inside the area the module hands over:
     root name + "can browse" line   (drawn)
     [x] Share entire boot volume    [Choose Folder...]
     [====== progress ======]        (only while bytes move)
     [Send File...] [Get files into: X] [Open]                       */

enum {
    kRowHeight = 20,
    kButtonHeight = 20
};

typedef struct {
    Rect root_line;
    Rect explain_line;
    Rect boot_check;
    Rect choose_btn;
    Rect progress;
    Rect send_btn;
    Rect into_btn;
    Rect reveal_btn;
} ShareRects;

static WindowRef g_owner;
static Rect g_area;
static ShareRects g_r;
static Boolean g_visible;

static ControlRef g_boot;
static ControlRef g_choose;
static ControlRef g_send;
static ControlRef g_into;
static ControlRef g_reveal;
static ControlRef g_bar;

static char g_note[128];
/* Idle caches: enable state and bar value repaint only on change. */
static short g_send_hilite = -1;
static Boolean g_bar_shown;
static short g_bar_value = -1;

static void compute_rects(const Rect *area, ShareRects *r)
{
    short x0 = area->left;
    short right = area->right;
    short y = area->top;
    short buttons_y = (short)(area->bottom - kButtonHeight - 2);

    SetRect(&r->root_line, x0, y, right, (short)(y + 14));
    SetRect(&r->explain_line, x0, (short)(y + 16), right, (short)(y + 30));
    SetRect(&r->boot_check, x0, (short)(y + 36), (short)(x0 + 200),
            (short)(y + 52));
    SetRect(&r->choose_btn, (short)(right - 118), (short)(y + 34), right,
            (short)(y + 34 + kButtonHeight));
    SetRect(&r->progress, x0, (short)(y + 62), right, (short)(y + 74));
    SetRect(&r->send_btn, x0, buttons_y, (short)(x0 + 100),
            (short)(buttons_y + kButtonHeight));
    SetRect(&r->into_btn, (short)(x0 + 110), buttons_y,
            (short)(x0 + 310), (short)(buttons_y + kButtonHeight));
    SetRect(&r->reveal_btn, (short)(x0 + 320), buttons_y,
            (short)(x0 + 380), (short)(buttons_y + kButtonHeight));
}

static void refresh_into_title(void)
{
    char where[64];
    char label[96];
    Str255 text;

    if (g_into == NULL) {
        return;
    }
    now_files_downloads_name(where, sizeof where);
    snprintf(label, sizeof label, "Get files into: %.31s", where);
    CopyCStringToPascal(label, text);
    SetControlTitle(g_into, text);
}

/* Boot-volume sharing changes only when the checkbox is clicked, so
   preferences are read THEN - never on the idle path (the panel this
   view descends from once starved a transfer doing that). */
static void sync_share_controls(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    SetControlValue(g_boot, prefs.share_boot ? 1 : 0);
    HiliteControl(g_choose, prefs.share_boot ? 255 : 0);
}

static void sync_send_control(void)
{
    short want;

    if (g_send == NULL || !g_visible) {
        return;
    }
    want = (conn_is_connected()
            && now_wire_send_state(NULL, NULL, NULL, 0) == kSendNothing)
        ? 0 : 255;
    if (want != g_send_hilite) {
        g_send_hilite = want;
        HiliteControl(g_send, want);
    }
}

Boolean files_share_create(WindowRef owner, const Rect *area)
{
    Str255 text;

    g_owner = owner;
    g_area = *area;
    compute_rects(area, &g_r);
    g_note[0] = '\0';
    g_send_hilite = -1;
    g_bar_shown = false;
    g_bar_value = -1;

    CopyCStringToPascal("Share entire boot volume", text);
    g_boot = NewControl(owner, &g_r.boot_check, text, false, 0, 0, 1,
                        checkBoxProc, 0);
    CopyCStringToPascal("Choose Folder...", text);
    g_choose = NewControl(owner, &g_r.choose_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    CopyCStringToPascal("Send File...", text);
    g_send = NewControl(owner, &g_r.send_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    text[0] = 0;
    g_into = NewControl(owner, &g_r.into_btn, text, false, 0, 0, 1,
                        pushButProc, 0);
    CopyCStringToPascal("Open", text);
    g_reveal = NewControl(owner, &g_r.reveal_btn, text, false, 0, 0, 1,
                          pushButProc, 0);
    /* Native determinate bar; scaled to 0..1000 below. */
    g_bar = NewControl(owner, &g_r.progress, text, false, 0, 0, 1000,
                       kControlProgressBarProc, 0);
    if (g_boot == NULL || g_choose == NULL || g_send == NULL
        || g_into == NULL || g_reveal == NULL || g_bar == NULL) {
        return false;
    }
    refresh_into_title();
    sync_share_controls();
    return true;
}

void files_share_dispose(void)
{
    g_owner = NULL;
    g_boot = NULL;
    g_choose = NULL;
    g_send = NULL;
    g_into = NULL;
    g_reveal = NULL;
    g_bar = NULL;
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

void files_share_layout(const Rect *area)
{
    g_area = *area;
    compute_rects(area, &g_r);
    if (g_boot == NULL) {
        return;
    }
    MoveControl(g_boot, g_r.boot_check.left, g_r.boot_check.top);
    MoveControl(g_choose, g_r.choose_btn.left, g_r.choose_btn.top);
    MoveControl(g_send, g_r.send_btn.left, g_r.send_btn.top);
    MoveControl(g_into, g_r.into_btn.left, g_r.into_btn.top);
    MoveControl(g_reveal, g_r.reveal_btn.left, g_r.reveal_btn.top);
    MoveControl(g_bar, g_r.progress.left, g_r.progress.top);
    SizeControl(g_bar, (SInt16)(g_r.progress.right - g_r.progress.left),
                (SInt16)(g_r.progress.bottom - g_r.progress.top));
}

void files_share_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_boot, visible);
    show_control(g_choose, visible);
    show_control(g_send, visible);
    show_control(g_into, visible);
    show_control(g_reveal, visible);
    show_control(g_bar, visible && g_bar_shown);
    if (visible) {
        g_send_hilite = -1;
        sync_share_controls();
        sync_send_control();
        refresh_into_title();
    }
}

void files_share_draw(void)
{
    Str255 text;
    char root[160];
    char line[120];
    char peer[24];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    now_files_root_name(root, sizeof root);
    MoveTo(g_r.root_line.left, (short)(g_r.root_line.top + 11));
    if (strlen(root) > 100) {
        root[100] = '\0';
    }
    CopyCStringToPascal(root, text);
    TruncString((short)(g_r.root_line.right - g_r.root_line.left), text,
                truncMiddle);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    conn_peer_label(peer, sizeof peer);
    snprintf(line, sizeof line,
             "%.20s can browse this folder and everything inside it.",
             peer);
    MoveTo(g_r.explain_line.left, (short)(g_r.explain_line.top + 11));
    CopyCStringToPascal(line, text);
    TruncString((short)(g_r.explain_line.right - g_r.explain_line.left),
                text, truncEnd);
    DrawString(text);
}

Boolean files_share_click(const EventRecord *event, Point local)
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
    if (control != g_boot && control != g_choose && control != g_send
        && control != g_into && control != g_reveal) {
        return false;
    }
    if (TrackControl(control, local, now_pump_action()) == 0) {
        return true;
    }
    if (control == g_choose) {
        char why[128];
        int rc = now_files_choose_root(why, sizeof why);

        if (rc > 0) {
            g_note[0] = '\0';
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "Not shared: %.100s", why);
        }
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_boot) {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        prefs.share_boot = !prefs.share_boot;
        if (now_prefs_save(&prefs) != noErr) {
            snprintf(g_note, sizeof g_note, "Could not save that setting");
        } else {
            g_note[0] = '\0';
        }
        sync_share_controls();
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_send) {
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
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_into) {
        char why[128];
        int rc = now_files_choose_downloads(why, sizeof why);

        if (rc > 0) {
            refresh_into_title();
            snprintf(g_note, sizeof g_note, "Files you get land there");
        } else if (rc < 0) {
            snprintf(g_note, sizeof g_note, "%.110s", why);
        }
        InvalWindowRect(g_owner, &g_area);
    } else if (control == g_reveal) {
        if (now_files_reveal_downloads() != kFilesOK) {
            snprintf(g_note, sizeof g_note, "Could not open that folder");
            InvalWindowRect(g_owner, &g_area);
        }
    }
    return true;
}

void files_share_activate(Boolean active)
{
    ControlRef controls[6];
    int i;

    controls[0] = g_boot;
    controls[1] = g_choose;
    controls[2] = g_send;
    controls[3] = g_into;
    controls[4] = g_reveal;
    controls[5] = g_bar;
    for (i = 0; i < 6; ++i) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
    if (active && g_visible) {
        /* Send and Choose carry their own enable state; re-derive it
           rather than assuming everything is enabled. */
        g_send_hilite = -1;
        sync_share_controls();
        sync_send_control();
    }
}

/* Every event-loop pass: two in-memory reads, and control updates only
   when a shown value would actually change. */
void files_share_idle(void)
{
    long sent = 0, total = 0;
    SendPhase phase;
    Boolean moving;
    short value;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    sync_send_control();
    phase = now_wire_send_state(&sent, &total, NULL, 0);
    /* Only once bytes are moving: an empty bar sitting at zero while
       the host has not answered reads as "stuck" when the truth is
       "waiting" - the status line already says which. */
    moving = (phase == kSendSending && total > 0);
    value = moving ? (short)(1000L * sent / total) : 0;
    if (moving != g_bar_shown) {
        g_bar_shown = moving;
        show_control(g_bar, g_visible && moving);
    }
    if (moving && value != g_bar_value) {
        g_bar_value = value;
        SetControlValue(g_bar, value);
    }
}

void files_share_status(char *out, long cap)
{
    snprintf(out, (size_t)cap, "%s", g_note);
}

void files_share_note(const char *line)
{
    if (g_owner == NULL) {
        return;
    }
    snprintf(g_note, sizeof g_note, "%.120s", line);
}
