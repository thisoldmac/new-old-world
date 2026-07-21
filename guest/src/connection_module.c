#include "connection_module.h"

#include <stdio.h>
#include <string.h>

#include "conn_fields.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"

/* The page has two halves: an "Other Mac" group whose fields edit the
   saved target, and an "At a glance" group of live read-only rows fed
   by conn_snapshot(). Nothing here services the wire, opens a dialog,
   or blocks; actions hand the target to wire.c and return. */

enum {
    kRetryMenuID = 133,
    kGlanceRowCount = 5,
    kMargin = 12,
    kFieldHeight = 16,
    kButtonHeight = 20,
    /* Stack the two groups when the body is narrower than this. */
    kStackBelow = 560
};

typedef struct {
    Rect other_group;
    Rect addr_field;
    Rect port_field;
    Rect retry_popup;
    Rect auto_box;
    Rect glance_group;
    Rect action_btn;
    Rect revert_btn;
    Rect save_btn;
} ConnRects;

static WindowRef g_owner;
static Rect g_body;
static ConnRects g_r;
static Boolean g_visible;

static ControlRef g_group_other;
static ControlRef g_addr;
static ControlRef g_port;
static ControlRef g_retry;
static ControlRef g_auto;
static ControlRef g_group_glance;
static ControlRef g_action;
static ControlRef g_revert;
static ControlRef g_save;

/* Transient result of the last action, shown in the status placard
   until the next action or module switch. */
static char g_status[120];

/* Glance cache: the five value strings plus the failure line, repainted
   only when the words change. */
static char g_vals[kGlanceRowCount][64];
static char g_fail_line[120];
static Boolean g_shown_connected;

