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
#include "workshop_scene_text.h"

static WindowRef g_owner;
static Rect g_body;
static MirrorLayout g_layout;
static MirrorFacts g_facts;
static Boolean g_visible;
static UInt32 g_next_poll;

/* The host button, the consent checkbox, and their status lines. Status
   is cached and compared before any redraw: `idle` runs every pass, and a
   page that repainted a string it had already drawn would flicker for
   as long as anyone left it open. */
static ControlRef g_show_button;
static ControlRef g_consent_check;
static char g_policy_status[128];
static char g_shown_policy_status[128];
static char g_show_status[128];
static char g_shown_status[128];
/* The line under the checkbox. Cached and compared like the two above,
   and for one more reason than they have: it names the connected machine,
   so it changes when a link arrives or drops rather than only when
   somebody clicks. */
static char g_consent_note[160];
static char g_shown_consent_note[160];

enum { kMirrorPollTicks = 60 };

/* Every hand-drawn line on this page goes through one walk, taken twice:
   with a NULL writer it draws, with a writer it describes itself to the
   host's observation plane. Two walks would be two chances to disagree,
   and a page that describes something other than what it drew is worse
   than one that describes nothing. */
static void emit_line(const WorkshopSceneWriter *writer, const Rect *where,
                      const char *text)
{
    Str255 ptext;

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, text, where,
                           true);
        return;
    }
    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, ptext);
    TruncString((short)(where->right - where->left), ptext, truncEnd);
    DrawString(ptext);
}

static void emit_row(const WorkshopSceneWriter *writer, const Rect *where,
                     const char *label, const char *value)
{
    Rect left = *where;
    Rect right = *where;

    left.right = (short)(where->left + kMirrorLabelWidth);
    right.left = left.right;
    emit_line(writer, &left, label);
    emit_line(writer, &right, value);
}

static void emit_heading(const WorkshopSceneWriter *writer, const Rect *where,
                         const char *text)
{
    if (writer != NULL) {
        emit_line(writer, where, text);
        return;
    }
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    emit_line(NULL, where, text);
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

/* The consent sentence, rebuilt from the two facts it names: the switch
   and whoever is on the other end of the wire. Called wherever either can
   have moved — page creation, a click, and every idle pass, which is what
   catches a connection arriving while somebody is looking at this page. */
static void refresh_consent_note(void)
{
    char peer[64];

    conn_peer_label(peer, (long)sizeof peer);
    now_mirror_consent_note(now_mirror_policy_enabled(), peer,
                            g_consent_note, (long)sizeof g_consent_note);
}

static OSErr mirror_create(WindowRef owner, const Rect *body)
{
    Str255 title;
    MirrorPolicy policy;

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
    CopyCStringToPascal(now_mirror_policy_name(), title);
    g_consent_check = now_control_new(
        owner, &g_layout.consent_row, title, false,
        policy.enabled ? 1 : 0, 0, 1, checkBoxProc, 0);
    if (g_consent_check == NULL) {
        now_mirror_log_page("create refused: out of memory");
        return memFullErr;
    }
    refresh_consent_note();
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
    g_consent_check = NULL;
    g_owner = NULL;
    g_visible = false;
    now_mirror_log_page("disposed");
}

static void mirror_show(Boolean visible)
{
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
        if (g_consent_check != NULL) ShowControl(g_consent_check);
    } else {
        HideControl(g_show_button);
        if (g_consent_check != NULL) HideControl(g_consent_check);
    }
}

static void mirror_layout(const Rect *body)
{
    g_body = *body;
    now_mirror_layout_compute(body, &g_layout);
    if (g_show_button != NULL) {
        MoveControl(g_show_button, g_layout.show_button.left,
                    g_layout.show_button.top);
    }
    if (g_consent_check != NULL) {
        MoveControl(g_consent_check, g_layout.consent_row.left,
                    g_layout.consent_row.top);
    }
}

