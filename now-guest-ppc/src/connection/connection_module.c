#include "connection_module.h"

#include <stdio.h>
#include <string.h>

#include "conn_edit_dialog.h"
#include "conn_fields.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"
#include "confirm.h"
#include "update_model.h"
#include "update_status.h"
#include "workshop_scene_text.h"

/* The page has two halves: an "Other Mac" group that SHOWS the saved
   target (address and port drawn read-only, changed through the Edit
   button's movable-modal dialog - conn_edit_dialog.c - because the
   Appearance edit-text control takes no input in this app), and an
   "At a glance" group of live read-only rows fed by conn_snapshot().
   Nothing here services the wire or blocks; actions hand the target to
   wire.c and return. The Edit button opens a modal, which is main-loop
   code, never pumped wire code, so the pump.h rule holds. */

enum {
    kRetryMenuID = 133,
    /* "Other Mac", "Connected", "Last traffic", "Wire", "This Mac", then
       "Round trip" - the guest already times its own ping/pong
       (wire.c :: g.last_rtt_ms); this is the sixth row rather than a
       second card, and the one row with a button beside it. */
    kGlanceRowCount = 6,
    kRttRow = kGlanceRowCount - 1,
    kMargin = 12,
    kFieldHeight = 16,
    kButtonHeight = 20,
    kTestButtonWidth = 56,
    /* Stack the two groups when the body is narrower than this. */
    kStackBelow = 560
};

typedef struct {
    Rect other_group;
    Rect addr_line;       /* "Address:  10.0.2.2", drawn read-only */
    Rect port_line;       /* "Port:  5250", drawn read-only */
    Rect edit_btn;        /* opens the movable-modal editor */
    Rect retry_popup;
    Rect auto_box;
    Rect glance_group;
    Rect test_btn;         /* beside the Round trip row */
    Rect update_group;
    Rect app_update_line;
    Rect ext_update_line;
    Rect app_update_btn;
    Rect ext_update_btn;
    Rect action_btn;
    Rect revert_btn;
    Rect save_btn;
} ConnRects;

static WindowRef g_owner;
static Rect g_body;
static ConnRects g_r;
static Boolean g_visible;

static ControlRef g_group_other;
static ControlRef g_edit;
static ControlRef g_retry;
static ControlRef g_auto;
static ControlRef g_group_glance;
static ControlRef g_test;
static ControlRef g_group_update;
static ControlRef g_update_app;
static ControlRef g_update_ext;
static ControlRef g_action;
static ControlRef g_revert;
static ControlRef g_save;

/* The edited target, the module's own state now that no control holds
   it. Seeded from prefs, changed by the Edit dialog, persisted by Save. */
static char g_host[64];
static unsigned short g_port_val;

/* Transient result of the last action, shown in the status placard
   until the next action or module switch. */
static char g_status[120];

/* Glance cache: the five value strings plus the failure line, repainted
   only when the words change. */
static char g_vals[kGlanceRowCount][64];
static char g_fail_line[120];
static NowConnActionTitle g_action_title;
static char g_update_lines[3][128];

static const char *k_glance_labels[kGlanceRowCount] = {
    "Other Mac", "Connected", "Last traffic", "Wire", "This Mac",
    "Round trip"
};

static char g_this_mac[64];           /* computed once; it cannot change */

static void compute_this_mac(void)
{
    long sys = 0;
    long carbon = 0;
    char sys_text[24];
    char carbon_text[24];

    if (Gestalt(gestaltSystemVersion, &sys) == noErr && sys != 0) {
        if ((sys & 0x000F) != 0) {
            snprintf(sys_text, sizeof sys_text, "Mac OS %ld.%ld.%ld",
                     (sys >> 8) & 0xFF, (sys >> 4) & 0xF, sys & 0xF);
        } else {
            snprintf(sys_text, sizeof sys_text, "Mac OS %ld.%ld",
                     (sys >> 8) & 0xFF, (sys >> 4) & 0xF);
        }
    } else {
        strcpy(sys_text, "Mac OS ?");
    }
    if (Gestalt(gestaltCarbonVersion, &carbon) == noErr && carbon != 0) {
        snprintf(carbon_text, sizeof carbon_text, "CarbonLib %ld.%ld",
                 (carbon >> 8) & 0xFF, (carbon >> 4) & 0xF);
    } else {
        strcpy(carbon_text, "CarbonLib ?");
    }
    snprintf(g_this_mac, sizeof g_this_mac, "%s - %s", sys_text,
             carbon_text);
}

