#include "console_module.h"

#include <stdio.h>
#include <string.h>

#include "console_model.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"

/* The page owns controls and pixels only; every remembered thing -
   scrollback, history, the command table - lives in console_model.c, so
   switching modules or closing the Workshop loses nothing. */

enum {
    kMargin = 10,
    kLineHeight = 12,
    kTextInset = 4,
    kScrollBarWidth = 16,
    kInputRowHeight = 26,
    kRunWidth = 52,
    kInvertWidth = 66
};

typedef struct {
    Rect box;             /* framed scrollback, without the scroll bar */
    Rect text;            /* where lines draw, inset from the box */
    Rect scrollbar;
    Rect field;
    Rect run_btn;
    Rect invert_box;      /* lives on the status placard below the body */
} ConsoleRects;

static WindowRef g_owner;
static Rect g_body;
static ConsoleRects g_r;
static Boolean g_visible;
static short g_font;

static ControlRef g_scroll;
static ControlRef g_field;
static ControlRef g_run;
static ControlRef g_invert;
static ControlActionUPP g_scroll_action_upp;

static Boolean g_inverted;
/* First visible scrollback line. Pinned to the newest output unless the
   human scrolled away; survives module switches with the rest. */
static short g_top;
static Boolean g_pinned = true;

static short visible_lines(void)
{
    short n = (short)((g_r.text.bottom - g_r.text.top) / kLineHeight);

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
    short input_top = (short)(body->bottom - kInputRowHeight);

    SetRect(&r->box, (short)(body->left + kMargin), (short)(body->top + 8),
            (short)(body->right - kMargin - kScrollBarWidth + 1),
            (short)(input_top - 6));
    SetRect(&r->text, (short)(r->box.left + kTextInset),
            (short)(r->box.top + kTextInset),
            (short)(r->box.right - kTextInset),
            (short)(r->box.bottom - kTextInset));
    SetRect(&r->scrollbar, (short)(r->box.right - 1), r->box.top,
            (short)(r->box.right - 1 + kScrollBarWidth), r->box.bottom);
    SetRect(&r->field, (short)(body->left + kMargin + 14),
            (short)(input_top + 4),
            (short)(body->right - kMargin - kRunWidth - 12),
            (short)(input_top + 20));
    SetRect(&r->run_btn, (short)(body->right - kMargin - kRunWidth),
            (short)(input_top + 2), (short)(body->right - kMargin),
            (short)(input_top + 22));
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

static void draw_scrollback(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    Str255 text;
    short vis = visible_lines();
    short count = (short)console_model_count();
    short i;
    short y;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    SetPortWindowPort(g_owner);
    GetBackColor(&saved_back);
    RGBForeColor(&black);
    FrameRect(&g_r.box);
    RGBBackColor(g_inverted ? &black : &white);
    RGBForeColor(g_inverted ? &white : &black);
    {
        Rect inner = g_r.box;

        InsetRect(&inner, 1, 1);
        EraseRect(&inner);
    }
    TextFont(g_font);
    TextSize(9);
    y = (short)(g_r.text.top + kLineHeight - 2);
    for (i = g_top; i < count && i < g_top + vis; ++i) {
        MoveTo(g_r.text.left, y);
        CopyCStringToPascal(console_model_line(i), text);
        DrawString(text);
        y = (short)(y + kLineHeight);
    }
    RGBForeColor(&black);
    RGBBackColor(&saved_back);
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
    g_pinned = (g_top >= max);
    SetControlValue(g_scroll, g_top);
    if (live) {
        draw_scrollback();            /* mid-track: paint now, not later */
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

static void set_field_text(const char *text)
{
    if (g_field == NULL) {
        return;
    }
    SetControlData(g_field, kControlEditTextPart, kControlEditTextTextTag,
                   (Size)strlen(text), text);
    if (g_owner != NULL) {
        Rect r = g_r.field;

        InsetRect(&r, -3, -3);
        InvalWindowRect(g_owner, &r);
    }
}

static void run_submit(void)
{
    char text[kConsoleMaxCols];
    Size actual = 0;
    long start = 0;
    long end;

    text[0] = '\0';
    if (GetControlData(g_field, kControlEditTextPart,
                       kControlEditTextTextTag, sizeof text - 1, text,
                       &actual) == noErr) {
        if (actual > (Size)(sizeof text - 1)) {
            actual = sizeof text - 1;
        }
        text[actual] = '\0';
    }
    while (text[start] == ' ') {
        ++start;
    }
    end = (long)strlen(text);
    while (end > start && text[end - 1] == ' ') {
        --end;
    }
    text[end] = '\0';
    console_model_history_add(text + start);
    console_model_run(text + start);
    set_field_text("");
    g_pinned = true;
    g_top = max_top();
    sync_scrollbar();
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, &g_r.box);
    }
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

    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    if (g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    text[0] = 0;
    g_scroll = NewControl(owner, &g_r.scrollbar, text, false, 0, 0, 0,
                          scrollBarProc, 0);
    g_field = NewControl(owner, &g_r.field, text, false, 0, 0, 0,
                         kControlEditTextProc, 0);
    CopyCStringToPascal("Run", text);
    g_run = NewControl(owner, &g_r.run_btn, text, false, 0, 0, 1,
                       pushButProc, 0);
    CopyCStringToPascal("Invert", text);
    g_invert = NewControl(owner, &g_r.invert_box, text, false,
                          g_inverted ? 1 : 0, 0, 1, checkBoxProc, 0);
    if (g_scroll == NULL || g_field == NULL || g_run == NULL
        || g_invert == NULL) {
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
    g_field = NULL;
    g_run = NULL;
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
    show_control(g_field, visible);
    show_control(g_run, visible);
    show_control(g_invert, visible);
    if (g_owner == NULL) {
        return;
    }
    if (visible) {
        sync_scrollbar();
        SetKeyboardFocus(g_owner, g_field, kControlFocusNextPart);
    } else {
        ClearKeyboardFocus(g_owner);
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

static void console_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    move_control(g_scroll, &g_r.scrollbar);
    move_control(g_field, &g_r.field);
    move_control(g_run, &g_r.run_btn);
    move_control(g_invert, &g_r.invert_box);
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void console_draw(void)
{
    Str255 text;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    draw_scrollback();
    TextFont(g_font);
    TextSize(9);
    MoveTo((short)(g_body.left + kMargin),
           (short)(g_r.field.bottom - 3));
    CopyCStringToPascal(">", text);
    DrawString(text);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
}

static Boolean console_click(const EventRecord *event, Point local)
{
    ControlRef control = NULL;
    ControlPartCode part;

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
    if (control == g_field) {
        SetKeyboardFocus(g_owner, g_field, kControlFocusNextPart);
        HandleControlClick(control, local, event->modifiers, NULL);
        return true;
    }
    if (control == g_run) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            run_submit();
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
    return false;
}

static Boolean console_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    ControlRef focus = NULL;
    short page = (short)(visible_lines() - 1);

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (page < 1) {
        page = 1;
    }
    /* The scrollback answers these wherever the focus is. */
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
    if (GetKeyboardFocus(g_owner, &focus) != noErr || focus != g_field) {
        return false;
    }
    if (c == '\r' || c == 3) {
        run_submit();
        return true;
    }
    if (c == 0x1E || c == 0x1F) {     /* up/down: command history */
        set_field_text(console_model_history_recall(c == 0x1E ? -1 : 1));
        return true;
    }
    if (c == '\t') {
        return false;                 /* the Workshop moves the focus */
    }
    HandleControlKey(g_field, (SInt16)((event->message & keyCodeMask) >> 8),
                     c, event->modifiers);
    return true;
}

static void console_activate(Boolean active)
{
    ControlRef controls[4];
    int i;

    controls[0] = g_scroll;
    controls[1] = g_field;
    controls[2] = g_run;
    controls[3] = g_invert;
    for (i = 0; i < 4; ++i) {
        if (controls[i] == NULL) {
            continue;
        }
        if (active) {
            ActivateControl(controls[i]);
        } else {
            DeactivateControl(controls[i]);
        }
    }
    if (active) {
        sync_scrollbar();             /* re-derives the disabled state */
    }
}

static void console_idle(void)
{
    if (g_owner == NULL || !g_visible) {
        return;
    }
    IdleControls(g_owner);            /* the caret blink */
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