static const char *k_glance_labels[kGlanceRowCount] = {
    "Other Mac", "Connected", "Last traffic", "Wire", "This Mac"
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
    short field_left = (short)(left + 84);

    SetRect(&r->other_group, left, top, other_right, (short)(top + 148));
    SetRect(&r->addr_field, field_left, (short)(top + 22),
            (short)(other_right - 14), (short)(top + 22 + kFieldHeight));
    SetRect(&r->port_field, field_left, (short)(top + 48),
            (short)(field_left + 60), (short)(top + 48 + kFieldHeight));
    SetRect(&r->retry_popup, (short)(left + 10), (short)(top + 74),
            (short)(other_right - 14), (short)(top + 94));
    SetRect(&r->auto_box, (short)(left + 12), (short)(top + 104),
            (short)(other_right - 14), (short)(top + 120));

    if (stacked) {
        SetRect(&r->glance_group, left, (short)(r->other_group.bottom + 8),
                right, (short)(body->bottom - 8 - kButtonHeight - 12));
    } else {
        SetRect(&r->glance_group, (short)(r->other_group.right + 12), top,
                right, (short)(top + 178));
    }

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

static void field_text(ControlRef field, char *out, long cap)
{
    Size actual = 0;

    out[0] = '\0';
    if (GetControlData(field, kControlEditTextPart, kControlEditTextTextTag,
                       cap - 1, out, &actual) == noErr) {
        if (actual > cap - 1) {
            actual = cap - 1;
        }
        out[actual] = '\0';
    }
}

static void set_field_text(ControlRef field, const char *text)
{
    SetControlData(field, kControlEditTextPart, kControlEditTextTextTag,
                   (Size)strlen(text), text);
    if (g_owner != NULL) {
        Rect r;

        GetControlBounds(field, &r);
        InsetRect(&r, -3, -3);        /* the frame draws outside */
        InvalWindowRect(g_owner, &r);
    }
}

static void load_fields(const NowPrefs *prefs)
{
    char text[16];

    set_field_text(g_addr, prefs->host);
    snprintf(text, sizeof text, "%u", prefs->port);
    set_field_text(g_port, text);
    SetControlValue(g_retry, now_conn_retry_item_for_secs(prefs->retry_secs));
    SetControlValue(g_auto, prefs->auto_connect ? 1 : 0);
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

/* Validate the visible fields into host/port. On failure, says why in
   the status placard and returns false. */
static Boolean read_fields(char *host, long host_cap, long *port_out)
{
    char port_text[16];
    long port;

    field_text(g_addr, host, host_cap);
    field_text(g_port, port_text, sizeof port_text);
    if (!now_conn_ipv4_valid(host)) {
        set_status("The address must be a dotted IPv4 number, "
                   "like 10.91.5.20.");
        return false;
    }
    port = now_conn_port_parse(port_text);
    if (port < 0) {
        set_status("The port must be a number from 1 through 65535.");
        return false;
    }
    *port_out = port;
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
    SetRect(out, (short)(g_r.glance_group.left + 96),
            (short)(g_r.glance_group.top + 12 + row * 18),
            (short)(g_r.glance_group.right - 8),
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
    return NewControl(g_owner, bounds, text, false, 0, 0, 1, pushButProc,
                      0);
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
    g_fail_line[0] = '\0';

    CopyCStringToPascal("Other Mac", text);
    g_group_other = NewControl(owner, &g_r.other_group, text, false, 0, 0,
                               0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("At a glance", text);
    g_group_glance = NewControl(owner, &g_r.glance_group, text, false, 0,
                                0, 0, kControlGroupBoxTextTitleProc, 0);
    CopyCStringToPascal("", text);
    g_addr = NewControl(owner, &g_r.addr_field, text, false, 0, 0, 0,
                        kControlEditTextProc, 0);
    g_port = NewControl(owner, &g_r.port_field, text, false, 0, 0, 0,
                        kControlEditTextProc, 0);
    CopyCStringToPascal("Retry:", text);
    /* classic popup CDEF: value = title justification, min = MENU id,
       max = title width in pixels */
    g_retry = NewControl(owner, &g_r.retry_popup, text, false,
                         popupTitleLeftJust, kRetryMenuID, 44,
                         popupMenuProc, 0);
    CopyCStringToPascal("Connect when New Old World opens", text);
    g_auto = NewControl(owner, &g_r.auto_box, text, false, 0, 0, 1,
                        checkBoxProc, 0);
    g_action = make_button(&g_r.action_btn, "Connect");
    g_revert = make_button(&g_r.revert_btn, "Revert");
    g_save = make_button(&g_r.save_btn, "Save");

    if (g_group_other == NULL || g_group_glance == NULL || g_addr == NULL
        || g_port == NULL || g_retry == NULL || g_auto == NULL
        || g_action == NULL || g_revert == NULL || g_save == NULL) {
        return memFullErr;
    }
    {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        load_fields(&prefs);
    }
    g_shown_connected = conn_is_connected();
    return noErr;
}

static void conn_dispose(void)
{
    /* DisposeWindow takes the controls; nothing else is owned here. */
    g_owner = NULL;
    g_group_other = NULL;
    g_addr = NULL;
    g_port = NULL;
    g_retry = NULL;
    g_auto = NULL;
    g_group_glance = NULL;
    g_action = NULL;
    g_revert = NULL;
    g_save = NULL;
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
    show_control(g_addr, visible);
    show_control(g_port, visible);
    show_control(g_retry, visible);
    show_control(g_auto, visible);
    show_control(g_action, visible);
    show_control(g_revert, visible);
    show_control(g_save, visible);
    if (g_owner == NULL) {
        return;
    }
    if (visible) {
        SetKeyboardFocus(g_owner, g_addr, kControlFocusNextPart);
    } else {
        ClearKeyboardFocus(g_owner);
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
    move_control(g_addr, &g_r.addr_field);
    move_control(g_port, &g_r.port_field);
    move_control(g_retry, &g_r.retry_popup);
    move_control(g_auto, &g_r.auto_box);
    move_control(g_action, &g_r.action_btn);
    move_control(g_revert, &g_r.revert_btn);
    move_control(g_save, &g_r.save_btn);
}

static void conn_draw(void)
{
    Str255 text;
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo((short)(g_r.other_group.left + 12),
           (short)(g_r.addr_field.top + 12));
    CopyCStringToPascal("Address:", text);
    DrawString(text);
    MoveTo((short)(g_r.other_group.left + 12),
           (short)(g_r.port_field.top + 12));
    CopyCStringToPascal("Port:", text);
    DrawString(text);

    for (i = 0; i < kGlanceRowCount; ++i) {
        Rect value;

        glance_value_rect(i, &value);
        MoveTo((short)(g_r.glance_group.left + 12),
               (short)(value.top + 12));
        CopyCStringToPascal(k_glance_labels[i], text);
        DrawString(text);
        MoveTo(value.left, (short)(value.top + 12));
        CopyCStringToPascal(g_vals[i], text);
        TruncString((short)(value.right - value.left), text, truncEnd);
        DrawString(text);
    }
    if (g_fail_line[0] != '\0') {
        Rect fail;

        glance_fail_rect(&fail);
        MoveTo(fail.left, (short)(fail.top + 12));
        CopyCStringToPascal(g_fail_line, text);
        TruncString((short)(fail.right - fail.left), text, truncMiddle);
        DrawString(text);
    }
}

static Boolean conn_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    if (control == g_addr || control == g_port) {
        SetKeyboardFocus(g_owner, control, kControlFocusNextPart);
        HandleControlClick(control, local, event->modifiers, NULL);
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
    return false;
}

static Boolean conn_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    ControlRef focus = NULL;

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (GetKeyboardFocus(g_owner, &focus) != noErr || focus == NULL) {
        return false;
    }
    if (focus != g_addr && focus != g_port) {
        return false;
    }
    if (c == '\r' || c == 3) {        /* Return or Enter runs Save */
        do_save(false);
        return true;
    }
    if (c == '\t') {
        return false;                 /* the Workshop moves the focus */
    }
    HandleControlKey(focus, (SInt16)((event->message & keyCodeMask) >> 8),
                     c, event->modifiers);
    return true;
}

static void conn_activate(Boolean active)
{
    ControlRef controls[9];
    int i;

    controls[0] = g_group_other;
    controls[1] = g_group_glance;
    controls[2] = g_addr;
    controls[3] = g_port;
    controls[4] = g_retry;
    controls[5] = g_auto;
    controls[6] = g_action;
    controls[7] = g_revert;
    controls[8] = g_save;
    for (i = 0; i < 9; ++i) {
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
    Boolean connected;
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    IdleControls(g_owner);            /* the edit-text caret blink */

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

    connected = conn_is_connected();
    if (connected != g_shown_connected && g_action != NULL) {
        Str255 text;

        g_shown_connected = connected;
        CopyCStringToPascal(connected ? "Disconnect" : "Connect", text);
        SetControlTitle(g_action, text);
    }
}

static void conn_status_text(char *out, long cap)
{
    if (g_status[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_status);
    } else {
        conn_status(out, cap);
    }
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
    conn_status_text
};

const WorkshopModuleOps *connection_module_ops(void)
{
    return &k_ops;
}
