#include "console_module.h"

#include <stdio.h>
#include <string.h>

#include "console_history.h"
#include "console_model.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"

/* The page owns pixels and the input line; every remembered thing -
   scrollback, history, the command table - lives in console_model.c, so
   switching modules or closing the Workshop loses nothing.

   The input is INSIDE the canvas, a "> " prompt on the bottom line of
   the same white (or inverted) area - the terminal shape the old
   console window had. On metal the first build's separate edit-text
   field never took a keystroke; this one has no focus to lose, because
   the page itself is the focus while it is selected. Arrows are
   history, like any terminal; the sidebar still switches by click and
   Cmd-1..4. */

enum {
    kMargin = 10,
    kLineHeight = 12,
    kTextInset = 4,
    kScrollBarWidth = 16,
    kInputStripHeight = 18,       /* rule + the prompt line */
    kInvertWidth = 66
};

typedef struct {
    Rect box;             /* framed canvas, without the scroll bar */
    Rect scroll_text;     /* where scrollback lines draw */
    Rect input_strip;     /* the prompt line at the canvas bottom */
    Rect scrollbar;
    Rect invert_box;      /* lives on the status placard below the body */
} ConsoleRects;

static WindowRef g_owner;
static Rect g_body;
static ConsoleRects g_r;
static Boolean g_visible;
static short g_font;

static ControlRef g_scroll;
static ControlRef g_invert;
static ControlActionUPP g_scroll_action_upp;

static Boolean g_inverted;
static Boolean g_active = true;   /* the caret hides in the background */
static char g_input[kConsoleMaxCols];
static short g_input_len;
/* The page owns the history because the page owns the input field - the
   same division NOW-68K's conwin.c makes, over the same file
   (now-guest-shared/src/console_history.c). ~2.3 KB of statics; see its
   header's budget. */
static ConsoleHistory g_history;
static Boolean g_history_ready = false;
/* First visible scrollback line. Pinned to the newest output unless the
   human scrolled away; survives module switches with the rest. */
static short g_top;
static Boolean g_pinned = true;

static short visible_lines(void)
{
    short n = (short)((g_r.scroll_text.bottom - g_r.scroll_text.top)
                      / kLineHeight);

    return n < 1 ? 1 : n;
}

static short max_top(void)
{
    short count = (short)console_model_count();
    short vis = visible_lines();

    return count > vis ? (short)(count - vis) : 0;
}

