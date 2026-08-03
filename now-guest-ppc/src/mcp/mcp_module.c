#include "mcp_module.h"

#include <string.h>

#include "agent_access.h"
#include "mcp_layout.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"

/* The MCP page: one control and an honest account of it.

   The division is not this page's to revisit. The other Mac runs the MCP
   server, owns its endpoint and its lifecycle, and enforces what an agent
   may do; this Mac owns exactly one fact - whether it consents to being
   driven, and how far - which it states in `hello`, revises with
   `agent.access` when it changes, and never enforces.
   So the page is a three-rung ladder and a short account of what has
   been said, and it deliberately shows no counters: who is attached and
   what they have done are the host's knowledge, and a row of zeroes
   standing in for it is the visual shape of something that failed to
   load. The resting state of this page, on almost every machine, is
   nothing connected - it has to read as waiting.

   The tier itself is NOT stored here. agent_access.c is the one place
   that decides, because it is the one `hello` asks; this page is a view
   onto that and a caller of its setter. */

static WindowRef g_owner;
static Rect g_body;
static McpLayout g_r;
static Boolean g_visible;

static ControlRef g_group;
static ControlRef g_radios[kMcpTierCount];

/* What this link has actually been told is asked of the wire, not tracked
   here: `agent.access` now revises the tier mid-session, so the page would
   otherwise be modelling a conversation it does not conduct. It used to
   record the tier when it saw the link come up and call that "what hello
   carried" - true every time anyone tried it, and still this file
   inferring another file's behaviour. */
static Boolean g_shown_connected;

/* Repaint caches: idle runs every pass, unslept during a transfer, so
   the account below the box repaints only when its words change. */
static char g_shown_lines[kMcpAnswerLines][160];

static void current_answer(McpAnswer *out)
{
    memset(out, 0, sizeof *out);
    out->tier = now_agent_access_tier();
    out->connected = conn_is_connected();
    out->sent_known = now_wire_agent_access_told(&out->sent);
    if (out->connected) {
        conn_peer_label(out->peer, sizeof out->peer);
    }
}

static void draw_account(void)
{
    McpAnswer answer;
    Str255 text;
    char line[160];
    int i;

    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    MoveTo(g_r.answer_heading.left,
           (short)(g_r.answer_heading.top + 12));
    CopyCStringToPascal("What this Mac has said", text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    current_answer(&answer);
    for (i = 0; i < kMcpAnswerLines; ++i) {
        if (mcp_answer_line(&answer, i, line, (long)sizeof line) == 0) {
            g_shown_lines[i][0] = '\0';   /* no line, not a blank one */
            continue;
        }
        MoveTo(g_r.answer_lines[i].left,
               (short)(g_r.answer_lines[i].top + 11));
        CopyCStringToPascal(line, text);
        TruncString((short)(g_r.answer_lines[i].right
                            - g_r.answer_lines[i].left),
                    text, truncEnd);
        DrawString(text);
        strcpy(g_shown_lines[i], line);
    }
}

static void sync_radios(void)
{
    AgentAccessTier tier = now_agent_access_tier();
    int i;

    for (i = 0; i < kMcpTierCount; ++i) {
        if (g_radios[i] == NULL) {
            continue;
        }
        /* SetControlValue redraws whatever it is passed, so only the ones
           that actually differ are touched. */
        if (GetControlValue(g_radios[i]) != ((int)tier == i ? 1 : 0)) {
            SetControlValue(g_radios[i], (int)tier == i ? 1 : 0);
        }
    }
}

/* --- module ops --------------------------------------------------------- */

static OSErr mcp_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    int i;

    g_owner = owner;
    g_body = *body;
    mcp_layout_compute(body, &g_r);
    memset(g_shown_lines, 0, sizeof g_shown_lines);

    CopyCStringToPascal("Agent access", text);
    g_group = now_control_new(owner, &g_r.access_box, text, false, 0, 0, 0,
                         kControlGroupBoxTextTitleProc, 0);
    if (g_group == NULL) {
        return memFullErr;
    }
    for (i = 0; i < kMcpTierCount; ++i) {
        CopyCStringToPascal(mcp_tier_label((AgentAccessTier)i), text);
        g_radios[i] = now_control_new(owner, &g_r.radios[i], text, false, 0, 0,
                                 1, radioButProc, 0);
        if (g_radios[i] == NULL) {
            return memFullErr;
        }
    }
    sync_radios();
    /* Only for noticing the link CHANGE below; what was said comes from
       the wire, which knows it whether this page was open or not. */
    g_shown_connected = conn_is_connected();
    return noErr;
}

