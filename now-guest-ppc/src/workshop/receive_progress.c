#include "receive_progress.h"

#include <string.h>
#include <stdio.h>

#include "control_kind.h"
#include "nowlog.h"
#include "pump.h"
#include "screen_bounds.h"
#include "wire.h"

enum {
    kWidth = 296,
    kHeight = 96,
    kMargin = 12,
    kButtonWidth = 76,
    kButtonHeight = 20,
    kBarHeight = 14,
    /* How long the outcome stays readable after the receive ends. A
       window that vanishes the instant the last byte lands tells a
       person nothing about a transfer that FAILED, which is the case
       this whole windoid is worth having for. Six seconds is long
       enough to read one line and short enough not to become litter;
       the close box is there for anyone impatient. */
    kOutcomeDwellTicks = 6 * 60,
    kBarMax = 1000
};

static WindowRef g_window;
static ControlRef g_bar;
static ControlRef g_cancel;

/* What is currently ON SCREEN, so idle can repaint only when a shown
   value actually changed - guest-ui-start-here.md's idle rule, and the
   reason this window does not flicker during a transfer that runs the
   event loop with no sleep. */
static char g_shown_line[120];
static short g_shown_bar = -1;
static Boolean g_bar_visible;

/* The receive this windoid is about. `outcome_seq` is the sequence
   number the wire bumps exactly when a receive ends; it is sampled when
   the window opens so an outcome from a transfer that ended BEFORE this
   window existed cannot be mistaken for this one's. */
static Boolean g_open;
static long g_outcome_seq;
static unsigned long g_dwell_until;    /* 0 while the receive is live */
static char g_name[64];

static void text_rect(Rect *out)
{
    SetRect(out, kMargin, kMargin, kWidth - kMargin, kMargin + 32);
}

static void bar_rect(Rect *out)
{
    SetRect(out, kMargin, kMargin + 38, kWidth - kMargin,
            kMargin + 38 + kBarHeight);
}

static void cancel_rect(Rect *out)
{
    SetRect(out, kWidth - kMargin - kButtonWidth,
            kHeight - kMargin - kButtonHeight, kWidth - kMargin,
            kHeight - kMargin);
}

/* Two lines inside one rect: the file's name, then where it has got to.
   TETextBox wraps in the port's current font, so a name longer than the
   window still reads rather than running off the edge - confirm.c's
   lesson, applied before it could be paid for a second time. */
static void draw_wrapped(const char *s, const Rect *box)
{
    Str255 text;
    Rect r = *box;

    if (s == NULL || s[0] == '\0') {
        return;
    }
    CopyCStringToPascal(s, text);
    TETextBox(text + 1, (SInt32)text[0], &r, teJustLeft);
}

static void show_bar(Boolean visible)
{
    if (g_bar == NULL || visible == g_bar_visible) {
        return;
    }
    g_bar_visible = visible;
    if (visible) {
        ShowControl(g_bar);
    } else {
        HideControl(g_bar);
    }
}

static void close_windoid(void)
{
    if (g_window == NULL) {
        return;
    }
    now_control_dispose_window(g_window);
    g_window = NULL;
    g_bar = NULL;
    g_cancel = NULL;
    g_open = false;
    g_bar_visible = false;
    g_shown_bar = -1;
    g_shown_line[0] = '\0';
    g_dwell_until = 0;
}

/* Bottom-right of the desktop, out of the way of a window someone is
   reading. Clamped to the desktop rather than placed at a plausible
   constant: now_screen_desktop answers an EMPTY rect when the machine
   will not say how big its screen is, and a windoid placed off-screen
   is indistinguishable from one that never opened. */