static void compute_rects(const Rect *body, ConsoleRects *r)
{
    SetRect(&r->box, (short)(body->left + kMargin), (short)(body->top + 8),
            (short)(body->right - kMargin - kScrollBarWidth + 1),
            (short)(body->bottom - 8));
    SetRect(&r->scroll_text, (short)(r->box.left + kTextInset),
            (short)(r->box.top + kTextInset),
            (short)(r->box.right - kTextInset),
            (short)(r->box.bottom - kInputStripHeight));
    SetRect(&r->input_strip, (short)(r->box.left + 1),
            (short)(r->box.bottom - kInputStripHeight),
            (short)(r->box.right - 1), (short)(r->box.bottom - 1));
    SetRect(&r->scrollbar, (short)(r->box.right - 1), r->box.top,
            (short)(r->box.right - 1 + kScrollBarWidth), r->box.bottom);
    /* The status placard sits directly under the body; the Invert switch
       lives at its far right, clear of the grow box. */
    SetRect(&r->invert_box, (short)(body->right - kInvertWidth - 22),
            (short)(body->bottom + 4), (short)(body->right - 22),
            (short)(body->bottom + 20));
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

static void set_canvas_colors(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    RGBBackColor(g_inverted ? &black : &white);
    RGBForeColor(g_inverted ? &white : &black);
}

static void restore_colors(RGBColor *saved_back)
{
    RGBColor black = { 0, 0, 0 };

    RGBForeColor(&black);
    RGBBackColor(saved_back);
}

/* Only the prompt line: a keystroke must not repaint the scrollback. */
static void draw_input_line(void)
{
    RGBColor saved_back;
    Str255 text;
    char prompt[kConsoleMaxCols + 4];

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    GetBackColor(&saved_back);
    set_canvas_colors();
    EraseRect(&g_r.input_strip);
    TextFont(g_font);
    TextSize(9);
    snprintf(prompt, sizeof prompt, "> %.120s%s", g_input,
             g_active ? "_" : "");
    MoveTo((short)(g_r.scroll_text.left),
           (short)(g_r.input_strip.bottom - 5));
    CopyCStringToPascal(prompt, text);
    DrawString(text);
    restore_colors(&saved_back);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

static void draw_canvas(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor saved_back;
    Str255 text;
    short vis = visible_lines();
    short count = (short)console_model_count();
    short i;
    short y;
    Rect inner;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    GetBackColor(&saved_back);
    RGBForeColor(&black);
    FrameRect(&g_r.box);
    set_canvas_colors();
    inner = g_r.box;
    InsetRect(&inner, 1, 1);
    inner.bottom = g_r.input_strip.top;
    EraseRect(&inner);
    TextFont(g_font);
    TextSize(9);
    y = (short)(g_r.scroll_text.top + kLineHeight - 2);
    for (i = g_top; i < count && i < g_top + vis; ++i) {
        MoveTo(g_r.scroll_text.left, y);
        CopyCStringToPascal(console_model_line(i), text);
        DrawString(text);
        y = (short)(y + kLineHeight);
    }
    restore_colors(&saved_back);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_input_line();
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
    g_pinned = (g_top >= max);
    SetControlValue(g_scroll, g_top);
    if (live) {
        draw_canvas();                /* mid-track: paint now, not later */
    } else if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_r.box);
    }
}

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    short delta = 0;
    short page = (short)(visible_lines() - 1);

    (void)control;
    if (page < 1) {
        page = 1;
    }
    switch (part) {
    case kControlUpButtonPart:
        delta = -1;
        break;
    case kControlDownButtonPart:
        delta = 1;
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

/* --- input -------------------------------------------------------------- */

static void run_submit(void)
{
    long start = 0;
    long end;

    while (g_input[start] == ' ') {
        ++start;
    }
    end = (long)strlen(g_input);
    while (end > start && g_input[end - 1] == ' ') {
        --end;
    }
    g_input[end] = '\0';
    console_history_push(&g_history, g_input + start);
    console_model_run(g_input + start);
    g_input[0] = '\0';
    g_input_len = 0;
    g_pinned = true;
    g_top = max_top();
    sync_scrollbar();
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_r.box);
    }
}

/* NULL means "there is nothing further that way" - leave the field exactly
   as the human left it. It never means "clear it", which is what this page
   used to do at both ends of a walk, because its own history returned ""
   there. See console_history.h. */
static void take_history(const char *recalled)
{
    if (recalled == NULL) {
        return;
    }
    strncpy(g_input, recalled, sizeof g_input - 1);
    g_input[sizeof g_input - 1] = '\0';
    g_input_len = (short)strlen(g_input);
    draw_input_line();
}

static void persist_invert(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.console_invert = g_inverted;
    if (now_prefs_save(&prefs) != noErr) {
        console_model_append("Could not save the console appearance.");
    }
}

/* --- module ops --------------------------------------------------------- */

static OSErr console_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    NowPrefs prefs;
    Str255 monaco;

    g_owner = owner;
    g_body = *body;
    compute_rects(body, &g_r);
    if (g_font == 0) {
        CopyCStringToPascal("Monaco", monaco);
        GetFNum(monaco, &g_font);
    }
    now_prefs_load(&prefs);
    g_inverted = prefs.console_invert;
    g_input[0] = '\0';
    g_input_len = 0;
    /* GUARDED, unlike the input line above it: create runs again every time
       the Workshop rebuilds this page, and what a human typed earlier in the
       run should outlive that the way the scrollback does. */
    if (!g_history_ready) {
        console_history_init(&g_history);
        g_history_ready = true;
    }

    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    if (g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    text[0] = 0;
    g_scroll = NewControl(owner, &g_r.scrollbar, text, false, 0, 0, 0,
                          scrollBarProc, 0);
    CopyCStringToPascal("Invert", text);
    g_invert = NewControl(owner, &g_r.invert_box, text, false,
                          g_inverted ? 1 : 0, 0, 1, checkBoxProc, 0);
    if (g_scroll == NULL || g_invert == NULL) {
        return memFullErr;
    }
    console_model_banner();
    g_top = max_top();
    g_pinned = true;
    return noErr;
}

