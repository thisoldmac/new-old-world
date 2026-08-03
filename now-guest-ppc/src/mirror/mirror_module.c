/*
 * mirror_module.c - the Mirror page.
 *
 * Mirror is not NOW. It is a separate application with its own wire, its
 * own host and its own three resident extensions, and it happens to live
 * on the same Macintosh. This page is a window onto it and a switch for
 * the one part of it that HAS a switch. It reads Gestalt, it walks the
 * Process Manager, it launches an application and it asks one to quit -
 * and it does nothing else to Mirror at all.
 *
 * The page's argument is the asymmetry between its two halves. An
 * extension is loaded by the system at startup and by nothing afterwards,
 * so the three extension rows have no controls and say so in the two
 * lines beneath them. The agent is an ordinary application, so it gets
 * two ordinary push buttons. Drawing the halves alike - three switches
 * that quietly did nothing - is the defect class this project has paid
 * for more than once, and the sentence is cheaper than the explanation.
 *
 * The Toolbox lives in mirror_probe.c; the words live in
 * mirror_layout.c, where the native test can reach them. What is left
 * here is rectangles, two controls and the repaint caches.
 */

#include "mirror_module.h"

#include <string.h>

#include "mirror_layout.h"
#include "mirror_probe.h"
#include "nowlog.h"
#include "pump.h"
#include "control_kind.h"

static WindowRef g_owner;
static Rect g_body;
static MirrorLayout g_r;
static Boolean g_visible;
static MirrorFacts g_facts;

static ControlRef g_enable;
static ControlRef g_disable;

/* What each half of the page is currently SHOWING. Idle compares against
   these and invalidates only what differs - the rule every module here
   keeps, because during a transfer the event loop runs unslept and an
   unconditional repaint is a visible flicker on this hardware.

   The extension rows have no cache and need none: nothing can load or
   unload one while the Mac is running, so what was drawn on the first
   update is still true. */
static char g_shown_agent[kMirrorAgentRows][160];
static char g_shown_note[kMirrorNoteLines][160];
static short g_shown_enable_hilite = -1;
static short g_shown_disable_hilite = -1;

/* Idle runs every pass; the Process Manager walk does not. One second is
   finer than anyone can perceive an application starting, and coarse
   enough that the walk is not on the hot path. */
enum { kMirrorPollTicks = 60, kMirrorQuitGraceTicks = 60 * 6 };

static UInt32 g_next_poll;

/* When the quit was sent, or 0. It exists so that an agent which DECLINES
   to quit is reported rather than left looking like a page that ignored
   the button. */
static UInt32 g_quit_asked;

/* --------------------------------------------------------------- draw */

static void draw_line(const Rect *where, const char *text)
{
    Str255 pas;

    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, pas);
    TruncString((short)(where->right - where->left), pas, truncEnd);
    DrawString(pas);
}

static void draw_row(const Rect *where, const char *label, const char *value)
{
    Rect lab = *where;
    Rect val = *where;

    lab.right = (short)(where->left + kMirrorLabelWidth);
    val.left = lab.right;
    draw_line(&lab, label);
    draw_line(&val, value);
}

