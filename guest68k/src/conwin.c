/*
 * conwin.c - the interactive console window (see conwin.h, which carries
 * the reason this guest has a second window at all).
 *
 * STATIC MEMORY BUDGET (no malloc/NewPtr/NewHandle anywhere in this file;
 * the Toolbox objects below are the Toolbox's own allocations, not ours):
 *   gOut (N68ConsoleRing)   8192 + 128 + ~16     = ~8.2 KB (its own
 *                                                   documented budget,
 *                                                   n68_console_ring.h)
 *   gHistory (N68History)   2048 + 256 + ~12     = ~2.3 KB (n68_history.h)
 *   misc scalars (window/TE handles, rects,
 *   scrollback offset, prompt width)             = ~ 120  bytes
 *   ---------------------------------------------------------------------
 *   file-static total                            = 10,954 bytes MEASURED
 *
 * Measured, not estimated - the arithmetic above is what it should be and
 * the number is what it is:
 *
 *   m68k-apple-macos-size <builddir>/CMakeFiles/now68k-guest.dir/src/\
 *     conwin.c.obj        ->  text 3534  data 0  bss 10954
 *
 * Whole-application cost of this window and the seam it needed, against
 * 4a7703f built the same way: text +4,428 and bss +10,954, so +15,382
 * bytes = +4.0% of the 384 KB partition. Re-measure rather than trust this
 * paragraph if you change either buffer.
 *
 * It is paid whether or not the window is ever opened, because BSS is BSS.
 * It buys the two things this window cannot fake: a scrollback the human
 * can page back through, and a history the arrow keys can walk. window.c's
 * own globals are 9,186 bytes by the same measurement, so the pair costs
 * ~20 KB - the CODE resource and the MacTCP buffers (17,696 bytes in
 * net_mactcp.c) remain the large items.
 *
 * Deepest transient stack, inside submit_line():
 *   line[kInputCap 256] + name[32] + echo[260]    = ~ 550 bytes here,
 * plus whatever now68k_exec_line adds below it - the N68CmdResult and the
 * render buffers moved there with the dispatch (n68_exec.c), so the deepest
 * frame on this path is now that file's business and is budgeted in its
 * own header. The pair still lands where the ~930 bytes measured before the
 * move did; nothing grew, it changed owner.
 * draw_all() is never on the stack under submit_line() - submit_line
 * invalidates and returns, it does not draw. No recursion, no VLA.
 *
 * REDRAW OWNERSHIP: exactly one painter, draw_all(), and it runs only
 * inside the updateEvt BeginUpdate/EndUpdate bracket. Every other function
 * here mutates state and calls InvalRect. The two exceptions are TextEdit's
 * own (TEKey/TEClick/TEIdle/TEActivate draw the field and its insertion
 * point immediately, which is TextEdit's contract, not this file's
 * drawing) - the same exception window.c already documents.
 */
#include "conwin.h"

/* commands68.h, numfmt.h, n68_proclist.h and proc68.h left with the
 * dispatch: this window no longer knows what a command IS, only how to
 * show text and take a key. n68_cmdresult.h stays for kN68CmdCodeCap,
 * which bounds the verb buffer `clear` is compared against. */
#include "log.h"
#include "n68_cmdresult.h"
#include "n68_console_ring.h"
#include "n68_exec.h"
#include "n68_history.h"
#include "wire68.h"

#include <Quickdraw.h>
#include <Fonts.h>
#include <TextEdit.h>
#include <TextUtils.h>
#include <Memory.h>

#include <stddef.h>
#include <string.h>

/* Same reason as window.c's: a "\p" literal is a char*, every Toolbox
 * string argument is a ConstStr255Param, and the two differ in signedness.
 * With the -Werror gate every call site needs the cast, so it lives here
 * once. */
#define PSTR(s) ((ConstStr255Param)(s))

/* Offset from the main window (40,60 at 512x300) so both are reachable
 * without dragging either: this one sits below and right of it and still
 * fits the 180c's 640x480 panel (60+268 = 328 bottom, 60+460 = 520 right). */
