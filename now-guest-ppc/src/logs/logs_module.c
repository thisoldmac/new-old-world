#include "logs_module.h"

#include <stdio.h>
#include <string.h>

#include "nowlog.h"
#include "prefs.h"
#include "pump.h"
#include "wire.h"
#include "control_kind.h"
#include "log_retention.h"

/* The Logs page is the Console page with the input line taken out: the
   same hand-drawn Monaco scrollback and scroll bar, reading nowlog.c's
   ring instead of a command model. The one control is a checkbox on the
   status placard that turns the now-logs file on and off; the in-memory
   ring is always live, so turning disk off loses nothing on screen. */

enum {
    kMargin = 10,
    kLineHeight = 12,
    kTextInset = 4,
    kScrollBarWidth = 16,
    kDiskWidth = 104,         /* room for the "Log to disk" checkbox */
    kInvertWidth = 66,        /* the "Invert" checkbox, left of it */
    kSwitchGap = 12,
    kRetainButtonWidth = 48,
    kRetainButtonGap = 4
};

typedef struct {
    Rect box;             /* framed canvas, without the scroll bar */
    Rect scroll_text;     /* where the log lines draw */
    Rect scrollbar;
    Rect disk_box;        /* checkbox on the status placard below the body */
    Rect invert_box;      /* the Invert checkbox, left of disk_box */
    Rect retain_less;
    Rect retain_more;
} LogsRects;

static WindowRef g_owner;
static Rect g_body;
static LogsRects g_r;
static Boolean g_visible;
static Boolean g_active = true;
static short g_font;

static ControlRef g_scroll;
static ControlRef g_disk;
static ControlRef g_invert;
static ControlRef g_retain_less;
static ControlRef g_retain_more;
static ControlActionUPP g_scroll_action_upp;

/* Black-on-white unless inverted, the Console page's switch kept its own. */
static Boolean g_inverted;

/* First visible line. Pinned to the newest unless the human scrolled
   away, so a live log follows the tail like a terminal. */
static short g_top;
static Boolean g_pinned = true;
/* Last line count drawn: idle repaints only when the ring actually grew,
   because idle runs every pass and unslept during a transfer. */
static short g_shown_count = -1;

static short visible_lines(void)
{
    short n = (short)((g_r.scroll_text.bottom - g_r.scroll_text.top)
                      / kLineHeight);

    return n < 1 ? 1 : n;
}

static short max_top(void)
{
    short count = (short)now_log_count();
    short vis = visible_lines();

    return count > vis ? (short)(count - vis) : 0;
}

static void compute_rects(const Rect *body, LogsRects *r)
{
    SetRect(&r->box, (short)(body->left + kMargin), (short)(body->top + 8),
            (short)(body->right - kMargin - kScrollBarWidth + 1),
            (short)(body->bottom - 8));
    SetRect(&r->scroll_text, (short)(r->box.left + kTextInset),
            (short)(r->box.top + kTextInset),
            (short)(r->box.right - kTextInset),
            (short)(r->box.bottom - kTextInset));
    SetRect(&r->scrollbar, (short)(r->box.right - 1), r->box.top,
            (short)(r->box.right - 1 + kScrollBarWidth), r->box.bottom);
    /* Both switches live on the status placard at the far right, clear of
       the grow box: "Log to disk" outermost, "Invert" to its left, the
       seat the Console's Invert switch takes. */
    SetRect(&r->disk_box, (short)(body->right - kDiskWidth - 22),
            (short)(body->bottom + 4), (short)(body->right - 22),
            (short)(body->bottom + 20));
    SetRect(&r->invert_box,
            (short)(r->disk_box.left - kSwitchGap - kInvertWidth),
            (short)(body->bottom + 4),
            (short)(r->disk_box.left - kSwitchGap),
            (short)(body->bottom + 20));
    SetRect(&r->retain_more,
            (short)(r->invert_box.left - kSwitchGap - kRetainButtonWidth),
            (short)(body->bottom + 3),
            (short)(r->invert_box.left - kSwitchGap),
            (short)(body->bottom + 21));
    SetRect(&r->retain_less,
            (short)(r->retain_more.left - kRetainButtonGap
                    - kRetainButtonWidth),
            (short)(body->bottom + 3),
            (short)(r->retain_more.left - kRetainButtonGap),
            (short)(body->bottom + 21));
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

/* The canvas ground and ink, flipped when inverted - the Console page's
   convention, so a dark log reads the same on both pages. */
static void set_canvas_colors(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };

    RGBBackColor(g_inverted ? &black : &white);
    RGBForeColor(g_inverted ? &white : &black);
}

/* The log lines actually on screen, walked once. A NULL writer draws
   them; a writer describes each in the rect it occupies. One walk means
   the host is never told about a line this page has scrolled past. */