static void place(Rect *bounds)
{
    Rect desk;

    now_screen_desktop(&desk);
    if (EmptyRect(&desk)) {
        SetRect(bounds, 60, 60, 60 + kWidth, 60 + kHeight);
        return;
    }
    SetRect(bounds, (short)(desk.right - kWidth - 12),
            (short)(desk.bottom - kHeight - 12),
            (short)(desk.right - 12), (short)(desk.bottom - 12));
    if (bounds->left < desk.left) {
        OffsetRect(bounds, (short)(desk.left - bounds->left), 0);
    }
    if (bounds->top < desk.top) {
        OffsetRect(bounds, 0, (short)(desk.top - bounds->top));
    }
}

static Boolean open_windoid(void)
{
    Rect bounds;
    Str255 text;

    place(&bounds);
    /* kFloatingWindowClass, and NOT kWindowStandardHandlerAttribute -
       that attribute installs HIToolbox's Carbon Event handler, which
       expects RunApplicationEventLoop and in this WaitNextEvent app
       eats the window's events (guest-ui-start-here.md).

       kWindowNoActivatesAttribute is the half that keeps the one-window
       app coherent: a floating window that took activation would leave
       the Workshop drawn as inactive for the length of a transfer, and
       main.c's key routing asks FrontNonFloatingWindow so this window
       never becomes the one the keyboard is talking to. */
    CreateNewWindow(kFloatingWindowClass,
                    kWindowCloseBoxAttribute | kWindowNoActivatesAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        /* A transfer with no window is the state this project was
           already in; it is not worth failing the transfer over. */
        now_log(kLogWarn, "put", "no window for the receive progress");
        return false;
    }
    CopyCStringToPascal("Receiving", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window,
                             kThemeBrushUtilityWindowBackgroundActive, true);

    bar_rect(&bounds);
    text[0] = 0;
    g_bar = now_control_new(g_window, &bounds, text, false, 0, 0, kBarMax,
                            kControlProgressBarProc, 0);
    cancel_rect(&bounds);
    CopyCStringToPascal("Stop", text);
    g_cancel = now_control_new(g_window, &bounds, text, true, 0, 0, 1,
                               pushButProc, 0);
    if (g_bar == NULL || g_cancel == NULL) {
        close_windoid();
        return false;
    }
    g_bar_visible = false;
    g_shown_bar = -1;
    g_shown_line[0] = '\0';
    g_dwell_until = 0;
    g_open = true;
    ShowWindow(g_window);
    return true;
}

/* The one place the window's text is decided, so what idle compares
   against is exactly what draw() would put on the glass. */
static void compose_line(char *out, long cap, long received, long expected)
{
    if (expected > 0) {
        long pct = expected > 0 ? (100L * received / expected) : 0;

        snprintf(out, (size_t)cap, "%.31s\r%ld of %ld K (%ld%%)", g_name,
                 (received + 512) / 1024, (expected + 512) / 1024, pct);
    } else {
        /* The host offered no size. Reporting a percentage of an unknown
           total would be an invention; the byte count is the fact. */
        snprintf(out, (size_t)cap, "%.31s\r%ld K so far", g_name,
                 (received + 512) / 1024);
    }
}

void now_receive_progress_draw(void)
{
    Rect bounds;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    DrawControls(g_window);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    text_rect(&bounds);
    draw_wrapped(g_shown_line, &bounds);
}

Boolean now_receive_progress_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