#define kCWinLeft    60
#define kCWinTop     92
#define kCWinWidth   460
#define kCWinHeight  268

#define kCMargin       6
#define kCRight      454        /* kCWinWidth - kCMargin */

#define kCOutTop       6
#define kCOutBot     216
#define kCInTop      222
#define kCInBot      244
#define kCHintTop    248
#define kCHintBot    262

/* Must equal kN68HistoryLineCap - see n68_history.h's WHY 256 WIDE. A line
 * the field can hold but the history cannot store would come back from an
 * Up arrow silently shortened. */
enum { kInputCap = kN68HistoryLineCap };

/* The two render caps that used to live here (kRenderCap, kRowsRenderCap)
 * moved to n68_exec.c with the code that renders into them. This file no
 * longer holds a rendered result at all: text arrives through con_emit
 * already formatted, and the only buffer left on this path is the input
 * line itself. */

/* Widest row array any single draw uses - a ~208px output pane at Monaco 9
 * is about 17 rows; see the row math in draw_output, which never indexes
 * past `shown`. */
enum { kMaxRows = 24 };

static WindowPtr gWindow  = NULL;
static TEHandle  gInputTE = NULL;
static Boolean   gActive  = false;

static Rect gOutRect, gInRect, gHintRect;
static short gPromptWidth = 0;   /* pixels taken by the "> " prompt */

static N68ConsoleRing gOut;
static N68History     gHistory;
static int            gInited = 0;

/* How many lines the view is scrolled UP from the newest. 0 = following the
 * bottom, which is where it snaps back on any new output. */
static short gScrollBack = 0;

/* ---- output ---------------------------------------------------------------- */

/* Appends one line to the scrollback and marks the pane dirty. Every caller
 * is a genuine content change (an echoed command, a result, a help line),
 * never a per-pass poll, so the unconditional InvalRect is the
 * invalidate-on-real-change rule rather than a violation of it. */
static void con_out(const char *s)
{
    n68_console_feed(&gOut, s, strlen(s));
    n68_console_feed(&gOut, "\r", 1);

    /* New output snaps the view back to the bottom. The alternative -
     * holding position while scrolled up - only makes sense for output that
     * arrives on its own; everything here arrives because the human just
     * pressed Return, and hiding their own result would read as a hang. */
    gScrollBack = 0;

    if (gWindow != NULL) {
        InvalRect(&gOutRect);
    }
}

/* Feeds a multi-line block (n68_cmdresult_render_text separates rows with
 * CR) as-is: the ring's splitter already turns CR into line breaks, so this
 * is one call, not a loop this file has to write. */
static void con_out_block(const char *s, long length)
{
    if (length <= 0) {
        return;
    }
    n68_console_feed(&gOut, s, (size_t)length);
    n68_console_feed(&gOut, "\r", 1);
    gScrollBack = 0;
    if (gWindow != NULL) {
        InvalRect(&gOutRect);
    }
}

/* ---- input field ----------------------------------------------------------- */

static void input_get_text(char *out, int cap)
{
    Handle h;
    short  len;
    short  n;

    out[0] = '\0';
    if (gInputTE == NULL || cap <= 0) {
        return;
    }
    len = (**gInputTE).teLength;
    h = (**gInputTE).hText;
    if (h == NULL || len <= 0) {
        return;
    }
    n = len < (short)(cap - 1) ? len : (short)(cap - 1);
    /* No call that can move memory between the deref and the copy - the
     * standing Handle rule (AGENTS.md / managers-memory-callbacks). */
    memcpy(out, *h, (size_t)n);
    out[n] = '\0';
}

static void input_set_text(const char *s)
{
    if (gInputTE == NULL) {
        return;
    }
    TESetText(s, (long)strlen(s), gInputTE);
    TESetSelect(32767, 32767, gInputTE);   /* caret to end, the shell idiom */
    TESelView(gInputTE);
    InvalRect(&gInRect);
}

/* ---- running a line -------------------------------------------------------- */

