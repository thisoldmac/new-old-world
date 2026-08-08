#include "mirror_module.h"

#include <stdio.h>
#include <string.h>

#include "control_kind.h"
#include "mirror_layout.h"
#include "mirror_log.h"
#include "nowlog.h"
#include "mirror_policy.h"
#include "mirror_probe.h"
#include "mirror_show.h"
#include "peek.h"
#include "pump.h"
#include "qdtrace.h"

static WindowRef g_owner;
static Rect g_body;
static MirrorLayout g_layout;
static MirrorFacts g_facts;
static Boolean g_visible;
static UInt32 g_next_poll;

/* The host button, policy controls, and their status lines. Status is
   cached and compared before any redraw: `idle` runs every pass, and a
   page that repainted a string it had already drawn would flicker for
   as long as anyone left it open. */
static ControlRef g_show_button;
static ControlRef g_policy_controls[kMirrorPolicyCount];
static char g_policy_status[128];
static char g_shown_policy_status[128];
static char g_show_status[128];
static char g_shown_status[128];

enum { kMirrorPollTicks = 60 };

static void draw_line(const Rect *where, const char *text)
{
    Str255 ptext;

    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, ptext);
    TruncString((short)(where->right - where->left), ptext, truncEnd);
    DrawString(ptext);
}

static void draw_row(const Rect *where, const char *label, const char *value)
{
    Rect left = *where;
    Rect right = *where;

    left.right = (short)(where->left + kMirrorLabelWidth);
    right.left = left.right;
    draw_line(&left, label);
    draw_line(&right, value);
}

