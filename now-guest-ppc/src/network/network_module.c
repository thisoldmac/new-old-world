/*
 * network_module.c - the Networking page.
 *
 * The Workshop shell owns the window; this owns four scrolled cards and
 * two buttons. Every decision about WHAT a card says lives in
 * net_layout.c and net_facts.c, both Toolbox-free and both gated by
 * native tests; this file is rectangles, controls and drawing.
 *
 * The page's argument, which is why the section order is what it is:
 * "This Connection" comes first because it needs no probe and no Open
 * Transport - NOW is holding the endpoint, so its peer and uptime are
 * facts we already have. A networking page whose resting state is a real
 * measurement is a different thing from one that is empty until someone
 * presses a button, and on a Mac with no TCP/IP configured it is the
 * difference between a page that works and a page that looks broken.
 *
 * The fourth card exists to say what we cannot do. See
 * docs/ot-networking-surface.md: no documented Open Transport call lists
 * a Mac's connections, so that card has no rows and no button and never
 * will. It is present rather than omitted because a person looking for a
 * connection list needs to find the ANSWER where they went looking for
 * the thing.
 */

#include "network_module.h"

#include <string.h>

#include "net_layout.h"
#include "net_probe.h"
#include "nowlog.h"
#include "wire.h"
#include "control_kind.h"

static WindowRef g_owner;
static Rect g_body;
static NetLayout g_r;
static Boolean g_visible;
static NetFacts g_facts;
static Boolean g_probed;

static ControlRef g_scroll;
static ControlRef g_buttons[kNetSectionCount];
static ControlActionUPP g_scroll_action_upp;
static short g_top;

/* What the link card's value column is currently SHOWING. Idle compares
   against this and invalidates only what differs - without it, "has the
   uptime changed" cannot be answered without redrawing to find out. */
static char g_link_vals[kNetMaxRows][80];

/* ---------------------------------------------------------------- state */

/* What NOW already knows about its own link. Read from the wire rather
   than measured here: the connection is the wire's, and a second reader
   of the same counters would be a second source of truth for a fact that
   already has one. */
static void sample_link(NetLinkSample *out)
{
    ConnSnapshot snap;

    memset(out, 0, sizeof *out);
    out->rtt_ms = -1;
    out->quiet_secs = -1;

    conn_snapshot(&snap);
    out->connected = conn_is_connected();
    if (!out->connected) {
        return;
    }
    /* The other Mac's own name when it has sent one, its address until
       then. conn_peer_label exists for exactly this and already refuses
       to say "the host" - guest and host are words for the code, not for
       the person reading the page. */
    conn_peer_label(out->peer, (long)sizeof out->peer);
    out->port = (unsigned long)snap.port;
    out->up_secs = snap.connected_secs > 0
        ? (unsigned long)snap.connected_secs : 0UL;
    out->quiet_secs = snap.quiet_secs;
    out->rtt_ms = conn_last_rtt_ms();
    out->rcv_window = conn_rcv_window();
    out->rcv_peak = conn_rcv_peak();
}

/* Seed the shown-value cache from the facts as they stand, so the next
   idle pass compares against what is on screen rather than against
   nothing and repaints every row once. */
static void seed_link_cache(void)
{
    short rows = now_net_section_rows(kNetSectionLink, &g_facts);
    short i;

    memset(g_link_vals, 0, sizeof g_link_vals);
    for (i = 0; i < rows && i < (short)kNetMaxRows; ++i) {
        char label[48];
        char value[80];

        if (!now_net_row(kNetSectionLink, &g_facts, i, label, sizeof label,
                         value, sizeof value)) {
            break;
        }
        strncpy(g_link_vals[i], value, sizeof g_link_vals[i] - 1);
    }
}

static void reprobe(void)
{
    NetLinkSample link;

    sample_link(&link);
    now_net_probe(&link, &g_facts);
    g_probed = true;
    seed_link_cache();
}

/* The link half changes on its own - bytes move, the clock runs - so it
   is refreshed without a probe. The Open Transport half is not: it costs
   two calls and a port walk, and it changes when a person changes a
   control panel, not while they watch. */
static void refresh_link_only(void)
{
    NetLinkSample link;

    sample_link(&link);
    if (link.connected) {
        g_facts.link.state = kNetFactPresent;
        strncpy(g_facts.link.peer, link.peer, sizeof g_facts.link.peer - 1);
        g_facts.link.peer[sizeof g_facts.link.peer - 1] = '\0';
        g_facts.link.port = link.port;
        g_facts.link.up_secs = link.up_secs;
        g_facts.link.rtt_ms = link.rtt_ms;
        g_facts.link.rcv_window = link.rcv_window;
        g_facts.link.rcv_peak = link.rcv_peak;
        g_facts.link.quiet_secs = link.quiet_secs;
        g_facts.link.has_rtt = (link.rtt_ms >= 0);
        g_facts.link.has_window = (link.rcv_window > 0);
    } else {
        g_facts.link.state = kNetFactNotServed;
    }
}