/* Emits a line built with now68k_fmt_append_* .
 *
 * THE APPEND HELPERS DO NOT TERMINATE. They copy strlen(s) bytes and
 * advance pos, which is right for building a wire payload of a known
 * length (numfmt.h exists so this guest can avoid snprintf entirely),
 * and wrong for anything handed to a function that takes a C string.
 * con_out takes a C string.
 *
 * Every builder here declares `char line[80]` INSIDE its loop, so each
 * iteration gets the same stack bytes the previous one left behind. A
 * line shorter than the one before it therefore trails that one's tail:
 * "files land in Startup Items" came out as "files land in Startup
 * Itemsbytes", picking up the end of "...1048576 bytes" above it. Caught
 * on a screen, because no native test can see a pixel.
 *
 * Terminating at each call site is the fix that had already been
 * forgotten twice (show_help and show_processes both had it latent, and
 * only avoided showing it because their lines happen to grow rather than
 * shrink). This is the one that cannot be forgotten: there is no way to
 * emit a built line except through here. */
/* The console window's emitter for n68_exec.h. Identical to con_out_block
 * above - it IS con_out_block, named for the callback it satisfies - and it
 * is the whole of what this window contributes to running a command now.
 * Everything that decides WHAT to print moved to n68_exec.c so the host's
 * console renders from the same dispatch; see that file's header for why a
 * second copy of this policy was the drift waiting to happen. */
static void con_emit(void *ctx, const char *text, long length)
{
    (void)ctx;
    con_out_block(text, length);
}

static void submit_line(void)
{
    char line[kInputCap];
    char name[kN68CmdCodeCap];
    char echo[kInputCap + 4];

    input_get_text(line, (int)sizeof line);
    input_set_text("");
    n68_history_push(&gHistory, line);

    /* An empty Return is a no-op, not a blank echoed line: on a 17-row pane
     * a stray Return would push real output off the top. */
    if (line[0] == '\0') {
        return;
    }

    echo[0] = '>';
    echo[1] = ' ';
    {
        size_t len = strlen(line);
        memcpy(echo + 2, line, len + 1);
    }
    con_out(echo);

    /* `clear` is answered HERE and nowhere else, because it acts on this
     * window's scrollback rather than on this machine. That is the whole
     * test for what stays behind: a verb belongs to the side whose pixels
     * it changes, which is the same rule the host's console applies from
     * the other end to its own /clear (ConsoleModel.LocalVerb). A wire that
     * carried this word would be one machine emptying another's view.
     *
     * The split is asked for only to answer it. Everything else - the
     * verb, its grammar, which renderer it gets, what an unknown name says
     * - belongs to n68_exec.c, which the host reaches too. */
    now68k_exec_split(line, name, (int)sizeof name);
    if (strcmp(name, "clear") == 0) {
        n68_console_init(&gOut);
        gScrollBack = 0;
        if (gWindow != NULL) {
            InvalRect(&gOutRect);
        }
        return;
    }

    /* wire_idle as the pump: a human has just started a command that may
     * walk the catalog or wait out a quit confirmation, and the wire must
     * not die of silence while they do. wire68.c passes NULL to the same
     * function for the opposite reason - see N68ExecPump. */
    (void)now68k_exec_line(line, con_emit, NULL, wire_idle);
}

/* ---- drawing --------------------------------------------------------------- */