static void compute_rects(const Rect *body, ConnRects *r)
{
    short width = (short)(body->right - body->left);
    Boolean stacked = width < kStackBelow;
    short left = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short top = (short)(body->top + 8);
    short other_right = stacked ? right : (short)(left + 300);
    short edit_w = 78;
    short edit_left = (short)(other_right - 14 - edit_w);

    SetRect(&r->other_group, left, top, other_right, (short)(top + 148));
    SetRect(&r->edit_btn, edit_left, (short)(top + 30),
            (short)(other_right - 14), (short)(top + 30 + kButtonHeight));
    SetRect(&r->addr_line, (short)(left + 12), (short)(top + 22),
            (short)(edit_left - 8), (short)(top + 22 + kFieldHeight));
    SetRect(&r->port_line, (short)(left + 12), (short)(top + 48),
            (short)(edit_left - 8), (short)(top + 48 + kFieldHeight));
    SetRect(&r->retry_popup, (short)(left + 10), (short)(top + 74),
            (short)(other_right - 14), (short)(top + 94));
    SetRect(&r->auto_box, (short)(left + 12), (short)(top + 104),
            (short)(other_right - 14), (short)(top + 120));

    if (stacked) {
        SetRect(&r->glance_group, left, (short)(r->other_group.bottom + 8),
                right, (short)(r->other_group.bottom + 152));
    } else {
        SetRect(&r->glance_group, (short)(r->other_group.right + 12), top,
                right, (short)(top + 198));
    }
    SetRect(&r->test_btn,
            (short)(r->glance_group.right - 8 - kTestButtonWidth),
            (short)(r->glance_group.top + 12 + kRttRow * 18 - 1),
            (short)(r->glance_group.right - 8),
            (short)(r->glance_group.top + 12 + kRttRow * 18 - 1
                    + kButtonHeight));

    SetRect(&r->update_group, left,
            (short)(r->glance_group.bottom + 8), right,
            (short)(body->bottom - 8 - kButtonHeight - 12));
    SetRect(&r->app_update_line, (short)(left + 12),
            (short)(r->update_group.top + 22), (short)(right - 126),
            (short)(r->update_group.top + 40));
    SetRect(&r->ext_update_line, (short)(left + 12),
            (short)(r->update_group.top + 46), (short)(right - 126),
            (short)(r->update_group.top + 64));
    SetRect(&r->app_update_btn, (short)(right - 116),
            (short)(r->update_group.top + 16), (short)(right - 10),
            (short)(r->update_group.top + 16 + kButtonHeight));
    SetRect(&r->ext_update_btn, (short)(right - 116),
            (short)(r->update_group.top + 42), (short)(right - 10),
            (short)(r->update_group.top + 42 + kButtonHeight));

    SetRect(&r->action_btn, left, (short)(body->bottom - 10 - kButtonHeight),
            (short)(left + 110), (short)(body->bottom - 10));
    SetRect(&r->save_btn, (short)(right - 70),
            (short)(body->bottom - 10 - kButtonHeight), right,
            (short)(body->bottom - 10));
    SetRect(&r->revert_btn, (short)(r->save_btn.left - 10 - 70),
            (short)(body->bottom - 10 - kButtonHeight),
            (short)(r->save_btn.left - 10), (short)(body->bottom - 10));
}

/* --- field access ------------------------------------------------------- */