static void draw_heading(const Rect *where, const char *text)
{
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    draw_line(where, text);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

static void draw_agent_rows(void)
{
    int i;

    for (i = 0; i < kMirrorAgentRows; ++i) {
        char label[32];
        char value[160];

        if (!now_mirror_agent_row(&g_facts, i, label, (long)sizeof label,
                                  value, (long)sizeof value)) {
            break;
        }
        draw_row(&g_r.agent_rows[i], label, value);
        strncpy(g_shown_agent[i], value, sizeof g_shown_agent[i] - 1);
        g_shown_agent[i][sizeof g_shown_agent[i] - 1] = '\0';
    }
}

static void draw_note(void)
{
    int i;

    for (i = 0; i < kMirrorNoteLines; ++i) {
        char line[160];

        if (now_mirror_note_line(&g_facts, i, line, (long)sizeof line) > 0) {
            draw_line(&g_r.note[i], line);
        }
        strncpy(g_shown_note[i], line, sizeof g_shown_note[i] - 1);
        g_shown_note[i][sizeof g_shown_note[i] - 1] = '\0';
    }
}

static void draw_page(void)
{
    int i;

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_heading(&g_r.ext_heading, "Mirror's resident extensions");
    for (i = 0; i < kMirrorExtCount; ++i) {
        char value[160];

        now_mirror_ext_value(&g_facts, (MirrorExt)i, value,
                             (long)sizeof value);
        draw_row(&g_r.ext_rows[i], now_mirror_ext_name((MirrorExt)i), value);
    }
    for (i = 0; i < kMirrorExtNoteLines; ++i) {
        draw_line(&g_r.ext_note[i], now_mirror_ext_note(i));
    }

    draw_heading(&g_r.agent_heading, "Mirror's agent");
    draw_agent_rows();
    draw_note();
}

/* ------------------------------------------------------------- controls */

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

/* HiliteControl redraws whatever it is passed, so it is called only when
   the answer has actually changed. An unconditional call here would be a
   flicker loop on a page whose idle handler runs every pass. */
static void sync_buttons(void)
{
    short want_enable = now_mirror_can_enable(&g_facts) ? 0 : 255;
    short want_disable = now_mirror_can_disable(&g_facts) ? 0 : 255;

    if (g_enable != NULL && want_enable != g_shown_enable_hilite) {
        HiliteControl(g_enable, want_enable);
        g_shown_enable_hilite = want_enable;
    }
    if (g_disable != NULL && want_disable != g_shown_disable_hilite) {
        HiliteControl(g_disable, want_disable);
        g_shown_disable_hilite = want_disable;
    }
}

/* Everything the agent half draws, repainted because an action just
   changed it. The extension half is untouched: a button press cannot
   load or unload an extension, and repainting it would only make the
   page flash. */
static void refresh_agent_half(void)
{
    int i;

    if (g_owner == NULL) {
        return;
    }
    sync_buttons();
    for (i = 0; i < kMirrorAgentRows; ++i) {
        InvalWindowRect(g_owner, &g_r.agent_rows[i]);
    }
    for (i = 0; i < kMirrorNoteLines; ++i) {
        InvalWindowRect(g_owner, &g_r.note[i]);
    }
}

/* --------------------------------------------------------------- ops */

static OSErr mirror_create(WindowRef owner, const Rect *body)
{
    g_owner = owner;
    g_body = *body;
    memset(&g_facts, 0, sizeof g_facts);
    memset(g_shown_agent, 0, sizeof g_shown_agent);
    memset(g_shown_note, 0, sizeof g_shown_note);
    g_shown_enable_hilite = -1;
    g_shown_disable_hilite = -1;
    g_quit_asked = 0;
    now_mirror_layout_compute(body, &g_r);

    /* Probed on creation rather than behind a Refresh button: the page is
       created lazily on first selection, so this IS somebody asking. Three
       Gestalt traps and one catalog walk. */
    now_mirror_probe(&g_facts);
    g_next_poll = TickCount() + kMirrorPollTicks;

    g_enable = now_control_new(owner, &g_r.enable, (ConstStr255Param)"\pEnable",
                          false, 0, 0, 0, kControlPushButtonProc, 0);
    if (g_enable == NULL) {
        return memFullErr;
    }
    g_disable = now_control_new(owner, &g_r.disable, (ConstStr255Param)"\pDisable",
                           false, 0, 0, 0, kControlPushButtonProc, 0);
    if (g_disable == NULL) {
        return memFullErr;
    }
    sync_buttons();
    return noErr;
}

static void mirror_dispose(void)
{
    /* The controls die with the window, and no UPP is constructed here -
       TrackControl is handed pump.c's action proc, which pump.c owns. */
    g_owner = NULL;
    g_enable = NULL;
    g_disable = NULL;
    g_visible = false;
}

static void mirror_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_enable, visible);
    show_control(g_disable, visible);
    if (visible) {
        sync_buttons();
    }
}

static void place(ControlRef control, const Rect *where)
{
    if (control == NULL) {
        return;
    }
    MoveControl(control, where->left, where->top);
    SizeControl(control, (SInt16)(where->right - where->left),
                (SInt16)(where->bottom - where->top));
}

static void mirror_layout(const Rect *body)
{
    g_body = *body;
    now_mirror_layout_compute(body, &g_r);
    place(g_enable, &g_r.enable);
    place(g_disable, &g_r.disable);
}

static void mirror_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    draw_page();
}

