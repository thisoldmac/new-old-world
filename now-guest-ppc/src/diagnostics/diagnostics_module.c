#include "diagnostics_module.h"

#include <string.h>

#include "diag_layout.h"
#include "fileshare.h"
#include "pump.h"
#include "vprobe.h"
#include "wire.h"

/* The Diagnostics page: what this Mac can measure about itself, run from
   the machine itself rather than only from the wire.

   Three cards, stacked in a scrolled canvas. Every one of them states
   what it measures and what it costs BEFORE it is spent, and a card the
   Carbon guest does not serve carries no button - the availability rules
   and the reasons for them live in diag_layout.h, which is also where
   every sentence on this page is chosen, because that file is the one the
   native test compiles.

   The cards' RESULTS are rows of label and value, drawn by hand: they
   arrive as a probe's own vocabulary rather than a fixed schema, and a
   Data Browser would be a list control's worth of machinery for text
   that never scrolls independently of the card it sits in. */

enum {
    kCardFrameGray = 0xAAAA
};

typedef struct DiagCard {
    DiagCardState state;
    short row_count;
    DiagRow rows[kDiagMaxRows];
    char refusal[96];
} DiagCard;

static WindowRef g_owner;
static Rect g_body;
static DiagLayout g_r;
static Boolean g_visible;
static DiagCard g_cards[kDiagProbeCount];

static ControlRef g_scroll;
static ControlRef g_buttons[kDiagProbeCount];
static ControlActionUPP g_scroll_action_upp;

/* First visible pixel of the content, never a line index: cards are of
   different heights, so there is no row to count in. */
static short g_top;

static void gather_states(DiagCardState *states, short *rows)
{
    int i;

    for (i = 0; i < kDiagProbeCount; ++i) {
        states[i] = g_cards[i].state;
        rows[i] = g_cards[i].row_count;
    }
}

static void recompute(void)
{
    DiagCardState states[kDiagProbeCount];
    short rows[kDiagProbeCount];

    gather_states(states, rows);
    diag_layout_compute(&g_body, states, rows, &g_r);
}

static short canvas_height(void)
{
    return (short)(g_r.canvas.bottom - g_r.canvas.top - 2);
}

static short max_top(void)
{
    short over = (short)(g_r.content_height - canvas_height());

    return over > 0 ? over : 0;
}

/* A card rectangle in window coordinates, or an empty one when the card
   has none (an absent probe's button). */
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

/* Buttons are real controls and draw themselves, so the canvas clip that
   keeps card text inside the viewport cannot hold them. A button scrolled
   even partly out is HIDDEN instead - a push button drawn across the
   sidebar is worse than one a scroll away. */