static void invalidate_other_group(void)
{
    if (g_owner != NULL && g_visible) {
        InvalWindowRect(g_owner, &g_r.other_group);
    }
}

static void load_fields(const NowPrefs *prefs)
{
    strncpy(g_host, prefs->host, sizeof g_host - 1);
    g_host[sizeof g_host - 1] = '\0';
    g_port_val = prefs->port;
    SetControlValue(g_retry, now_conn_retry_item_for_secs(prefs->retry_secs));
    SetControlValue(g_auto, prefs->auto_connect ? 1 : 0);
    invalidate_other_group();
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

/* The edited target, validated. The Edit dialog only writes back valid
   values, so this normally just copies; it re-checks defensively (a
   prefs file could carry an old malformed host) and reports in the
   placard if somehow invalid. */
static Boolean read_fields(char *host, long host_cap, long *port_out)
{
    if (!now_conn_ipv4_valid(g_host)) {
        set_status("The address must be a dotted IPv4 number, "
                   "like 192.168.1.20. Use Edit to set it.");
        return false;
    }
    strncpy(host, g_host, (size_t)(host_cap - 1));
    host[host_cap - 1] = '\0';
    *port_out = g_port_val;
    return true;
}

/* Persist the edited values. Connects, reconnects, or leaves the wire
   alone depending on where things stand; see the spec's action rules. */
static void do_save(Boolean force_connect)
{
    char host[64];
    long port = 0;
    NowPrefs prefs;
    Boolean target_changed;

    if (!read_fields(host, sizeof host, &port)) {
        return;
    }
    now_prefs_load(&prefs);
    target_changed = strcmp(prefs.host, host) != 0
        || prefs.port != (unsigned short)port;
    strcpy(prefs.host, host);
    prefs.port = (unsigned short)port;
    prefs.retry_secs = now_conn_retry_secs_for_item(GetControlValue(g_retry));
    prefs.auto_connect = GetControlValue(g_auto) != 0;
    if (now_prefs_save(&prefs) != noErr) {
        set_status("Could not save the settings.");
        return;
    }
    if (force_connect) {
        conn_set_target(host, (unsigned short)port);
        set_status("Saved - connecting.");
        return;
    }
    if (conn_is_connected() && target_changed) {
        /* The saved target is the live target; changing it while
           connected means redialing the new one. */
        conn_set_target(host, (unsigned short)port);
        set_status("Saved - reconnecting to the new address.");
        return;
    }
    if (!conn_is_connected() && prefs.auto_connect && target_changed) {
        conn_set_target(host, (unsigned short)port);
        set_status("Saved - connecting.");
        return;
    }
    set_status("Saved.");
}

/* --- glance rows -------------------------------------------------------- */

static void format_duration(long secs, char *out, long cap)
{
    if (secs < 0) {
        snprintf(out, (size_t)cap, "-");
    } else if (secs < 60) {
        snprintf(out, (size_t)cap, "%ld s", secs);
    } else if (secs < 3600) {
        snprintf(out, (size_t)cap, "%ld:%02ld", secs / 60, secs % 60);
    } else {
        snprintf(out, (size_t)cap, "%ld:%02ld:%02ld", secs / 3600,
                 (secs % 3600) / 60, secs % 60);
    }
}

static void build_values(const ConnSnapshot *snap,
                         char vals[][64], char *fail_line, long fail_cap)
{
    if (snap->peer_name[0] != '\0') {
        snprintf(vals[0], 64, "%.40s", snap->peer_name);
    } else {
        strcpy(vals[0], "Not known yet");
    }

    switch (snap->phase) {
    case kConnConnected:
        format_duration(snap->connected_secs, vals[1], 64);
        break;
    case kConnConnecting:
    case kConnHandshaking:
        strcpy(vals[1], "Connecting...");
        break;
    case kConnBackoff:
        snprintf(vals[1], 64, "Retry in %ld s", snap->retry_in_secs);
        break;
    case kConnNeedsCarbonLib:
        strcpy(vals[1], "Needs CarbonLib 1.6");
        break;
    default:
        strcpy(vals[1], "Not connected");
        break;
    }

    if (snap->quiet_secs >= 0) {
        char ago[32];

        format_duration(snap->quiet_secs, ago, sizeof ago);
        snprintf(vals[2], 64, "%s ago", ago);
    } else {
        strcpy(vals[2], "-");
    }

    if (snap->phase == kConnConnected) {
        snprintf(vals[3], 64, "Revision %d - %s", snap->contract_revision,
                 snap->transfer_active ? "transfer" : "idle");
    } else {
        strcpy(vals[3], "-");
    }

    snprintf(vals[4], 64, "%.60s", g_this_mac);

    /* The guest's own ping/pong timing (wire.c), read rather than
       measured here - a second reader of the same clock, never a second
       one. -1 before any pong has come back, the same absence the wire
       itself uses. */
    {
        long rtt = conn_last_rtt_ms();

        if (rtt >= 0) {
            snprintf(vals[5], 64, "%ld ms", rtt);
        } else {
            strcpy(vals[5], "Not measured yet");
        }
    }

    /* Failure detail outranks pleasantries when there is one. */
    if (snap->phase != kConnConnected && snap->last_fail[0] != '\0') {
        snprintf(fail_line, (size_t)fail_cap, "%.24s:%u - %.80s",
                 snap->host, snap->port, snap->last_fail);
    } else if (snap->phase != kConnConnected) {
        snprintf(fail_line, (size_t)fail_cap, "Target: %.24s:%u",
                 snap->host, snap->port);
    } else {
        fail_line[0] = '\0';
    }
}

static void glance_value_rect(int row, Rect *out)
{
    /* The Round trip row shares its band with the Test button, so its
       value column stops short of it - the same reason the address/port
       lines on this page stop short of Edit. */
    short right = (short)(g_r.glance_group.right - 8);

    if (row == kRttRow) {
        right = (short)(right - kTestButtonWidth - 8);
    }
    SetRect(out, (short)(g_r.glance_group.left + 96),
            (short)(g_r.glance_group.top + 12 + row * 18),
            right,
            (short)(g_r.glance_group.top + 12 + (row + 1) * 18));
}

static void glance_fail_rect(Rect *out)
{
    SetRect(out, (short)(g_r.glance_group.left + 8),
            (short)(g_r.glance_group.top + 12 + kGlanceRowCount * 18),
            (short)(g_r.glance_group.right - 8),
            (short)(g_r.glance_group.top + 12 + kGlanceRowCount * 18 + 18));
}

/* --- module ops --------------------------------------------------------- */

static ControlRef make_button(const Rect *bounds, const char *title)
{
    Str255 text;

    CopyCStringToPascal(title, text);
    return now_control_new(g_owner, bounds, text, false, 0, 0, 1, pushButProc,
                      0);
}

/* The button's words follow the wire wherever the page is in its life:
   created, shown again after a spell hidden, or ticking. Idle alone is
   not enough - it is silent while the page is hidden, and a page can be
   created for the first time long after the connection came up. */
static void sync_action_title(void)
{
    const char *want = now_conn_action_title_next(&g_action_title,
                                                  conn_is_connected());

    if (want != NULL && g_action != NULL) {
        Str255 text;

        CopyCStringToPascal(want, text);
        SetControlTitle(g_action, text);
    }
}

static OSErr conn_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    g_body = *body;
    compute_rects(body, &g_r);
    compute_this_mac();
    g_status[0] = '\0';
    memset(g_vals, 0, sizeof g_vals);
    memset(g_update_lines, 0, sizeof g_update_lines);
    g_fail_line[0] = '\0';

    CopyCStringToPascal("Other Mac", text);
    g_group_other = now_control_new(owner, &g_r.other_group, text, false, 0, 0,
                               0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("At a glance", text);
    g_group_glance = now_control_new(owner, &g_r.glance_group, text, false, 0,
                                0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("Updates from the other Mac", text);
    g_group_update = now_control_new(owner, &g_r.update_group, text, false, 0,
                                0, 0, kControlGroupBoxTextTitleProc, 0);
    g_edit = make_button(&g_r.edit_btn, "Edit\xC9");   /* MacRoman ellipsis */
    CopyCStringToPascal("Retry:", text);
    /* classic popup CDEF: value = title justification, min = MENU id,
       max = title width in pixels */
    g_retry = now_control_new(owner, &g_r.retry_popup, text, false,
                         popupTitleLeftJust, kRetryMenuID, 44,
                         popupMenuProc, 0);
    CopyCStringToPascal("Connect when New Old World opens", text);
    g_auto = now_control_new(owner, &g_r.auto_box, text, false, 0, 0, 1,
                        checkBoxProc, 0);
    {
        const char *action_title = now_conn_action_title(conn_is_connected());

        g_action = make_button(&g_r.action_btn, action_title);
        now_conn_action_title_init(&g_action_title, action_title);
    }
    g_revert = make_button(&g_r.revert_btn, "Revert");
    g_save = make_button(&g_r.save_btn, "Save");
    g_test = make_button(&g_r.test_btn, "Test");
    g_update_app = make_button(&g_r.app_update_btn, "Install App");
    g_update_ext = make_button(&g_r.ext_update_btn, "Install Extension");

    if (g_group_other == NULL || g_group_glance == NULL || g_edit == NULL
        || g_retry == NULL || g_auto == NULL
        || g_group_update == NULL || g_update_app == NULL
        || g_update_ext == NULL || g_action == NULL || g_revert == NULL
        || g_save == NULL || g_test == NULL) {
        return memFullErr;
    }
    {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        load_fields(&prefs);
    }
    return noErr;
}

static void conn_dispose(void)
{
    /* DisposeWindow takes the controls; nothing else is owned here. */
    g_owner = NULL;
    g_group_other = NULL;
    g_edit = NULL;
    g_retry = NULL;
    g_auto = NULL;
    g_group_glance = NULL;
    g_group_update = NULL;
    g_update_app = NULL;
    g_update_ext = NULL;
    g_action = NULL;
    g_revert = NULL;
    g_save = NULL;
    g_test = NULL;
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

static void conn_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_group_other, visible);
    show_control(g_group_glance, visible);
    show_control(g_group_update, visible);
    show_control(g_update_app, visible);
    show_control(g_update_ext, visible);
    show_control(g_edit, visible);
    show_control(g_retry, visible);
    show_control(g_auto, visible);
    show_control(g_action, visible);
    show_control(g_revert, visible);
    show_control(g_save, visible);
    show_control(g_test, visible);
    if (visible) {
        /* Idle was mute while this page was away; catch the title up
           before the human sees it rather than a tick later. */
        sync_action_title();
    } else {
        g_status[0] = '\0';
    }
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

static void conn_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    move_control(g_group_other, &g_r.other_group);
    move_control(g_group_glance, &g_r.glance_group);
    move_control(g_group_update, &g_r.update_group);
    move_control(g_update_app, &g_r.app_update_btn);
    move_control(g_update_ext, &g_r.ext_update_btn);
    move_control(g_edit, &g_r.edit_btn);
    move_control(g_retry, &g_r.retry_popup);
    move_control(g_auto, &g_r.auto_box);
    move_control(g_action, &g_r.action_btn);
    move_control(g_revert, &g_r.revert_btn);
    move_control(g_save, &g_r.save_btn);
    move_control(g_test, &g_r.test_btn);
}

/* One run of hand-drawn text, drawn or described. A NULL writer draws at
   the run's own baseline with its own truncation; a writer reports the
   rect it occupies. Both faces of this page take one walk - the address,
   the port and the glance rows are exactly the facts a host asks about,
   and a second traversal free to disagree with the pixels about them is
   the drift this whole change exists to close. `room <= 0` means the run
   was never truncated. */
static void emit_run(const WorkshopSceneWriter *writer, const Rect *where,
                     short baseline, short room, TruncCode trunc,
                     const char *line)
{
    Str255 text;

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, line, where,
                           true);
        return;
    }
    CopyCStringToPascal(line, text);
    if (room > 0) {
        TruncString(room, text, trunc);
    }
    MoveTo(where->left, baseline);
    DrawString(text);
}