static void emit_lines(const WorkshopSceneWriter *writer)
{
    Str255 text;
    short vis = visible_lines();
    short count = (short)now_log_count();
    short i;
    short y = (short)(g_r.scroll_text.top + kLineHeight - 2);

    for (i = g_top; i < count && i < g_top + vis; ++i) {
        if (writer != NULL) {
            Rect line;

            SetRect(&line, g_r.scroll_text.left,
                    (short)(y - kLineHeight + 2), g_r.scroll_text.right,
                    (short)(y + 2));
            workshop_scene_add(writer, kWorkshopSceneStaticText,
                               now_log_line(i), &line, true);
        } else {
            MoveTo(g_r.scroll_text.left, y);
            CopyCStringToPascal(now_log_line(i), text);
            DrawString(text);
        }
        y = (short)(y + kLineHeight);
    }
}

static void draw_canvas(void)
{
    RGBColor black = { 0, 0, 0 };
    RGBColor saved_back;
    short count = (short)now_log_count();
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
    EraseRect(&inner);
    TextFont(g_font);
    TextSize(9);
    emit_lines(NULL);
    RGBForeColor(&black);
    RGBBackColor(&saved_back);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    g_shown_count = count;
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

/* Persist the disk switch's ACTUAL state, not the intent: a disk open can
   fail, and a checkbox that claims a file it does not have would lie. */
static void persist_disk(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.log_to_disk = now_log_disk_on();
    (void)now_prefs_save(&prefs);
}

static void persist_invert(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.logs_invert = g_inverted;
    (void)now_prefs_save(&prefs);
}

static void sync_retention_controls(void)
{
    short keep = now_log_retention();
    if (g_retain_less != NULL) {
        HiliteControl(g_retain_less,
                      (g_active && keep > kNowLogRetentionMin) ? 0 : 255);
    }
    if (g_retain_more != NULL) {
        HiliteControl(g_retain_more,
                      (g_active && keep < kNowLogRetentionMax) ? 0 : 255);
    }
}

static void change_retention(short delta)
{
    NowPrefs prefs;
    short keep = (short)(now_log_retention() + delta);

    if (keep < kNowLogRetentionMin) keep = kNowLogRetentionMin;
    if (keep > kNowLogRetentionMax) keep = kNowLogRetentionMax;
    now_log_set_retention(keep);
    now_prefs_load(&prefs);
    prefs.log_retention = now_log_retention();
    (void)now_prefs_save(&prefs);
    sync_retention_controls();
}

/* --- module ops --------------------------------------------------------- */

static OSErr logs_create(WindowRef owner, const Rect *body)
{
    Str255 text;
    Str255 monaco;
    NowPrefs prefs;

    g_owner = owner;
    g_body = *body;
    compute_rects(body, &g_r);
    if (g_font == 0) {
        CopyCStringToPascal("Monaco", monaco);
        GetFNum(monaco, &g_font);
    }
    now_prefs_load(&prefs);
    g_inverted = prefs.logs_invert;
    now_log_set_retention(prefs.log_retention);

    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    if (g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    text[0] = 0;
    g_scroll = now_control_new(owner, &g_r.scrollbar, text, false, 0, 0, 0,
                          scrollBarProc, 0);
    CopyCStringToPascal("Log to disk", text);
    g_disk = now_control_new(owner, &g_r.disk_box, text, false,
                        now_log_disk_on() ? 1 : 0, 0, 1, checkBoxProc, 0);
    CopyCStringToPascal("Invert", text);
    g_invert = now_control_new(owner, &g_r.invert_box, text, false,
                          g_inverted ? 1 : 0, 0, 1, checkBoxProc, 0);
    CopyCStringToPascal("Fewer", text);
    g_retain_less = now_control_new(owner, &g_r.retain_less, text, false,
                                    0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("More", text);
    g_retain_more = now_control_new(owner, &g_r.retain_more, text, false,
                                    0, 0, 1, pushButProc, 0);
    if (g_scroll == NULL || g_disk == NULL || g_invert == NULL
        || g_retain_less == NULL || g_retain_more == NULL) {
        return memFullErr;
    }
    g_top = max_top();
    g_pinned = true;
    g_shown_count = (short)now_log_count();
    return noErr;
}

static void logs_dispose(void)
{
    /* Controls die with the window; only the UPP is ours to release. */
    if (g_scroll_action_upp != NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
    }
    g_owner = NULL;
    g_scroll = NULL;
    g_disk = NULL;
    g_invert = NULL;
    g_retain_less = NULL;
    g_retain_more = NULL;
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

static void logs_show(Boolean visible)
{
    g_visible = visible;
    show_control(g_scroll, visible);
    show_control(g_disk, visible);
    show_control(g_invert, visible);
    show_control(g_retain_less, visible);
    show_control(g_retain_more, visible);
    if (visible) {
        /* Catch up on anything logged while the page was hidden. */
        if (g_pinned) {
            g_top = max_top();
        }
        g_shown_count = (short)now_log_count();
        SetControlValue(g_disk, now_log_disk_on() ? 1 : 0);
        SetControlValue(g_invert, g_inverted ? 1 : 0);
        sync_scrollbar();
        sync_retention_controls();
    }
}

static void logs_layout(const Rect *body)
{
    g_body = *body;
    compute_rects(body, &g_r);
    if (g_scroll != NULL) {
        MoveControl(g_scroll, g_r.scrollbar.left, g_r.scrollbar.top);
        SizeControl(g_scroll,
                    (SInt16)(g_r.scrollbar.right - g_r.scrollbar.left),
                    (SInt16)(g_r.scrollbar.bottom - g_r.scrollbar.top));
    }
    if (g_disk != NULL) {
        MoveControl(g_disk, g_r.disk_box.left, g_r.disk_box.top);
    }
    if (g_invert != NULL) {
        MoveControl(g_invert, g_r.invert_box.left, g_r.invert_box.top);
    }
    if (g_retain_less != NULL) {
        MoveControl(g_retain_less, g_r.retain_less.left, g_r.retain_less.top);
    }
    if (g_retain_more != NULL) {
        MoveControl(g_retain_more, g_r.retain_more.left, g_r.retain_more.top);
    }
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void logs_draw(void)
{
    draw_canvas();
}

static Boolean logs_click(const EventRecord *event, Point local)
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
    if (control == g_disk) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            now_log_set_disk(!now_log_disk_on());
            persist_disk();
            /* Honest, not optimistic: a failed open leaves disk off, and
               the box must show that. The status placard, which names the
               file, repaints itself when workshop_idle notices the line
               changed. */
            SetControlValue(g_disk, now_log_disk_on() ? 1 : 0);
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
    if (control == g_retain_less || control == g_retain_more) {
        if (TrackControl(control, local, now_pump_action()) != 0) {
            change_retention(control == g_retain_less ? -1 : 1);
        }
        return true;
    }
    /* A canvas click is the page's own - there is nothing to select, but
       it must not fall through to the sidebar. */
    return PtInRect(local, &g_r.box);
}

static Boolean logs_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    short page = (short)(visible_lines() - 1);

    if (g_owner == NULL || !g_visible) {
        return false;
    }
    if (page < 1) {
        page = 1;
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
        scroll_to((short)(g_top - 1), false);
        return true;
    case 0x1F:                        /* down arrow */
        scroll_to((short)(g_top + 1), false);
        return true;
    default:
        return false;
    }
}

static void logs_activate(Boolean active)
{
    g_active = active;
    if (g_scroll != NULL) {
        if (active) {
            ActivateControl(g_scroll);
        } else {
            DeactivateControl(g_scroll);
        }
    }
    if (g_disk != NULL) {
        if (active) {
            ActivateControl(g_disk);
        } else {
            DeactivateControl(g_disk);
        }
    }
    if (g_invert != NULL) {
        if (active) {
            ActivateControl(g_invert);
        } else {
            DeactivateControl(g_invert);
        }
    }
    sync_retention_controls();
    if (active) {
        sync_scrollbar();             /* re-derives the disabled state */
    }
}

static void logs_idle(void)
{
    short count;

    if (g_owner == NULL || !g_visible) {
        return;
    }
    count = (short)now_log_count();
    if (count == g_shown_count) {
        return;                       /* nothing new: idle stays free */
    }
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
    InvalWindowRect(g_owner, &g_r.box);
    /* g_shown_count updates when draw_canvas runs, so a deferred update
       that has not painted yet still counts as pending. */
}

static void logs_status_text(char *out, long cap)
{
    if (now_log_disk_on()) {
        snprintf(out, (size_t)cap, "Keep %d logs. Saving to %.72s",
                 now_log_retention(), now_log_path());
    } else {
        snprintf(out, (size_t)cap,
                 "Keep %d logs when disk logging is on; currently memory only.",
                 now_log_retention());
    }
}

static void logs_describe_scene(const WorkshopSceneWriter *writer)
{
    /* The framed well is hand-drawn; the scroll bar beside it is already
       a Control Manager fact and is not repeated here. */
    workshop_scene_add(writer, kWorkshopScenePanel, "Log", &g_r.box, true);
    emit_lines(writer);
}

static const WorkshopModuleOps k_ops = {
    logs_create,
    logs_dispose,
    logs_show,
    logs_layout,
    logs_draw,
    logs_click,
    logs_key,
    logs_activate,
    logs_idle,
    logs_status_text,
    logs_describe_scene
};

const WorkshopModuleOps *logs_module_ops(void)
{
    return &k_ops;
}