static void recompute(void)
{
    now_net_layout_compute(&g_body, &g_facts, &g_r);
}

static short canvas_height(void)
{
    return (short)(g_r.canvas.bottom - g_r.canvas.top);
}

static short max_top(void)
{
    short over = (short)(g_r.content_height - canvas_height());

    return over > 0 ? over : 0;
}

static void to_window(const Rect *content, Rect *out)
{
    if (content->right <= content->left) {
        *out = *content;
        return;
    }
    out->left = content->left;
    out->right = content->right;
    out->top = (short)(content->top - g_top + g_r.canvas.top + 1);
    out->bottom = (short)(content->bottom - g_top + g_r.canvas.top + 1);
}

/* Same rule the Diagnostics page established: a push button is a real
   control and draws itself, so the canvas clip cannot hold it. A button
   scrolled even partly out of the viewport is hidden rather than drawn
   across the sidebar. */
static void place_buttons(void)
{
    int i;

    for (i = 0; i < (int)kNetSectionCount; ++i) {
        Rect where;

        if (g_buttons[i] == NULL) {
            continue;
        }
        to_window(&g_r.sections[i].button, &where);
        if (where.right <= where.left || !g_visible
            || where.top < g_r.canvas.top + 1
            || where.bottom > g_r.canvas.bottom - 1) {
            HideControl(g_buttons[i]);
            continue;
        }
        MoveControl(g_buttons[i], where.left, where.top);
        ShowControl(g_buttons[i]);
    }
}

static void sync_scrollbar(void)
{
    short max = max_top();

    if (g_scroll == NULL) {
        return;
    }
    if (g_top > max) {
        g_top = max;
    }
    if (g_top < 0) {
        g_top = 0;
    }
    SetControlMaximum(g_scroll, max);
    SetControlValue(g_scroll, g_top);
    HiliteControl(g_scroll, (max > 0 && g_visible) ? 0 : 255);
}

/* ---------------------------------------------------------------- draw */

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

    lab.right = (short)(where->left + kNetLabelWidth);
    val.left = lab.right;
    draw_line(&lab, label);
    draw_line(&val, value);
}

static void draw_section(int index)
{
    const NetSectionLayout *s = &g_r.sections[index];
    NetSection sec = (NetSection)index;
    Rect card;
    Rect line;
    short rows;
    short i;

    to_window(&s->card, &card);
    if (card.bottom < g_r.canvas.top || card.top > g_r.canvas.bottom) {
        return;                       /* fully scrolled away */
    }

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    FrameRect(&card);

    to_window(&s->title, &line);
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    draw_line(&line, now_net_section_title(sec));
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);

    line.top = (short)(line.bottom);
    line.bottom = (short)(line.top + kNetLineHeight);
    line.right = (short)(card.right - kNetCardInset);
    draw_line(&line, now_net_section_blurb(sec));

    to_window(&s->body, &line);
    line.bottom = (short)(line.top + kNetRowHeight);

    rows = now_net_section_rows(sec, &g_facts);
    if (rows > 0) {
        for (i = 0; i < rows; ++i) {
            char label[48];
            char value[80];

            if (!now_net_row(sec, &g_facts, i, label, sizeof label,
                             value, sizeof value)) {
                break;
            }
            draw_row(&line, label, value);
            line.top = (short)(line.top + kNetRowHeight);
            line.bottom = (short)(line.top + kNetRowHeight);
        }
        return;
    }

    /* No rows. Every such state has a sentence, and the sentence is the
       whole content of the card - which is why the layout gives a
       row-less section body height rather than collapsing it. */
    {
        NetFactState st = kNetFactNotServed;

        switch (sec) {
        case kNetSectionLink:        st = g_facts.link.state; break;
        case kNetSectionInet:        st = g_facts.inet.state; break;
        case kNetSectionPorts:       st = g_facts.ports_state; break;
        case kNetSectionConnections: st = g_facts.connections; break;
        case kNetSectionCount:       break;
        }
        line.bottom = (short)(line.top + kNetLineHeight);
        draw_line(&line, now_net_state_sentence(st));
    }
}