static void conn_content(const WorkshopSceneWriter *writer)
{
    Rect where;
    int i;

    where = g_r.addr_line;
    where.right = (short)(where.left + 58);
    emit_run(writer, &where, (short)(g_r.addr_line.top + 12), 0, truncEnd,
             "Address:");
    where = g_r.addr_line;
    where.left = (short)(g_r.addr_line.left + 58);
    emit_run(writer, &where, (short)(g_r.addr_line.top + 12),
             (short)(g_r.addr_line.right - g_r.addr_line.left - 58),
             truncEnd, g_host[0] != '\0' ? g_host : "not set");

    where = g_r.port_line;
    where.right = (short)(where.left + 58);
    emit_run(writer, &where, (short)(g_r.port_line.top + 12), 0, truncEnd,
             "Port:");
    {
        char port_text[16];

        snprintf(port_text, sizeof port_text, "%u", g_port_val);
        where = g_r.port_line;
        where.left = (short)(g_r.port_line.left + 58);
        emit_run(writer, &where, (short)(g_r.port_line.top + 12), 0,
                 truncEnd, port_text);
    }

    for (i = 0; i < kGlanceRowCount; ++i) {
        Rect value;

        glance_value_rect(i, &value);
        where = value;
        where.left = (short)(g_r.glance_group.left + 12);
        where.right = value.left;
        emit_run(writer, &where, (short)(value.top + 12), 0, truncEnd,
                 k_glance_labels[i]);
        emit_run(writer, &value, (short)(value.top + 12),
                 (short)(value.right - value.left), truncEnd, g_vals[i]);
    }
    if (g_fail_line[0] != '\0') {
        Rect fail;

        glance_fail_rect(&fail);
        emit_run(writer, &fail, (short)(fail.top + 12),
                 (short)(fail.right - fail.left), truncMiddle, g_fail_line);
    }
    emit_run(writer, &g_r.app_update_line,
             (short)(g_r.app_update_line.top + 12),
             (short)(g_r.app_update_line.right - g_r.app_update_line.left),
             truncMiddle, g_update_lines[0]);
    emit_run(writer, &g_r.ext_update_line,
             (short)(g_r.ext_update_line.top + 12),
             (short)(g_r.ext_update_line.right - g_r.ext_update_line.left),
             truncMiddle, g_update_lines[1]);
    if (g_update_lines[2][0] != '\0') {
        SetRect(&where, (short)(g_r.update_group.left + 12),
                (short)(g_r.update_group.bottom - 22),
                (short)(g_r.update_group.right - 12),
                (short)(g_r.update_group.bottom - 6));
        emit_run(writer, &where, (short)(g_r.update_group.bottom - 10),
                 (short)(g_r.update_group.right - g_r.update_group.left - 24),
                 truncMiddle, g_update_lines[2]);
    }
}