Boolean now_receive_progress_click(const EventRecord *event, short part)
{
    Point local;
    ControlRef control = NULL;
    Rect drag;

    if (g_window == NULL) {
        return false;
    }
    if (part == inDrag) {
        now_screen_desktop(&drag);
        if (EmptyRect(&drag)) {
            GetRegionBounds(GetGrayRgn(), &drag);
        }
        DragWindow(g_window, event->where, &drag);
        return true;
    }
    if (part == inGoAway) {
        /* Dismissing the WINDOW is not cancelling the TRANSFER. A close
           box that silently stopped a file arriving would be the worst
           kind of destructive default: the Stop button says what it
           does, this one only stops watching. */
        if (TrackGoAway(g_window, event->where)) {
            close_windoid();
        }
        return true;
    }
    if (part != inContent) {
        return false;
    }
    local = event->where;
    SetPortWindowPort(g_window);
    GlobalToLocal(&local);
    if (FindControl(local, g_window, &control) == 0 || control == NULL) {
        return true;                  /* ours, and nothing was hit */
    }
    /* Tracking is a nested loop: with a NULL action proc the wire stops
       for as long as the finger rests on the button, and this button
       exists precisely for a transfer that is still running. */
    if (control != g_cancel
        || TrackControl(control, local, now_pump_action()) == 0) {
        return true;
    }
    {
        char why[128];

        if (now_wire_put_cancel(why, sizeof why) != 0) {
            /* It ended between the press and the release. Say so in the
               window rather than beeping at a person who did nothing
               wrong. */
            Rect r;

            snprintf(g_shown_line, sizeof g_shown_line, "%.110s", why);
            g_dwell_until = TickCount() + kOutcomeDwellTicks;
            show_bar(false);
            text_rect(&r);
            InvalWindowRect(g_window, &r);
        }
    }
    return true;
}

/* Every event-loop pass. Three in-memory reads and a comparison; the
   window is touched only when a shown value differs. */
void now_receive_progress_idle(void)
{
    long received = 0, expected = 0;
    Boolean cloud_get = false;
    char name[64];
    char line[120];
    Boolean active;

    active = now_wire_receive_active(&received, &expected, &cloud_get,
                                     name, (long)sizeof name);
    if (active && cloud_get) {
        /* The Cloud page already draws its own downloads, correlated to
           the cloud.get that asked for them. Drawing them here as well
           would be two windows reporting one transfer. */
        active = false;
    }
    if (!g_open) {
        if (!active) {
            return;
        }
        /* Sampled BEFORE the window exists, so an outcome left over from
           an earlier transfer cannot be shown as this one's. */
        g_outcome_seq = now_wire_receive_outcome(NULL, 0);
        snprintf(g_name, sizeof g_name, "%.31s", name);
        if (!open_windoid()) {
            return;
        }
    }
    if (active && g_dwell_until == 0) {
        short value;

        snprintf(g_name, sizeof g_name, "%.31s", name);
        compose_line(line, (long)sizeof line, received, expected);
        if (strcmp(line, g_shown_line) != 0) {
            Rect r;

            snprintf(g_shown_line, sizeof g_shown_line, "%s", line);
            text_rect(&r);
            InvalWindowRect(g_window, &r);
        }
        /* An empty bar sitting at zero while the size is unknown reads
           as stuck; the line already says how much has landed. */
        show_bar(expected > 0);
        if (expected > 0) {
            value = (short)((long)kBarMax * received / expected);
            if (value != g_shown_bar) {
                g_shown_bar = value;
                SetControlValue(g_bar, value);
            }
        }
        return;
    }
    if (g_dwell_until == 0) {
        /* The receive ended. Show how it went - including, and
           especially, when it failed - before the window leaves. */
        char outcome[128];
        long seq = now_wire_receive_outcome(outcome, (long)sizeof outcome);
        Rect r;

        if (seq != g_outcome_seq && outcome[0] != '\0') {
            snprintf(g_shown_line, sizeof g_shown_line, "%.110s", outcome);
        } else {
            snprintf(g_shown_line, sizeof g_shown_line,
                     "%.31s: the transfer ended", g_name);
        }
        show_bar(false);
        if (g_cancel != NULL) {
            HiliteControl(g_cancel, 255);
        }
        text_rect(&r);
        InvalWindowRect(g_window, &r);
        g_dwell_until = TickCount() + kOutcomeDwellTicks;
        return;
    }
    if (active) {
        /* A second push started while the outcome was still on screen.
           Reopening is cheaper to reason about than reusing the window
           mid-dwell, and the outcome has been readable for at least one
           pass either way. */
        close_windoid();
        return;
    }
    if (TickCount() >= g_dwell_until) {
        close_windoid();
    }
}

void now_receive_progress_shutdown(void)
{
    close_windoid();
}