static void mcp_dispose(void)
{
    int i;

    /* Controls die with the window; no UPP is constructed here. */
    g_owner = NULL;
    g_group = NULL;
    for (i = 0; i < kMcpTierCount; ++i) {
        g_radios[i] = NULL;
    }
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

static void mcp_show(Boolean visible)
{
    int i;

    g_visible = visible;
    show_control(g_group, visible);
    for (i = 0; i < kMcpTierCount; ++i) {
        show_control(g_radios[i], visible);
    }
    if (visible) {
        sync_radios();
    }
}

static void mcp_layout(const Rect *body)
{
    int i;

    g_body = *body;
    mcp_layout_compute(body, &g_r);
    if (g_group != NULL) {
        MoveControl(g_group, g_r.access_box.left, g_r.access_box.top);
        SizeControl(g_group,
                    (SInt16)(g_r.access_box.right - g_r.access_box.left),
                    (SInt16)(g_r.access_box.bottom - g_r.access_box.top));
    }
    for (i = 0; i < kMcpTierCount; ++i) {
        if (g_radios[i] != NULL) {
            MoveControl(g_radios[i], g_r.radios[i].left, g_r.radios[i].top);
            SizeControl(g_radios[i],
                        (SInt16)(g_r.radios[i].right - g_r.radios[i].left),
                        (SInt16)(g_r.radios[i].bottom - g_r.radios[i].top));
        }
    }
}

static void mcp_draw(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    draw_account();
}

static Boolean mcp_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    int i, line;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (FindControl(local, g_owner, &control) == 0 || control == NULL) {
        return false;
    }
    for (i = 0; i < kMcpTierCount; ++i) {
        if (control != g_radios[i]) {
            continue;
        }
        if (TrackControl(control, local, now_pump_action()) != 0
            && now_agent_access_tier() != (AgentAccessTier)i) {
            /* Stores, and tells a host already on the line. */
            now_agent_access_set_tier((AgentAccessTier)i);
            sync_radios();
            /* Every line, not the three that used to change: the setter
               above now announces, so the line saying what the host has
               been told changes on this click too. Idle would have caught
               it a pass later, which is a flicker on the one page whose
               job is to be believed about permissions. */
            InvalWindowRect(g_owner, &g_r.answer_heading);
            for (line = 0; line < kMcpAnswerLines; ++line) {
                InvalWindowRect(g_owner, &g_r.answer_lines[line]);
            }
        }
        return true;
    }
    return false;
}

static void mcp_activate(Boolean active)
{
    int i;

    for (i = 0; i < kMcpTierCount; ++i) {
        if (g_radios[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(g_radios[i]);
        } else {
            DeactivateControl(g_radios[i]);
        }
    }
}

static void mcp_idle(void)
{
    McpAnswer answer;
    char line[160];
    Boolean connected;
    Boolean changed = false;
    int i;

    if (g_owner == NULL) {
        return;
    }
    connected = conn_is_connected();
    if (connected != g_shown_connected) {
        /* The link changed, so the account below has changed with it. What
           it says was told is the wire's to report, not this page's to
           deduce from having watched this moment. */
        g_shown_connected = connected;
    }
    if (!g_visible) {
        return;                       /* hidden pages cost nothing */
    }
    current_answer(&answer);
    for (i = 0; i < kMcpAnswerLines; ++i) {
        (void)mcp_answer_line(&answer, i, line, (long)sizeof line);
        if (strcmp(line, g_shown_lines[i]) != 0) {
            changed = true;
            break;
        }
    }
    if (changed) {
        for (i = 0; i < kMcpAnswerLines; ++i) {
            InvalWindowRect(g_owner, &g_r.answer_lines[i]);
        }
    }
}

static void mcp_status_line(char *out, long cap)
{
    McpAnswer answer;

    current_answer(&answer);
    mcp_status_text(&answer, out, cap);
}

static const WorkshopModuleOps k_ops = {
    mcp_create,
    mcp_dispose,
    mcp_show,
    mcp_layout,
    mcp_draw,
    mcp_click,
    NULL,                             /* no key handling: one control */
    mcp_activate,
    mcp_idle,
    mcp_status_line,
    NULL
};

const WorkshopModuleOps *mcp_module_ops(void)
{
    return &k_ops;
}