static void draw_output(void)
{
    FontInfo fi;
    short    lineHeight, rows, i;
    size_t   retained, maxBack, first, shown;
    N68ConsoleLine lines[kMaxRows];
    Rect     inner;

    FrameRect(&gOutRect);
    inner = gOutRect;
    InsetRect(&inner, 2, 2);
    /* ERASE BEFORE DRAWING, and this is not decoration. The Window
     * Manager erases only what it newly exposes; a rectangle WE
     * invalidated arrives with its old pixels intact, and this pane draws
     * a variable number of lines. Without this, `clear` emptied the
     * buffer and drew nothing over the old text, so the pane looked
     * untouched and the command looked broken - watched in the q800
     * emulator, 2026-07-25, where it cost a bug report against `clear`
     * that was really a bug here. */
    EraseRect(&inner);

    TextFont(kFontIDMonaco);
    TextSize(9);
    GetFontInfo(&fi);
    lineHeight = (short)(fi.ascent + fi.descent + fi.leading);
    if (lineHeight <= 0) {
        return;   /* pathological font metrics - nothing sane to draw */
    }

    rows = (short)((inner.bottom - inner.top) / lineHeight);
    if (rows > kMaxRows) {
        rows = kMaxRows;
    }
    if (rows <= 0) {
        return;
    }

    retained = n68_console_retained_count(&gOut);
    maxBack = retained > (size_t)rows ? retained - (size_t)rows : 0;
    if ((size_t)gScrollBack > maxBack) {
        /* The pane grew, or lines aged out from under a scrolled-up view.
         * Clamped here, in the one place that knows both numbers, rather
         * than at each key that changes either. */
        gScrollBack = (short)maxBack;
    }
    first = maxBack - (size_t)gScrollBack;

    shown = n68_console_visible_slice(&gOut, first, lines, (size_t)rows);
    for (i = 0; i < (short)shown; i++) {
        MoveTo(inner.left, (short)(inner.top + fi.ascent + i * lineHeight));
        DrawText(lines[i].text, 0, (short)lines[i].length);
    }
}

static void draw_input(void)
{
    FontInfo fi;

    FrameRect(&gInRect);
    {
        /* Same reason as draw_output, and the same watched symptom: after
         * Return the field is emptied and invalidated, but TEUpdate draws
         * only the text it HAS - it does not clear what was there. The
         * command a human just ran stayed on screen looking unrun, and
         * pressing Return again would have repeated it. For `quit` or
         * `launch` that is a real action on a real machine. */
        Rect inner = gInRect;

        InsetRect(&inner, 1, 1);
        EraseRect(&inner);
    }
    TextFont(kFontIDMonaco);
    TextSize(9);
    GetFontInfo(&fi);
    MoveTo((short)(gInRect.left + 3),
           (short)(gInRect.top + 3 + fi.ascent));
    DrawString(PSTR("\p> "));

    if (gInputTE != NULL) {
        Rect view = (**gInputTE).viewRect;
        TEUpdate(&view, gInputTE);
    }
}

static void draw_hint(void)
{
    FontInfo fi;

    TextFont(kFontIDGeneva);
    TextSize(9);
    GetFontInfo(&fi);
    MoveTo(gHintRect.left, (short)(gHintRect.top + fi.ascent));
    DrawString(PSTR("\pReturn runs  -  Up/Down history  -  Option-Up/Down "
                     "scrolls  -  type help"));
}

/* The one painter. Nothing else in this file draws outside the updateEvt
 * bracket that calls it - see this file's header comment. */
static void draw_all(void)
{
    draw_output();
    draw_input();
    draw_hint();
}

/* ---- lifecycle -------------------------------------------------------------- */

static void ensure_buffers(void)
{
    if (gInited) {
        return;
    }
    n68_console_init(&gOut);
    n68_history_init(&gHistory);
    gInited = 1;

    con_out("NOW-68K console - type help.");
}