static void draw_heading(const Rect *where, const char *text)
{
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    draw_line(where, text);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

/* The wire's answer, arriving from pumped code. It sets a string and
   nothing else — no dialog, no redraw from here: `idle` notices the
   change and invalidates. That is the rule this page would break first.

   Static, module-scope and not a stack buffer, because the note fires
   long after the click that asked has returned. */
static void show_note(Boolean ok, const char *reason)
{
    snprintf(g_show_status, sizeof g_show_status, "%s%.100s",
             ok ? "" : "Refused: ", reason);
}

static OSErr mirror_create(WindowRef owner, const Rect *body)
{
    Str255 title;
    MirrorPolicy policy;
    int i;

    g_owner = owner;
    g_body = *body;
    now_mirror_layout_compute(body, &g_layout);
    now_mirror_probe(&g_facts);
    g_next_poll = TickCount() + kMirrorPollTicks;
    CopyCStringToPascal(now_mirror_show_button_title(), title);
    /* Invisible, per the module contract: the Workshop shows the page's
       controls when it selects the page. */
    g_show_button = now_control_new(owner, &g_layout.show_button, title,
                                    false, 0, 0, 1, pushButProc, 0);
    if (g_show_button == NULL) {
        now_mirror_log_page("create refused: out of memory");
        return memFullErr;
    }
    now_mirror_policy_get(&policy);
    for (i = 0; i < kMirrorPolicyCount; ++i) {
        Boolean enabled;

        CopyCStringToPascal(now_mirror_policy_name((MirrorPolicyDomain)i),
                            title);
        switch ((MirrorPolicyDomain)i) {
        case kMirrorPolicyStructure: enabled = policy.structure; break;
        case kMirrorPolicyFinderComplements:
            enabled = policy.finder_complements;
            break;
        case kMirrorPolicyContent: enabled = policy.content; break;
        case kMirrorPolicyForegroundCycle:
            enabled = policy.foreground_cycle;
            break;
        case kMirrorPolicyEnd: enabled = false; break;
        }
        g_policy_controls[i] = now_control_new(
            owner, &g_layout.policy_rows[i], title, false,
            enabled ? 1 : 0, 0, 1, checkBoxProc, 0);
        if (g_policy_controls[i] == NULL) {
            now_mirror_log_page("create refused: out of memory");
            return memFullErr;
        }
    }
    conn_set_host_show_note(show_note);
    now_mirror_log_page("created");
    return noErr;
}

static void mirror_dispose(void)
{
    /* The window takes its controls with it, so the ref is nulled and
       never disposed. The hook is dropped because the wire outlives
       this page and would otherwise write into a dead module's state. */
    conn_set_host_show_note(NULL);
    g_show_button = NULL;
    memset(g_policy_controls, 0, sizeof g_policy_controls);
    g_owner = NULL;
    g_visible = false;
    now_mirror_log_page("disposed");
}

static void mirror_show(Boolean visible)
{
    int i;

    /* Compared before it is stored: the Workshop may reassert a page's
       visibility, and a line per assertion would be a heartbeat rather
       than the event of a person arriving at this page. */
    if (visible != g_visible) {
        now_mirror_log_page(visible ? "entered" : "left");
    }
    g_visible = visible;
    if (g_show_button == NULL) {
        return;
    }
    if (visible) {
        ShowControl(g_show_button);
        for (i = 0; i < kMirrorPolicyCount; ++i) {
            ShowControl(g_policy_controls[i]);
        }
    } else {
        HideControl(g_show_button);
        for (i = 0; i < kMirrorPolicyCount; ++i) {
            HideControl(g_policy_controls[i]);
        }
    }
}

static void mirror_layout(const Rect *body)
{
    int i;

    g_body = *body;
    now_mirror_layout_compute(body, &g_layout);
    if (g_show_button != NULL) {
        MoveControl(g_show_button, g_layout.show_button.left,
                    g_layout.show_button.top);
    }
    for (i = 0; i < kMirrorPolicyCount; ++i) {
        if (g_policy_controls[i] != NULL) {
            MoveControl(g_policy_controls[i], g_layout.policy_rows[i].left,
                        g_layout.policy_rows[i].top);
        }
    }
}

static void mirror_draw(void)
{
    char value[180];
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_heading(&g_layout.heading, "NOW Extension");
    now_mirror_lifecycle_text(&g_facts, value, (long)sizeof value);
    draw_row(&g_layout.lifecycle_rows[0], "Lifecycle", value);
    if (g_facts.lifecycle == kMirrorLifecycleActive
        || g_facts.lifecycle == kMirrorLifecycleDegraded
        || g_facts.lifecycle == kMirrorLifecycleWrongVersion) {
        snprintf(value, sizeof value, "%lu.%lu", g_facts.resident_major,
                 g_facts.resident_minor);
    } else {
        strcpy(value, "-");
    }
    draw_row(&g_layout.lifecycle_rows[1], "Resident version", value);
    snprintf(value, sizeof value, "cap %lu, requested %lu, active %lu",
             g_facts.capabilities, g_facts.requested_bits,
             g_facts.active_bits);
    draw_row(&g_layout.lifecycle_rows[2], "Plane bits", value);
    snprintf(value, sizeof value, "%s",
             g_facts.has_build_identity ? "Exact build identity available"
                                        : "Build identity unavailable");
    draw_row(&g_layout.lifecycle_rows[3], "Build", value);
    now_mirror_rest_text(&g_facts, value, (long)sizeof value);
    draw_row(&g_layout.lifecycle_rows[4], "Installed", value);

    draw_heading(&g_layout.plane_heading, "Mirror planes");
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        now_mirror_plane_value(&g_facts, (MirrorPlane)i, value,
                               (long)sizeof value);
        draw_row(&g_layout.plane_rows[i],
                 now_mirror_plane_name((MirrorPlane)i), value);
    }
    draw_heading(&g_layout.policy_heading, "Observation policy");
    draw_line(&g_layout.policy_status, g_policy_status);
    strcpy(g_shown_policy_status, g_policy_status);
    draw_line(&g_layout.show_status, g_show_status);
    strcpy(g_shown_status, g_show_status);
    for (i = 0; i < kMirrorNoteLines; ++i) {
        draw_line(&g_layout.note[i], now_mirror_note(i));
    }
}