static Boolean mirror_click(const EventRecord *event, Point local)
{
    ControlRef hit = NULL;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &hit) == 0 || hit == NULL) {
        return false;
    }
    if (hit != g_enable && hit != g_disable) {
        return false;
    }
    /* now_pump_action(): a finger resting on a push button holds the
       Control Manager's tracking loop, and the wire is serviced from the
       main loop it is holding. */
    if (TrackControl(hit, local, now_pump_action()) == 0) {
        return true;                  /* released outside; nothing asked */
    }
    if (hit == g_enable) {
        now_log(kLogInfo, "mirror", "start requested");
        now_mirror_agent_start(&g_facts);
        g_quit_asked = 0;
    } else {
        now_log(kLogInfo, "mirror", "quit requested");
        now_mirror_agent_stop(&g_facts);
        g_quit_asked = TickCount();
    }
    g_next_poll = TickCount() + kMirrorPollTicks;
    refresh_agent_half();
    return true;
}

static void mirror_activate(Boolean active)
{
    /* Reassert the enabled/disabled answer rather than blanket-activate:
       a button that cannot act must stay dimmed when the window comes
       forward, and ActivateControl would light both of them. */
    g_shown_enable_hilite = -1;
    g_shown_disable_hilite = -1;
    if (active) {
        sync_buttons();
        return;
    }
    if (g_enable != NULL) {
        DeactivateControl(g_enable);
    }
    if (g_disable != NULL) {
        DeactivateControl(g_disable);
    }
}

static void mirror_idle(void)
{
    MirrorAgentState before;
    int i;

    if (g_owner == NULL || !g_visible) {
        return;                       /* hidden pages cost nothing */
    }
    if ((long)(TickCount() - g_next_poll) < 0) {
        return;                       /* the cheap path, most passes */
    }
    g_next_poll = TickCount() + kMirrorPollTicks;

    /* The agent can start or stop without anyone touching this page - the
       Finder can launch it, a crash can end it - so its state is polled.
       The extensions are NOT: nothing loads or unloads one while the Mac
       is running, and asking Gestalt about that every second would be
       three traps a second spent to learn what cannot change. */
    before = g_facts.agent;
    now_mirror_poll_agent(&g_facts);

    if (g_quit_asked != 0) {
        if (g_facts.agent != kMirrorAgentRunning) {
            strncpy(g_facts.note, "The Mirror agent has quit.",
                    sizeof g_facts.note - 1);
            g_facts.note[sizeof g_facts.note - 1] = '\0';
            g_quit_asked = 0;
        } else if ((long)(TickCount() - (g_quit_asked
                                         + kMirrorQuitGraceTicks)) >= 0) {
            /* The outcome that must never read as success: the event was
               delivered and the process is still there. Say it once, then
               stop claiming anything about the request. */
            strncpy(g_facts.note,
                    "The Mirror agent was asked to quit and is still "
                    "running. It declined, or it is busy.",
                    sizeof g_facts.note - 1);
            g_facts.note[sizeof g_facts.note - 1] = '\0';
            g_quit_asked = 0;
        }
    }

    if (before != g_facts.agent) {
        refresh_agent_half();
        return;
    }
    /* Same state, but a row's WORDS can still have moved - the signature
       arrives with the process. Compare what would be drawn against what
       is drawn, and invalidate only those. */
    for (i = 0; i < kMirrorAgentRows; ++i) {
        char label[32];
        char value[160];

        if (!now_mirror_agent_row(&g_facts, i, label, (long)sizeof label,
                                  value, (long)sizeof value)) {
            break;
        }
        if (strcmp(value, g_shown_agent[i]) != 0) {
            InvalWindowRect(g_owner, &g_r.agent_rows[i]);
        }
    }
    for (i = 0; i < kMirrorNoteLines; ++i) {
        char line[160];

        (void)now_mirror_note_line(&g_facts, i, line, (long)sizeof line);
        if (strcmp(line, g_shown_note[i]) != 0) {
            InvalWindowRect(g_owner, &g_r.note[i]);
        }
    }
    sync_buttons();
}

static void mirror_status_text(char *out, long cap)
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
    NULL,                             /* no keys: two buttons and text */
    mirror_activate,
    mirror_idle,
    mirror_status_text,
    NULL
};

const WorkshopModuleOps *mirror_module_ops(void)
{
    return &k_ops;
}