void conwin_show(void)
{
    Rect bounds, dest, view;

    ensure_buffers();

    if (gWindow != NULL) {
        SelectWindow(gWindow);
        return;
    }

    SetRect(&bounds, kCWinLeft, kCWinTop,
            kCWinLeft + kCWinWidth, kCWinTop + kCWinHeight);

    /* noGrowDocProc for the same reason window.c gives: documentProc
     * reserves a grow box this file neither draws nor handles, and a
     * control that is drawn but inert reads as a bug. */
    gWindow = NewCWindow(NULL, &bounds, PSTR("\pConsole"), true,
                          noGrowDocProc, (WindowPtr)-1L, true, 0);
    if (gWindow == NULL) {
        now68k_log("conwin: NewCWindow failed");
        return;
    }
    SetPort(gWindow);
    gActive = true;

    SetRect(&gOutRect,  kCMargin, kCOutTop,  kCRight, kCOutBot);
    SetRect(&gInRect,   kCMargin, kCInTop,   kCRight, kCInBot);
    SetRect(&gHintRect, kCMargin, kCHintTop, kCRight, kCHintBot);

    /* Set the port's font/size BEFORE TENew: TENew captures the port's
     * txFont/txSize into the TERec permanently, and TEUpdate/TESetText draw
     * with the TERec's own pair, not whatever a later draw sets. window.c
     * records this as DEFECT 16 - a freshly made port is Chicago 12, whose
     * ~16px line height clips inside an 18px field. Monaco 9 here so typed
     * text matches the output pane above it character for character, which
     * is the whole point of a console. */
    TextFont(kFontIDMonaco);
    TextSize(9);
    gPromptWidth = StringWidth(PSTR("\p> "));

    view = gInRect;
    InsetRect(&view, 3, 3);
    view.left = (short)(view.left + gPromptWidth);
    dest = view;
    /* destRect far wider than viewRect so TE never word-wraps (there is no
     * second line to wrap into); TESelView after every edit keeps the caret
     * in view - the standard classic-Mac one-line scrolling field recipe
     * (Inside Macintosh: Text), same as window.c's three fields. */
    dest.right = (short)(dest.left + 2000);
    gInputTE = TENew(&dest, &view);
    if (gInputTE == NULL) {
        /* Keep the window: the scrollback is still readable and still
         * scrollable, which is more useful than a window that refuses to
         * open. A dead field reads as inert, not as a crash. */
        now68k_log("conwin: TENew failed - output only, no input");
    } else {
        TEActivate(gInputTE);
    }
}

int conwin_owns(WindowPtr w)
{
    return (w != NULL && w == gWindow);
}

void conwin_close(void)
{
    if (gInputTE != NULL) {
        TEDispose(gInputTE);
        gInputTE = NULL;
    }
    if (gWindow != NULL) {
        DisposeWindow(gWindow);
        gWindow = NULL;
    }
    gActive = false;
    /* gOut and gHistory deliberately survive: closing a console should not
     * silently erase what it said, and both are BSS that costs the same
     * either way. */
}

void conwin_dispose(void)
{
    conwin_close();
}

/* ---- events ----------------------------------------------------------------- */

static void handle_key(EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);
    const char *recalled;
    char current[kInputCap];

    /* Option-Up/Down scrolls the pane, as well as Page Up/Down below.
     * BOTH bindings exist because of the machine: kPageUpCharCode /
     * kPageDownCharCode (Events.h, 11 and 12) come from an extended
     * keyboard's dedicated page keys, and the PowerBook 180c's built-in
     * keyboard has no such keys - a console whose only way to see older
     * output needed hardware the target does not have would be scrollback
     * in name only. Option is chosen over Command because Command-anything
     * is consumed by MenuKey in main.c before this file ever sees it. */
    if ((event->modifiers & optionKey) != 0
        && (c == kUpArrowCharCode || c == kDownArrowCharCode)) {
        if (c == kUpArrowCharCode) {
            gScrollBack = (short)(gScrollBack + 1);
        } else {
            gScrollBack = (short)(gScrollBack > 0 ? gScrollBack - 1 : 0);
        }
        InvalRect(&gOutRect);
        return;
    }

    switch (c) {
    case kUpArrowCharCode:
    case kDownArrowCharCode:
        /* INTERCEPTED BEFORE TEKey, and that ordering is the feature. Given
         * these two codes TextEdit moves the insertion point between
         * display lines; in a one-line field that is a no-op, so handing
         * them to TEKey would make the arrows do nothing at all rather than
         * walk history. Left and right arrows (kLeftArrowCharCode /
         * kRightArrowCharCode, Events.h) deliberately fall through to TEKey
         * below, which is where ordinary cursor movement belongs and where
         * shift-extend already works.
         *
         * n68_history returns NULL for "there is nothing further that way",
         * which means LEAVE THE FIELD ALONE - never clear it. Pressing Up
         * past the oldest entry must not wipe what is showing. */
        if (c == kUpArrowCharCode) {
            input_get_text(current, (int)sizeof current);
            recalled = n68_history_prev(&gHistory, current);
        } else {
            recalled = n68_history_next(&gHistory);
        }
        if (recalled != NULL) {
            input_set_text(recalled);
        }
        break;

    case kReturnCharCode:
    case kEnterCharCode:
        submit_line();
        break;

    case kPageUpCharCode:
        gScrollBack = (short)(gScrollBack + 4);
        /* The upper clamp lives in draw_output, which is the only code that
         * knows how many rows fit and how many lines are retained. */
        InvalRect(&gOutRect);
        break;

    case kPageDownCharCode:
        gScrollBack = (short)(gScrollBack >= 4 ? gScrollBack - 4 : 0);
        InvalRect(&gOutRect);
        break;

    default:
        if (gInputTE != NULL) {
            /* Everything else is TextEdit's: printable characters, Delete/
             * Backspace, and left/right cursor movement with or without
             * shift. Reimplementing any of it here would be a second, worse
             * line editor. */
            TEKey((CharParameter)c, gInputTE);
            TESelView(gInputTE);
        }
        break;
    }
}