static void place_buttons(void)
{
    int i;

    for (i = 0; i < kDiagProbeCount; ++i) {
        Rect where;

        if (g_buttons[i] == NULL) {
            continue;
        }
        to_window(&g_r.cards[i].button, &where);
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

static void draw_line(const Rect *where, const char *text)
{
    Str255 pas;

    MoveTo(where->left, (short)(where->top + 11));
    CopyCStringToPascal(text, pas);
    TruncString((short)(where->right - where->left), pas, truncEnd);
    DrawString(pas);
}

static void draw_card(int index)
{
    const DiagCardLayout *card = &g_r.cards[index];
    const DiagCard *state = &g_cards[index];
    Rect frame;
    Rect where;
    Str255 pas;
    char line[192];
    RGBColor gray = { kCardFrameGray, kCardFrameGray, kCardFrameGray };
    RGBColor black = { 0, 0, 0 };
    short y;
    int i;

    to_window(&card->card, &frame);
    if (frame.bottom < g_r.canvas.top || frame.top > g_r.canvas.bottom) {
        return;                       /* wholly scrolled away */
    }
    RGBForeColor(&gray);
    FrameRect(&frame);
    RGBForeColor(&black);

    to_window(&card->title, &where);
    UseThemeFont(kThemeSmallEmphasizedSystemFont, smSystemScript);
    MoveTo(where.left, (short)(where.top + 12));
    CopyCStringToPascal(diag_probe_title((DiagProbe)index), pas);
    DrawString(pas);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    /* The verb, quietly, after the name: it is what a person types in the
       Console and what the other Mac's page calls the same measurement. */
    DrawString((ConstStr255Param)"\p  ");
    CopyCStringToPascal(diag_probe_verb((DiagProbe)index), pas);
    DrawString(pas);

    to_window(&card->measures, &where);
    draw_line(&where, diag_probe_measures((DiagProbe)index));
    to_window(&card->cost, &where);
    draw_line(&where, diag_probe_cost((DiagProbe)index));

    to_window(&card->body, &where);
    y = where.top;
    if (state->state == kDiagRefused) {
        /* The probe's own sentence, verbatim. Rewording a machine's
           account of why it could not measure is this page explaining
           something it did not do. */
        Rect line_rect = where;

        line_rect.bottom = (short)(y + kDiagLineHeight);
        draw_line(&line_rect, state->refusal);
        return;
    }
    if (state->state == kDiagRows) {
        for (i = 0; i < state->row_count; ++i) {
            Rect label_rect;
            Rect value_rect;

            label_rect = where;
            label_rect.top = y;
            label_rect.bottom = (short)(y + kDiagRowHeight);
            label_rect.right = (short)(where.left + kDiagRowLabelWidth);
            draw_line(&label_rect, state->rows[i].label);
            value_rect = where;
            value_rect.top = y;
            value_rect.bottom = label_rect.bottom;
            value_rect.left = (short)(where.left + kDiagRowLabelWidth);
            draw_line(&value_rect, state->rows[i].value);
            y = (short)(y + kDiagRowHeight);
        }
        return;
    }
    for (i = 0; i < kDiagBodyLines; ++i) {
        Rect line_rect;

        if (diag_body_line((DiagProbe)index, state->state, i, line,
                           (long)sizeof line) == 0) {
            continue;
        }
        line_rect = where;
        line_rect.top = y;
        line_rect.bottom = (short)(y + kDiagLineHeight);
        draw_line(&line_rect, line);
        y = (short)(y + kDiagLineHeight);
    }
}

static void draw_canvas(void)
{
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    RgnHandle saved_clip;
    Rect inner;
    int i;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    FrameRect(&g_r.canvas);
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    inner = g_r.canvas;
    InsetRect(&inner, 1, 1);
    EraseRect(&inner);
    RGBBackColor(&saved_back);

    /* Everything below draws in content coordinates shifted by the scroll
       offset, so a partly visible card must not spill past the frame. */
    saved_clip = NewRgn();
    if (saved_clip != NULL) {
        GetClip(saved_clip);
        ClipRect(&inner);
    }
    for (i = 0; i < kDiagProbeCount; ++i) {
        draw_card(i);
    }
    if (saved_clip != NULL) {
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
    }
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

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
    SetControlValue(g_scroll, g_top);
    place_buttons();
    if (live) {
        draw_canvas();                /* mid-track: paint now, not later */
    } else if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_r.canvas);
    }
}

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    short delta = 0;
    short page = (short)(canvas_height() - kDiagLineHeight);

    (void)control;
    if (page < kDiagLineHeight) {
        page = kDiagLineHeight;
    }
    switch (part) {
    case kControlUpButtonPart:
        delta = -kDiagLineHeight;
        break;
    case kControlDownButtonPart:
        delta = kDiagLineHeight;
        break;
    case kControlPageUpPart:
        delta = (short)-page;
        break;
    case kControlPageDownPart:
        delta = page;
        break;
    default:
        break;
    }
    if (delta != 0) {
        scroll_to((short)(g_top + delta), true);
    }
    now_wire_pump();                  /* a held arrow must not starve the wire */
}

/* A card's height depends on its state, so anything that changes a state
   re-lays the page out before it repaints. */
static void state_changed(void)
{
    recompute();
    sync_scrollbar();
    place_buttons();
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_r.canvas);
    }
}

static void update_button_title(int index)
{
    Str255 text;
    const char *title = diag_button_title((DiagProbe)index,
                                          g_cards[index].state);

    if (g_buttons[index] == NULL || title == NULL) {
        return;
    }
    CopyCStringToPascal(title, text);
    SetControlTitle(g_buttons[index], text);
}