static void mirror_content(const WorkshopSceneWriter *writer)
{
    char value[180];
    int i;

    emit_heading(writer, &g_layout.heading, "NOW Extension");
    now_mirror_lifecycle_text(&g_facts, value, (long)sizeof value);
    emit_row(writer, &g_layout.lifecycle_rows[0], "Lifecycle", value);
    if (g_facts.lifecycle == kMirrorLifecycleActive
        || g_facts.lifecycle == kMirrorLifecycleDegraded
        || g_facts.lifecycle == kMirrorLifecycleWrongVersion) {
        snprintf(value, sizeof value, "%lu.%lu", g_facts.resident_major,
                 g_facts.resident_minor);
    } else {
        strcpy(value, "-");
    }
    emit_row(writer, &g_layout.lifecycle_rows[1], "Resident version", value);
    snprintf(value, sizeof value, "cap %lu, requested %lu, active %lu",
             g_facts.capabilities, g_facts.requested_bits,
             g_facts.active_bits);
    emit_row(writer, &g_layout.lifecycle_rows[2], "Plane bits", value);
    snprintf(value, sizeof value, "%s",
             g_facts.has_build_identity ? "Exact build identity available"
                                        : "Build identity unavailable");
    emit_row(writer, &g_layout.lifecycle_rows[3], "Build", value);
    now_mirror_rest_text(&g_facts, value, (long)sizeof value);
    emit_row(writer, &g_layout.lifecycle_rows[4], "Installed", value);

    emit_heading(writer, &g_layout.plane_heading, "Mirror planes");
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        now_mirror_plane_value(&g_facts, (MirrorPlane)i, value,
                               (long)sizeof value);
        emit_row(writer, &g_layout.plane_rows[i],
                 now_mirror_plane_name((MirrorPlane)i), value);
    }
    emit_heading(writer, &g_layout.policy_heading, "Mirroring");
    emit_line(writer, &g_layout.consent_note, g_consent_note);
    emit_line(writer, &g_layout.policy_status, g_policy_status);
    emit_line(writer, &g_layout.show_status, g_show_status);
    if (writer == NULL) {
        /* Only the drawing pass may claim the strings are now on screen;
           describing them changes no pixels, and marking them shown would
           lose the invalidation `idle` owes them. */
        strcpy(g_shown_policy_status, g_policy_status);
        strcpy(g_shown_status, g_show_status);
        strcpy(g_shown_consent_note, g_consent_note);
    }
    for (i = 0; i < kMirrorNoteLines; ++i) {
        emit_line(writer, &g_layout.note[i], now_mirror_note(i));
    }
}

static void mirror_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    mirror_content(NULL);
}

static void mirror_describe_scene(const WorkshopSceneWriter *writer)
{
    mirror_content(writer);
}

/* Edit>Copy: the plane facts, exactly what mirror_content already draws
   and describes — one walk, so nothing here can drift from either.

   Served by pointing this page's own describe_scene at a buffer instead
   of at the host, so what lands on the clipboard is by construction what
   the page describes, which is by construction what it drew. */
static long mirror_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    mirror_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
}

static Boolean mirror_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;

    (void)event;
    if (g_owner == NULL || !g_visible || g_show_button == NULL) {
        return false;
    }
    (void)FindControl(local, g_owner, &control);
    if (control != NULL && control == g_consent_check) {
        Boolean want;
        OSErr err;

        if (TrackControl(control, local, now_pump_action()) == 0) {
            return true;
        }
        want = GetControlValue(control) == 0;
        err = now_mirror_policy_set(want);
        if (err != noErr) {
            snprintf(g_policy_status, sizeof g_policy_status,
                     "Could not save this setting (%d)", (int)err);
            now_log(kLogWarn, "mirror", "consent save failed (%d)",
                    (int)err);
            return true;
        }
        SetControlValue(control, want ? 1 : 0);
        snprintf(g_policy_status, sizeof g_policy_status, "%s: %s",
                 now_mirror_policy_name(), want ? "on" : "off");
        now_log(kLogInfo, "mirror", "mirror consent %s",
                want ? "granted" : "withdrawn");
        refresh_consent_note();
        /* Withdrawing consent is not a preference that takes effect next
           time somebody asks: what is already running stops here. Both
           of these were per-gate before and are now one act, because
           there is now one gate — and a switch that leaves a trace
           running until the next request is a switch a person cannot
           trust. */
        if (!want) {
            now_qdtrace_stop_for_policy();
            now_peek_release(kNowPeekOwnerScene,
                (unsigned long)(kNowPeekCapAnchors | kNowPeekCapTree
                                | kNowPeekTableCapAct));
        }
        return true;
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
    ControlRef controls[2];

    controls[0] = g_show_button;
    controls[1] = g_consent_check;
    for (i = 0; i < 2; ++i) {
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
    /* Rebuilt here rather than only on a click, because the machine it
       names arrives and leaves without one. Rebuilding costs a snprintf;
       the strcmp below is what decides whether anything is repainted. */
    refresh_consent_note();
    if (strcmp(g_consent_note, g_shown_consent_note) != 0) {
        InvalWindowRect(g_owner, &g_layout.consent_note);
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
    {
        int display_changed = !now_mirror_display_equal(&latest, &g_facts);

        /* Keep the complete current snapshot even when its volatile fields
           do not affect the page. A later freshness transition is then
           compared against the latest evidence rather than a stale copy. */
        g_facts = latest;
        if (display_changed) {
            InvalWindowRect(g_owner, &g_body);
        }
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
    mirror_describe_scene,
    mirror_copy_text
};

const WorkshopModuleOps *mirror_module_ops(void)
{
    return &k_ops;
}