static void draw_canvas(void)
{
    RgnHandle save = NewRgn();
    Rect clip = g_r.canvas;
    int i;

    if (save != NULL) {
        GetClip(save);
    }
    InsetRect(&clip, 1, 1);
    ClipRect(&clip);

    EraseRect(&clip);
    for (i = 0; i < (int)kNetSectionCount; ++i) {
        draw_section(i);
    }

    if (save != NULL) {
        SetClip(save);
        DisposeRgn(save);
    }
    FrameRect(&g_r.canvas);
}

/* ------------------------------------------------------------- scroll */

static void scroll_to(short top, Boolean live)
{
    short max = max_top();

    if (top > max) {
        top = max;
    }
    if (top < 0) {
        top = 0;
    }
    if (top == g_top) {
        return;
    }
    g_top = top;
    if (g_scroll != NULL) {
        SetControlValue(g_scroll, g_top);
    }
    place_buttons();
    if (live) {
        draw_canvas();
    }
}

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    short step = kNetRowHeight * 3;
    short page = (short)(canvas_height() - kNetRowHeight);

    if (page < step) {
        page = step;
    }
    switch (part) {
    case kControlUpButtonPart:   scroll_to((short)(g_top - step), true); break;
    case kControlDownButtonPart: scroll_to((short)(g_top + step), true); break;
    case kControlPageUpPart:     scroll_to((short)(g_top - page), true); break;
    case kControlPageDownPart:   scroll_to((short)(g_top + page), true); break;
    case kControlIndicatorPart:
        scroll_to(GetControlValue(control), true);
        break;
    default:
        break;
    }
}

/* ------------------------------------------------------------- buttons */

static void sync_buttons(void)
{
    int i;

    for (i = 0; i < (int)kNetSectionCount; ++i) {
        const char *title = now_net_button_title((NetSection)i, &g_facts);
        Str255 pas;

        if (g_buttons[i] == NULL) {
            continue;
        }
        if (title == NULL) {
            HideControl(g_buttons[i]);
            continue;
        }
        CopyCStringToPascal(title, pas);
        SetControlTitle(g_buttons[i], pas);
    }
    place_buttons();
}

/* --------------------------------------------------------------- ops */

static OSErr network_create(WindowRef owner, const Rect *body)
{
    Rect r;
    int i;

    g_owner = owner;
    g_body = *body;
    g_top = 0;
    now_net_facts_clear(&g_facts);
    g_probed = false;
    recompute();

    r = g_r.scrollbar;
    g_scroll = now_control_new(owner, &r, (ConstStr255Param)"\p", true, 0, 0, 0,
                          kControlScrollBarLiveProc, 0);
    if (g_scroll == NULL) {
        return memFullErr;
    }
    if (g_scroll_action_upp == NULL) {
        g_scroll_action_upp = NewControlActionUPP(scroll_action);
    }

    for (i = 0; i < (int)kNetSectionCount; ++i) {
        Rect b = g_r.sections[i].button;

        if (b.right <= b.left) {
            g_buttons[i] = NULL;
            continue;
        }
        b.right = (short)(b.left + kNetButtonWidth);
        b.bottom = (short)(b.top + kNetButtonHeight);
        g_buttons[i] = now_control_new(owner, &b, (ConstStr255Param)"\pRefresh",
                                  false, 0, 0, 0,
                                  kControlPushButtonProc, (long)i);
    }

    /* Probed on creation rather than on first click: the page is created
       lazily on first selection, so this IS the person asking. Two
       documented calls and a bounded walk - cheap enough that making
       someone press a button to see their own IP address would be
       ceremony. */
    reprobe();
    recompute();
    sync_scrollbar();
    sync_buttons();
    return noErr;
}

static void network_dispose(void)
{
    int i;

    for (i = 0; i < (int)kNetSectionCount; ++i) {
        if (g_buttons[i] != NULL) {
            now_control_dispose(g_buttons[i]);
            g_buttons[i] = NULL;
        }
    }
    if (g_scroll != NULL) {
        now_control_dispose(g_scroll);
        g_scroll = NULL;
    }
    g_owner = NULL;
    g_visible = false;
}

static void network_show(Boolean visible)
{
    g_visible = visible;
    if (g_scroll != NULL) {
        if (visible) {
            ShowControl(g_scroll);
        } else {
            HideControl(g_scroll);
        }
    }
    sync_scrollbar();
    sync_buttons();
}

static void network_layout(const Rect *body)
{
    Rect r;

    g_body = *body;
    recompute();
    if (g_scroll != NULL) {
        r = g_r.scrollbar;
        MoveControl(g_scroll, r.left, r.top);
        SizeControl(g_scroll, (short)(r.right - r.left),
                    (short)(r.bottom - r.top));
    }
    sync_scrollbar();
    sync_buttons();
}