static void conn_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    conn_content(NULL);
}

static void conn_describe_scene(const WorkshopSceneWriter *writer)
{
    conn_content(writer);
}

static void install_update(NowUpdateComponent component)
{
    NowUpdateOffer offer;
    char detail[180];
    char err[120];

    if (!now_update_offer_get(component, &offer)) return;
    if (!offer.signed_artifact) {
        snprintf(detail, sizeof detail,
                 "%s %s build %.12s has a verified SHA-256, but no release "
                 "signature. Install this %s build?",
                 component == kNowUpdateApplication ? "Application"
                                                    : "Extension",
                 offer.version, offer.build,
                 offer.channel[0] != '\0' ? offer.channel : "development");
        if (!now_confirm("Install unsigned update?", detail, "Install")) {
            set_status("Update not installed.");
            return;
        }
    }
    if (now_wire_update_request(component, true, err, sizeof err) != 0) {
        set_status(err);
        return;
    }
    set_status(component == kNowUpdateApplication
               ? "Downloading application update..."
               : "Downloading extension update; restart afterward.");
}

static Boolean conn_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    (void)event;                      /* controls track by point, not event */
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    /* Plain FindControl: the window has no root control (workshop_window.c
       explains why), so the controls are flat siblings and this is the
       correct classic hit-test. */
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_edit) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            char host[64];
            unsigned short port = g_port_val;

            strcpy(host, g_host);
            /* A modal from a click is main-loop code, not pumped wire
               code, so opening it here is allowed (pump.h). */
            if (now_conn_edit(host, sizeof host, &port)) {
                strcpy(g_host, host);
                g_port_val = port;
                invalidate_other_group();
                /* Committing an address in the editor IS the intent to
                   use it; staging it behind a second Save button left
                   the page showing a target it was not dialling. */
                do_save(true);
            }
        }
        return true;
    }
    if (control == g_retry) {
        /* Popup CDEFs run their own menu tracking; the pump action is
           for buttons only (pump.h). */
        TrackControl(control, local, (ControlActionUPP)-1L);
        return true;
    }
    if (control == g_auto) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            SetControlValue(g_auto, GetControlValue(g_auto) ? 0 : 1);
        }
        return true;
    }
    if (control == g_action || control == g_revert || control == g_save) {
        if (TrackControl(control, local, now_pump_action()) == 0) {
            return true;
        }
        if (control == g_action) {
            if (conn_is_connected()) {
                conn_disconnect();
                set_status("Disconnected.");
            } else {
                do_save(true);
            }
        } else if (control == g_revert) {
            NowPrefs prefs;

            now_prefs_load(&prefs);
            load_fields(&prefs);
            set_status("Reverted to the saved values.");
        } else {
            do_save(false);
        }
        return true;
    }
    if (control == g_test) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            /* No set_status here, deliberately: that placard is the last
               ACTION's result and would otherwise freeze on "Pinging..."
               forever, hiding the live RTT the wire keeps stamping into
               it on every connected tick (conn_status). The Round trip
               row is where this press's answer shows up. */
            conn_ping_now();
        }
        return true;
    }
    if (control == g_update_app || control == g_update_ext) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            install_update(control == g_update_app
                           ? kNowUpdateApplication : kNowUpdateExtension);
        }
        return true;
    }
    return false;
}