static void run_vprobe(void)
{
    VProbeRow probe_rows[kDiagMaxRows];
    DiagCard *card = &g_cards[kDiagVProbe];
    char err[96];
    int n;
    int i;

    /* Three seconds with the wire unpumped, deliberately: the probe times
       tight read loops and servicing the network inside them would
       measure the servicing. The console's `vprobe` makes the same
       trade, and the card said the cost before the button was pressed. */
    card->state = kDiagRunning;
    state_changed();
    /* Painted here rather than left to the update event: the call below
       blocks for three seconds without reaching the event loop, so an
       invalidated rectangle would be repainted only once the answer is
       already in - which is to say never, as far as anyone watching is
       concerned. */
    update_button_title(kDiagVProbe);
    draw_canvas();
    err[0] = '\0';
    n = now_vprobe_run(probe_rows, kDiagMaxRows, err, (long)sizeof err);
    if (n < 0) {
        card->row_count = 0;
        card->state = kDiagRefused;
        strncpy(card->refusal, err[0] != '\0' ? err
                                              : "The probe gave no reason.",
                sizeof card->refusal - 1);
        card->refusal[sizeof card->refusal - 1] = '\0';
        state_changed();
        return;
    }
    if (n > kDiagMaxRows) {
        n = kDiagMaxRows;
    }
    for (i = 0; i < n; ++i) {
        strncpy(card->rows[i].label, probe_rows[i].label,
                sizeof card->rows[i].label - 1);
        card->rows[i].label[sizeof card->rows[i].label - 1] = '\0';
        strncpy(card->rows[i].value, probe_rows[i].value,
                sizeof card->rows[i].value - 1);
        card->rows[i].value[sizeof card->rows[i].value - 1] = '\0';
    }
    card->row_count = (short)n;
    card->state = kDiagRows;
    state_changed();
}

static void read_putstat(void)
{
    FileReceiveStats st;
    DiagPutStat plain;
    DiagCard *card = &g_cards[kDiagPutStat];

    now_files_receive_stats(&st);
    plain.chunks = st.chunks;
    plain.writes = st.writes;
    plain.bytes = st.bytes;
    plain.resumed_from = st.resumed_from;
    plain.us_write = st.us_write;
    plain.us_total = st.us_total;
    plain.crc = st.crc;
    if (!diag_putstat_has_run(&plain)) {
        /* Eleven honest zeroes withheld on purpose - see diag_layout.h. */
        card->row_count = 0;
        card->state = kDiagNothingYet;
        state_changed();
        return;
    }
    card->row_count = (short)diag_putstat_rows(&plain, card->rows,
                                               kDiagMaxRows);
    card->state = kDiagRows;
    state_changed();
}

/* --- module ops --------------------------------------------------------- */

static OSErr diagnostics_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    int i;

    g_owner = owner;
    g_body = *body;
    for (i = 0; i < kDiagProbeCount; ++i) {
        g_cards[i].state = diag_probe_served((DiagProbe)i) ? kDiagReady
                                                           : kDiagAbsent;
        g_cards[i].row_count = 0;
        g_cards[i].refusal[0] = '\0';
    }
    recompute();

    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    if (g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    text[0] = 0;
    g_scroll = NewControl(owner, &g_r.scrollbar, text, false, 0, 0, 0,
                          scrollBarProc, 0);
    if (g_scroll == NULL) {
        return memFullErr;
    }
    for (i = 0; i < kDiagProbeCount; ++i) {
        const char *title = diag_button_title((DiagProbe)i,
                                              g_cards[i].state);
        Rect where;

        if (title == NULL) {
            continue;                 /* absent: no control at all */
        }
        to_window(&g_r.cards[i].button, &where);
        CopyCStringToPascal(title, text);
        g_buttons[i] = NewControl(owner, &where, text, false, 0, 0, 1,
                                  pushButProc, 0);
        if (g_buttons[i] == NULL) {
            return memFullErr;
        }
    }
    return noErr;
}

static void diagnostics_dispose(void)
{
    int i;

    /* Controls die with the window; only the UPP is ours to release. */
    if (g_scroll_action_upp != NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
    }
    g_owner = NULL;
    g_scroll = NULL;
    for (i = 0; i < kDiagProbeCount; ++i) {
        g_buttons[i] = NULL;
    }
}