static void network_draw(void)
{
    draw_canvas();
}

static Boolean network_click(const EventRecord *event, Point local)
{
    ControlRef hit = NULL;
    ControlPartCode part;

    part = FindControl(local, g_owner, &hit);
    if (hit == NULL) {
        return false;
    }
    if (hit == g_scroll) {
        if (part == kControlIndicatorPart) {
            TrackControl(hit, local, NULL);
            scroll_to(GetControlValue(hit), true);
        } else {
            TrackControl(hit, local, g_scroll_action_upp);
        }
        return true;
    }
    {
        int i;

        for (i = 0; i < (int)kNetSectionCount; ++i) {
            if (hit != g_buttons[i]) {
                continue;
            }
            if (TrackControl(hit, local, NULL) == 0) {
                return true;
            }
            /* Both Refresh buttons re-run the same probe: the two
               sections come from one call each and there is nothing to
               gain from asking for half of it. */
            now_log(kLogInfo, "net", "refresh requested");
            reprobe();
            recompute();
            sync_scrollbar();
            sync_buttons();
            draw_canvas();
            return true;
        }
    }
    (void)event;
    return false;
}

static Boolean network_key(const EventRecord *event)
{
    (void)event;
    return false;
}

static void network_activate(Boolean active)
{
    if (g_scroll != NULL) {
        HiliteControl(g_scroll, (active && max_top() > 0) ? 0 : 255);
    }
}

/* The window rect of one link row's VALUE column - the only part of this
   page that changes without anyone asking. */
static void link_value_rect(short row, Rect *out)
{
    const NetSectionLayout *s = &g_r.sections[kNetSectionLink];
    Rect content;

    content.left = (short)(s->body.left + kNetLabelWidth);
    content.right = s->body.right;
    content.top = (short)(s->body.top + row * kNetRowHeight);
    content.bottom = (short)(content.top + kNetRowHeight);
    to_window(&content, out);
}

/* The link counters move on their own, so idle refreshes THEM - and
   invalidates only the values that actually changed, the way the
   Connection page's glance does. It does NOT redraw the canvas.
   Repainting everything on every event-loop pass is a visible flicker on
   this hardware and was exactly the defect reported on 2026-08-01: an
   idle handler runs many times a second, and the finest thing this page
   can say is a whole second, so almost every one of those repaints drew
   the same pixels again.

   Open Transport is never re-asked here either: an idle handler running
   two OT calls per pass would be a probe nobody asked for, and this
   project's rule is that probes run on request. */
static void network_idle(void)
{
    NetFactState before;
    short rows;
    short i;

    if (!g_visible || !g_probed || g_owner == NULL) {
        return;
    }
    before = g_facts.link.state;
    rows = now_net_section_rows(kNetSectionLink, &g_facts);
    refresh_link_only();

    if (before != g_facts.link.state
        || rows != now_net_section_rows(kNetSectionLink, &g_facts)) {
        /* Connecting or disconnecting changes the row COUNT, so the page
           is re-laid out and redrawn in full. Rare, and the one case
           where a whole repaint is the honest answer. */
        recompute();
        sync_scrollbar();
        sync_buttons();
        InvalWindowRect(g_owner, &g_r.canvas);
        return;
    }

    rows = now_net_section_rows(kNetSectionLink, &g_facts);
    for (i = 0; i < rows && i < (short)kNetMaxRows; ++i) {
        char label[48];
        char value[80];
        Rect r;

        if (!now_net_row(kNetSectionLink, &g_facts, i, label, sizeof label,
                         value, sizeof value)) {
            break;
        }
        if (strcmp(value, g_link_vals[i]) == 0) {
            continue;                 /* same pixels; do not draw them */
        }
        strncpy(g_link_vals[i], value, sizeof g_link_vals[i] - 1);
        g_link_vals[i][sizeof g_link_vals[i] - 1] = '\0';
        link_value_rect(i, &r);
        InvalWindowRect(g_owner, &r);
    }
}

static void network_status_text(char *out, long cap)
{
    now_net_status_text(&g_facts, out, cap);
}

const WorkshopModuleOps *network_module_ops(void)
{
    static const WorkshopModuleOps ops = {
        network_create,
        network_dispose,
        network_show,
        network_layout,
        network_draw,
        network_click,
        network_key,
        network_activate,
        network_idle,
        network_status_text,
        NULL
    };

    return &ops;
}
