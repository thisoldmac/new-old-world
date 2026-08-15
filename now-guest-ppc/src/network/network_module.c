/*
 * network_module.c - the Networking page.
 *
 * The Workshop shell owns the window; this owns two scrolled cards (TCP/IP
 * and Ports) plus the Connections placard and their Refresh buttons.
 * Every decision about WHAT a card says lives in net_layout.c and
 * net_facts.c, both Toolbox-free and both gated by native tests; this
 * file is rectangles, controls and drawing.
 *
 * "This Connection" used to lead the page - it needed no probe, since
 * NOW already holds the endpoint. It is gone from here now: peer,
 * uptime and round trip are shown live on the Connection page instead
 * (034 G-1), which is where a person looks for them and where the new
 * Test button that forces a fresh round trip lives. This page no longer
 * reads the wire at all - it is Open Transport facts only, which is why
 * it no longer needs wire.h.
 *
 * The Connections card still exists to say what we cannot do. See
 * docs/ot-networking-surface.md: no documented Open Transport call lists
 * a Mac's connections, so that card has no rows and no button and never
 * will. It is present rather than omitted because a person looking for a
 * connection list needs to find the ANSWER where they went looking for
 * the thing - shrunk to one placard line now rather than an essay, since
 * the answer itself is short.
 */

#include "network_module.h"

#include <string.h>

#include "net_layout.h"
#include "net_probe.h"
#include "nowlog.h"
#include "control_kind.h"
#include "workshop_scene_text.h"

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

/* ---------------------------------------------------------------- state */

/* No link sample: this page shows Open Transport facts only now (see the
   file header). now_net_probe's `link` argument may be NULL - it reads
   as "not connected", which is fine because kNetSectionLink is never
   laid out or drawn from here regardless of what it says. */
static void reprobe(void)
{
    now_net_probe(NULL, &g_facts);
    g_probed = true;
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

/* Every fact on this page is hand-drawn text inside a hand-drawn card,
   so nothing here reaches the host except through this walk. A NULL
   writer draws; a writer describes. Both faces take the same walk on
   purpose - the alternative is a second traversal free to disagree with
   the pixels about which section said what. */
static void emit_line(const WorkshopSceneWriter *writer, const Rect *where,
                      const char *text)
{
    Str255 pas;

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopSceneStaticText, text, where,
                           true);
        return;
    }
    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, pas);
    TruncString((short)(where->right - where->left), pas, truncEnd);
    DrawString(pas);
}

static void emit_row(const WorkshopSceneWriter *writer, const Rect *where,
                     const char *label, const char *value)
{
    Rect lab = *where;
    Rect val = *where;

    lab.right = (short)(where->left + kNetLabelWidth);
    val.left = lab.right;
    emit_line(writer, &lab, label);
    emit_line(writer, &val, value);
}

static void emit_section(const WorkshopSceneWriter *writer, int index)
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

    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopScenePanel,
                           now_net_section_title(sec), &card, true);
    } else {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
        FrameRect(&card);
    }

    to_window(&s->title, &line);
    if (writer == NULL) {
        UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    }
    emit_line(writer, &line, now_net_section_title(sec));
    if (writer == NULL) {
        UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    }

    line.top = (short)(line.bottom);
    line.bottom = (short)(line.top + kNetLineHeight);
    line.right = (short)(card.right - kNetCardInset);
    emit_line(writer, &line, now_net_section_blurb(sec));

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
            emit_row(writer, &line, label, value);
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
        emit_line(writer, &line, now_net_state_sentence(st));
    }
}

static void network_describe_scene(const WorkshopSceneWriter *writer)
{
    int i;

    workshop_scene_add(writer, kWorkshopScenePanel, "Networking",
                       &g_r.canvas, true);
    /* emit_section already declines the sections scrolled out of the
       canvas, so the host sees the same cards a person does. */
    for (i = 0; i < (int)kNetSectionCount; ++i) {
        emit_section(writer, i);
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
        emit_section(NULL, i);
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

static void network_status_text(char *out, long cap)
{
    now_net_status_text(&g_facts, out, cap);
}

/* Edit>Copy: the TCP/IP and Ports cards - facts this Mac states about
   itself and cannot otherwise get off it.

   Served by pointing this page's own describe_scene at a buffer instead
   of at the host, so what lands on the clipboard is by construction what
   the page describes, which is by construction what it drew. */
static long network_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    network_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
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
        /* No idle work: the link card that used to change on its own is
           gone from this page (see the file header), and the remaining
           cards - TCP/IP, Ports, Connections - only change when a
           person presses Refresh. */
        NULL,
        network_status_text,
        network_describe_scene,
        network_copy_text
    };

    return &ops;
}