static void diagnostics_show(Boolean visible)
{
    g_visible = visible;
    if (g_scroll != NULL) {
        if (visible) {
            ShowControl(g_scroll);
        } else {
            HideControl(g_scroll);
        }
    }
    place_buttons();                  /* hides them all when not visible */
    if (visible) {
        sync_scrollbar();
    }
}

static void diagnostics_layout(const Rect *body)
{
    g_body = *body;
    recompute();
    if (g_scroll != NULL) {
        MoveControl(g_scroll, g_r.scrollbar.left, g_r.scrollbar.top);
        SizeControl(g_scroll,
                    (SInt16)(g_r.scrollbar.right - g_r.scrollbar.left),
                    (SInt16)(g_r.scrollbar.bottom - g_r.scrollbar.top));
    }
    sync_scrollbar();
    place_buttons();
}

static void diagnostics_draw(void)
{
    draw_canvas();
}

static Boolean diagnostics_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    ControlPartCode part;
    int i;

    (void)event;
    if (g_owner == NULL || !g_visible) {
        return false;
    }
    part = FindControl(local, g_owner, &control);
    if (control == g_scroll) {
        if (part == kControlIndicatorPart) {
            /* The thumb tracks as an outline and reports at release. */
            if (TrackControl(g_scroll, local, NULL) != 0) {
                scroll_to(GetControlValue(g_scroll), false);
            }
        } else {
            TrackControl(g_scroll, local, g_scroll_action_upp);
        }
        return true;
    }
    for (i = 0; i < kDiagProbeCount; ++i) {
        if (control == NULL || control != g_buttons[i]) {
            continue;
        }
        if (TrackControl(control, local, now_pump_action()) != 0) {
            if (i == kDiagVProbe) {
                run_vprobe();
            } else if (i == kDiagPutStat) {
                read_putstat();
            }
            update_button_title(i);
        }
        return true;
    }
    /* A canvas click is the page's own - there is nothing to select, but
       it must not fall through to the sidebar. */
    return PtInRect(local, &g_r.canvas);
}

static Boolean diagnostics_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    short page = (short)(canvas_height() - kDiagLineHeight);

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (page < kDiagLineHeight) {
        page = kDiagLineHeight;
    }
    switch (c) {
    case 0x0B:                        /* page up */
        scroll_to((short)(g_top - page), false);
        return true;
    case 0x0C:                        /* page down */
        scroll_to((short)(g_top + page), false);
        return true;
    case 0x01:                        /* home */
        scroll_to(0, false);
        return true;
    case 0x04:                        /* end */
        scroll_to(max_top(), false);
        return true;
    case 0x1E:                        /* up arrow */
        scroll_to((short)(g_top - kDiagLineHeight), false);
        return true;
    case 0x1F:                        /* down arrow */
        scroll_to((short)(g_top + kDiagLineHeight), false);
        return true;
    default:
        return false;
    }
}

static void diagnostics_activate(Boolean active)
{
    int i;

    if (g_scroll != NULL) {
        if (active) {
            ActivateControl(g_scroll);
        } else {
            DeactivateControl(g_scroll);
        }
    }
    for (i = 0; i < kDiagProbeCount; ++i) {
        if (g_buttons[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(g_buttons[i]);
        } else {
            DeactivateControl(g_buttons[i]);
        }
    }
    if (active) {
        sync_scrollbar();             /* re-derives the disabled state */
    }
}

static void diagnostics_status_text(char *out, long cap)
{
    DiagCardState states[kDiagProbeCount];
    short rows[kDiagProbeCount];

    gather_states(states, rows);
    diag_status_text(states, out, cap);
}

static const WorkshopModuleOps k_ops = {
    diagnostics_create,
    diagnostics_dispose,
    diagnostics_show,
    diagnostics_layout,
    diagnostics_draw,
    diagnostics_click,
    diagnostics_key,
    diagnostics_activate,
    /* No idle work: nothing here changes on its own. A probe answers when
       it is asked, and the counters putstat reads are re-read on the same
       press - so the page costs the event loop nothing between clicks. */
    NULL,
    diagnostics_status_text
};

const WorkshopModuleOps *diagnostics_module_ops(void)
{
    return &k_ops;
}