void conwin_handle_event(EventRecord *event)
{
    GrafPtr save;
    WindowPtr w;

    if (gWindow == NULL) {
        return;
    }

    switch (event->what) {
    case updateEvt:
        w = (WindowPtr)event->message;
        GetPort(&save);
        SetPort(w);
        BeginUpdate(w);
        draw_all();
        EndUpdate(w);
        SetPort(save);
        break;

    case activateEvt:
    {
        Boolean newActive = (event->modifiers & activeFlag) != 0;

        if (newActive != gActive) {
            gActive = newActive;
            GetPort(&save);
            SetPort(gWindow);
            if (gInputTE != NULL) {
                if (gActive) {
                    TEActivate(gInputTE);
                } else {
                    TEDeactivate(gInputTE);
                }
            }
            SetPort(save);
        }
        break;
    }

    case osEvt:
        if (((event->message >> 24) & 0xFF) == suspendResumeMessage) {
            Boolean newActive = (event->message & resumeFlag) != 0;

            if (newActive != gActive) {
                gActive = newActive;
                GetPort(&save);
                SetPort(gWindow);
                if (gInputTE != NULL) {
                    if (gActive) {
                        TEActivate(gInputTE);
                    } else {
                        TEDeactivate(gInputTE);
                    }
                }
                SetPort(save);
            }
        }
        break;

    case mouseDown:
    {
        Point pt;

        GetPort(&save);
        SetPort(gWindow);
        pt = event->where;
        GlobalToLocal(&pt);
        if (gInputTE != NULL && PtInRect(pt, &gInRect)) {
            TEClick(pt, (event->modifiers & shiftKey) != 0, gInputTE);
            TESelView(gInputTE);
        }
        /* A click in the output pane does nothing on purpose: the pane is
         * drawn text, not a TERec, so there is nothing to select. Noted
         * rather than silently ignored - copy-out of the scrollback is a
         * real gap, and docs/open-issues.md carries it. */
        SetPort(save);
        break;
    }

    case keyDown:
    case autoKey:
        /* One port bracket around the whole key path, not per-branch:
         * input_set_text and the Page keys call InvalRect, which writes
         * into WindowPeek(thePort)->updateRgn - whatever port is current,
         * not necessarily this one, once a desk accessory has changed it.
         * window.c records the per-branch version of this as DEFECT 8. */
        GetPort(&save);
        SetPort(gWindow);
        handle_key(event);
        SetPort(save);
        break;

    default:
        break;
    }
}

void conwin_idle(void)
{
    GrafPtr save;

    if (gWindow == NULL || gInputTE == NULL || !gActive) {
        return;   /* costs nothing while the window is closed or behind */
    }
    GetPort(&save);
    SetPort(gWindow);
    TEIdle(gInputTE);   /* insertion-point blink - the standard TE idiom for
                            this, not "our" redraw */
    SetPort(save);
}