static void console_dispose(void)
{
    /* Controls die with the window; only the UPP is ours to release. */
    if (g_scroll_action_upp != NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
    }
    g_owner = NULL;
    g_scroll = NULL;
    g_invert = NULL;
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

static void console_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_scroll, visible);
    show_control(g_invert, visible);
    if (visible) {
        sync_scrollbar();
    }
}

static void console_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    if (g_scroll != NULL) {
        MoveControl(g_scroll, g_r.scrollbar.left, g_r.scrollbar.top);
        SizeControl(g_scroll,
                    (SInt16)(g_r.scrollbar.right - g_r.scrollbar.left),
                    (SInt16)(g_r.scrollbar.bottom - g_r.scrollbar.top));
    }
    if (g_invert != NULL) {
        MoveControl(g_invert, g_r.invert_box.left, g_r.invert_box.top);
    }
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void console_draw(void)
{
    draw_canvas();
}

static Boolean console_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    ControlPartCode part;

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
                g_pinned = (g_top >= max_top());
            }
        } else {
            TrackControl(g_scroll, local, g_scroll_action_upp);
        }
        return true;
    }
    if (control == g_invert) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            g_inverted = !g_inverted;
            SetControlValue(g_invert, g_inverted ? 1 : 0);
            persist_invert();
            InvalWindowRect(g_owner, &g_r.box);
        }
        return true;
    }
    /* Clicks in the canvas are the page's own; there is nothing to
       place a cursor into, but they must not fall through to the
       sidebar either. */
    return PtInRect(local, &g_r.box);
}

static Boolean console_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    short page = (short)(visible_lines() - 1);

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (page < 1) {
        page = 1;
    }
    if (c == 0x0B) {                  /* page up */
        scroll_to((short)(g_top - page), false);
        return true;
    }
    if (c == 0x0C) {                  /* page down */
        scroll_to((short)(g_top + page), false);
        return true;
    }
    if (c == 0x01) {                  /* home */
        scroll_to(0, false);
        return true;
    }
    if (c == 0x04) {                  /* end */
        scroll_to(max_top(), false);
        return true;
    }
    if (c == '\r' || c == 3) {
        run_submit();
        return true;
    }
    if (c == 0x1E || c == 0x1F) {     /* up/down: command history */
        /* Up hands the shared history whatever is half-typed, so walking
           back down past the newest entry restores it instead of blanking
           it - the shell behaviour whose absence is noticed immediately. */
        take_history(c == 0x1E ? console_history_prev(&g_history, g_input)
                               : console_history_next(&g_history));
        return true;
    }
    if (c == '\b' || c == 0x7F) {
        if (g_input_len > 0) {
            g_input[--g_input_len] = '\0';
            draw_input_line();
        }
        return true;
    }
    if (c >= 0x20 && c < 0x7F) {
        if (g_input_len < (short)(sizeof g_input - 2)) {
            g_input[g_input_len++] = c;
            g_input[g_input_len] = '\0';
            draw_input_line();
        }
        return true;
    }
    return false;
}

static void console_activate(Boolean active)
{
    if (g_scroll != NULL) {
        if (active) {
            ActivateControl(g_scroll);
        } else {
            DeactivateControl(g_scroll);
        }
    }
    if (g_invert != NULL) {
        if (active) {
            ActivateControl(g_invert);
        } else {
            DeactivateControl(g_invert);
        }
    }
    if (active != g_active) {
        g_active = active;
        /* Only the caret changes; only the prompt line repaints. */
        draw_input_line();
    }
    if (active) {
        sync_scrollbar();             /* re-derives the disabled state */
    }
}

static void console_idle(void)
{
    /* Nothing to poll: output arrives through commands the page itself
       runs, and the caret is a plain underscore, not a blinker. */
}

static void console_status_text(char *out, long cap)
{
    snprintf(out, (size_t)cap,
             "Commands run on this Mac only - type help for the list.");
}

static const WorkshopModuleOps k_ops = {
    console_create,
    console_dispose,
    console_show,
    console_layout,
    console_draw,
    console_click,
    console_key,
    console_activate,
    console_idle,
    console_status_text
};

const WorkshopModuleOps *console_module_ops(void)
{
    return &k_ops;
}