static Boolean mirror_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    int i;

    (void)event;
    if (g_owner == NULL || !g_visible || g_show_button == NULL) {
        return false;
    }
    (void)FindControl(local, g_owner, &control);
    for (i = 0; i < kMirrorPolicyCount; ++i) {
        if (control == g_policy_controls[i]) {
            Boolean want;
            OSErr err;

            if (TrackControl(control, local, now_pump_action()) == 0) {
                return true;
            }
            want = GetControlValue(control) == 0;
            err = now_mirror_policy_set((MirrorPolicyDomain)i, want);
            if (err != noErr) {
                snprintf(g_policy_status, sizeof g_policy_status,
                         "Could not save this setting (%d)", (int)err);
                now_log(kLogWarn, "mirror", "policy save failed (%d)",
                        (int)err);
                return true;
            }
            SetControlValue(control, want ? 1 : 0);
            snprintf(g_policy_status, sizeof g_policy_status, "%s: %s",
                     now_mirror_policy_name((MirrorPolicyDomain)i),
                     want ? "on" : "off");
            now_log(kLogInfo, "mirror", "policy %d %s", i,
                    want ? "enabled" : "disabled");
            if (!want && i == kMirrorPolicyContent) {
                now_qdtrace_stop_for_policy();
            }
            if (!want && i == kMirrorPolicyStructure) {
                now_peek_release(kNowPeekOwnerScene,
                    (unsigned long)(kNowPeekCapAnchors | kNowPeekCapTree
                                    | kNowPeekTableCapAct));
            }
            return true;
        }
    }
    if (control != g_show_button) return false;
    /* The wire is pumped inside the tracking loop, as every tracked
       control on this machine must be: a press held down is a press
       during which the host is still talking. */
    if (TrackControl(control, local, now_pump_action()) != 0) {
        char err[96];

        if (now_wire_host_show(kMirrorHostSurface, err, sizeof err) != 0) {
            snprintf(g_show_status, sizeof g_show_status, "%.100s", err);
            /* Rule 4: the string that explains the refusal goes to the
               log, not only to a status line the next event overwrites. */
            now_log(kLogWarn, "mirror", "show refused: %.60s", err);
        } else {
            now_log(kLogInfo, "mirror", "show requested on the host");
            snprintf(g_show_status, sizeof g_show_status, "%s",
                     now_mirror_show_waiting_text());
        }
    }
    return true;
}

static void mirror_activate(Boolean active)
{
    int i;
    ControlRef controls[kMirrorPolicyCount + 1];

    controls[0] = g_show_button;
    for (i = 0; i < kMirrorPolicyCount; ++i) {
        controls[i + 1] = g_policy_controls[i];
    }
    for (i = 0; i < kMirrorPolicyCount + 1; ++i) {
        if (controls[i] == NULL) continue;
        if (active) ActivateControl(controls[i]);
        else DeactivateControl(controls[i]);
    }
}

/* Checked on EVERY pass rather than with the poll above, and it is the
   cheap half: one strcmp against what was last drawn. The answer to a
   button press must not wait up to a second to appear, and repainting
   only the status rectangle is what keeps that from being a flicker. */
static void mirror_status_idle(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    if (strcmp(g_show_status, g_shown_status) != 0) {
        InvalWindowRect(g_owner, &g_layout.show_status);
    }
    if (strcmp(g_policy_status, g_shown_policy_status) != 0) {
        InvalWindowRect(g_owner, &g_layout.policy_status);
    }
}

static void mirror_idle(void)
{
    MirrorFacts latest;

    mirror_status_idle();
    if (g_owner == NULL || !g_visible
        || (long)(TickCount() - g_next_poll) < 0) {
        return;
    }
    g_next_poll = TickCount() + kMirrorPollTicks;
    now_mirror_probe(&latest);
    if (memcmp(&latest, &g_facts, sizeof latest) != 0) {
        g_facts = latest;
        InvalWindowRect(g_owner, &g_body);
    }
}


static void mirror_status(char *out, long cap)
{
    now_mirror_status_text(&g_facts, out, cap);
}

static const WorkshopModuleOps k_ops = {
    mirror_create,
    mirror_dispose,
    mirror_show,
    mirror_layout,
    mirror_draw,
    mirror_click,
    NULL,
    mirror_activate,
    mirror_idle,
    mirror_status,
    NULL
};

const WorkshopModuleOps *mirror_module_ops(void)
{
    return &k_ops;
}