static Boolean conn_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    /* The page has no text field of its own now; Return means Save, the
       way a dialog's default button would. Everything else falls
       through to the Workshop (sidebar arrows, Tab). */
    if (c == '\r' || c == 3) {
        do_save(false);
        return true;
    }
    return false;
}

static void conn_activate(Boolean active)
{
    ControlRef controls[12];
    int i;

    controls[0] = g_group_other;
    controls[1] = g_group_glance;
    controls[2] = g_edit;
    controls[3] = g_retry;
    controls[4] = g_auto;
    controls[5] = g_action;
    controls[6] = g_revert;
    controls[7] = g_save;
    controls[8] = g_group_update;
    controls[9] = g_update_app;
    controls[10] = g_update_ext;
    controls[11] = g_test;
    for (i = 0; i < 12; ++i) {
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

static void conn_idle(void)
{
    ConnSnapshot snap;
    char vals[kGlanceRowCount][64];
    char fail_line[120];
    int i;
    int update_changed = 0;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    conn_snapshot(&snap);
    build_values(&snap, vals, fail_line, sizeof fail_line);
    for (i = 0; i < kGlanceRowCount; ++i) {
        if (strcmp(vals[i], g_vals[i]) != 0) {
            Rect r;

            strcpy(g_vals[i], vals[i]);
            glance_value_rect(i, &r);
            InvalWindowRect(g_owner, &r);
        }
    }
    if (strcmp(fail_line, g_fail_line) != 0) {
        Rect r;

        strcpy(g_fail_line, fail_line);
        glance_fail_rect(&r);
        InvalWindowRect(g_owner, &r);
    }

    sync_action_title();
    /* Nothing to ping without a live session - see conn_ping_now(). */
    HiliteControl(g_test, snap.phase == kConnConnected
                              ? kControlNoPart : kControlInactivePart);
    for (i = 0; i < kNowUpdateComponentCount; ++i) {
        char version[24], build[65], line[160];
        Rect dirty = i == 0 ? g_r.app_update_line : g_r.ext_update_line;

        now_update_current_identity((NowUpdateComponent)i,
                                    version, sizeof version,
                                    build, sizeof build);
        now_update_offer_line((NowUpdateComponent)i, version, build,
                              line, sizeof line);
        if (i == kNowUpdateApplication
            && now_wire_update_relaunch_required()) {
            snprintf(line, sizeof line,
                     "Application installed - quit and relaunch NOW");
        } else if (i == kNowUpdateExtension
            && now_wire_update_restart_required()) {
            snprintf(line, sizeof line,
                     "Extension installed - restart this Mac");
        }
        if (strcmp(line, g_update_lines[i]) != 0) {
            strcpy(g_update_lines[i], line);
            InvalWindowRect(g_owner, &dirty);
        }
    }
    {
        char warning[128];
        Rect dirty = g_r.update_group;
        warning[0] = '\0';
        now_update_extension_differs_from_app(warning, sizeof warning);
        if (strcmp(warning, g_update_lines[2]) != 0) {
            strcpy(g_update_lines[2], warning);
            InvalWindowRect(g_owner, &dirty);
        }
    }
    if (!now_wire_update_pending(NULL)) {
        char version[24], build[65];
        now_update_current_identity(kNowUpdateApplication, version,
                                    sizeof version, build, sizeof build);
        update_changed = now_update_offer_differs(
            kNowUpdateApplication, version, build);
        HiliteControl(g_update_app,
                      update_changed
                          && !now_wire_update_relaunch_required()
                      ? kControlNoPart
                                     : kControlInactivePart);
        now_update_current_identity(kNowUpdateExtension, version,
                                    sizeof version, build, sizeof build);
        update_changed = now_update_offer_differs(
            kNowUpdateExtension, version, build);
        HiliteControl(g_update_ext,
                      update_changed
                          && !now_wire_update_restart_required()
                      ? kControlNoPart : kControlInactivePart);
    } else {
        HiliteControl(g_update_app, kControlInactivePart);
        HiliteControl(g_update_ext, kControlInactivePart);
    }
}

static void conn_status_text(char *out, long cap)
{
    if (now_wire_update_relaunch_required()) {
        snprintf(out, (size_t)cap,
                 "Application installed. Quit NOW, then launch it again.");
    } else if (now_wire_update_restart_required()) {
        snprintf(out, (size_t)cap,
                 "Extension installed. Restart this Mac to activate it.");
    } else if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        conn_status(out, cap);
    }
}

/* Edit>Copy: address, port and the at-a-glance rows - the facts a person is
       asked for when the link will not come up.

   Served by pointing this page's own describe_scene at a buffer instead
   of at the host, so what lands on the clipboard is by construction what
   the page describes, which is by construction what it drew. */
static long conn_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    conn_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
}

static const WorkshopModuleOps k_ops = {
    conn_create,
    conn_dispose,
    conn_show,
    conn_layout,
    conn_draw,
    conn_click,
    conn_key,
    conn_activate,
    conn_idle,
    conn_status_text,
    conn_describe_scene,
    conn_copy_text
};

const WorkshopModuleOps *connection_module_ops(void)
{
    return &k_ops;
}
