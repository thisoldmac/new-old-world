/*
 * window.c - the NOW-68K single window (see window.h). One page, no tabs
 * (System 7.1 has no Appearance Manager and therefore no tab CDEF - a hand-
 * drawn tab bar is deferred to its own slice, now-guest-68k.r's SIZE resource
 * comment and AGENTS.md agree). Connection fields, health readout and
 * console all live here.
 *
 * STATIC MEMORY BUDGET (no malloc/NewPtr/NewHandle anywhere in this file):
 *   gConsole (N68ConsoleRing)      8192 + 128 + ~16       ~ 8.2 KB (its own
 *                                                            documented
 *                                                            budget, n68_
 *                                                            console_ring.h)
 *   3 field-text extraction buffers  40 + 24 + 24          =   88  bytes
 *   gStatusShown (kStatusShownCap)                         =  128  bytes
 *   ConnHost/Port/TimeoutResult x2 (live + shown)           ~  200  bytes
 *   gDev (N68DevSettings) + gDevLoaded + gRetrySecs          ~   70  bytes
 *                                        (68K: int 4, short 2, align 2;
 *                                         grew by 6 with the launch-search
 *                                         budget key, and the old ~50 here
 *                                         was already an undercount)
 *   misc scalars (focus, rects, handles, UPP)                ~  150  bytes
 *   ---------------------------------------------------------------------
 *   file-static total                                       ~  8.9 KB
 * Transient stack use inside a single draw call: draw_console's
 * buf[48] + lines[24]*sizeof(N68ConsoleLine)(8) = 240 bytes, or
 * draw_health's line[160] + a stack-local HealthDynamic (two ~24-byte
 * string bufs plus two longs) = ~216 bytes - draw_page calls these in
 * sequence, not nested, so only one is ever live at a time. Freed on
 * return - not held across calls. Well under the 384 KB partition and the
 * <1 MB free-memory design target.
 *
 * NOT sized here: the three TERecs + their text Handles (TENew), the
 * WindowRecord (NewCWindow), two ControlRecords (NewControl) and one
 * ControlActionUPP routine descriptor - these come out of the application
 * heap via the Toolbox's own internal sizing, not this file's static data,
 * and Universal Interfaces does not document a fixed byte count for any of
 * them (TextEdit.h's TERec.lineStarts[16001] is a compile-time upper bound
 * for struct layout, not what TENew actually allocates for a one-line
 * field). Classic single-line TERecs and small ControlRecords are
 * conventionally a few hundred bytes each; this file has no way to state
 * an exact number and does not claim one.
 */
#include "window.h"
#include "log.h"
#include "wire68.h"
#include "connfields.h"
#include "n68_console_ring.h"
#include "numfmt.h"
#include "health.h"
#include "n68_devsettings_file.h"
#include "proc68.h"   /* proc_set_launch_search_seconds - see dev_settings_apply_wire */

#include <MacWindows.h>
#include <Quickdraw.h>
#include <Fonts.h>
#include <TextUtils.h>
#include <TextEdit.h>
#include <Controls.h>
#include <Memory.h>

#include <stddef.h>
#include <string.h>

/* A "\p" literal is a char*, every Toolbox string argument is a
 * ConstStr255Param (const unsigned char*), and the two differ in signedness.
 * Without the warning gate that mismatch compiles silently; with it, every
 * call site needs the cast, so it lives here once instead of at each one. */
#define PSTR(s) ((ConstStr255Param)(s))

/* Classic Control Manager procID values (pushButProc / checkBoxProc). Not
 * pulled from ControlDefinitions.h - that header chains into Appearance.h
 * and CarbonEvents.h, which this 68K non-Carbon app does not, and must not,
 * link against (AGENTS.md: no Appearance Manager on System 7.1). These two
 * numbers are Control Manager ABI going back to System 1, stable enough to
 * hand-roll instead of dragging in a Carbon-flavored header for them. */
enum {
    kPushButProcID  = 0,
    kCheckBoxProcID = 1
};

/* Stringize-after-expansion so the pre-filled Port/Timeout text tracks
 * connfields.h's own default constants instead of duplicating "5250"/"15"
 * as literals that could silently drift from them. */
#define N68_STR2(x) #x
#define N68_STR(x) N68_STR2(x)
static const char kDefaultPortText[]    = N68_STR(kNowDefaultHostPort);
static const char kDefaultTimeoutText[] = N68_STR(kConnTimeoutDefaultSecs);

/* 512x300 leaves the whole page visible on the 180c's 640x480 panel with the
 * menu bar above it, and still fits a 512x342 compact screen if this ever
 * runs on one. */
#define kWinLeft    40
#define kWinTop     60
#define kWinWidth   512
#define kWinHeight  300

#define kMargin     8
#define kRightEdge  504     /* kWinWidth - kMargin */

#define kFieldX     70      /* all three field boxes start here */
#define kReasonX   240      /* all three reason columns start here */

#define kHostFieldR     230
#define kPortFieldR     150
#define kTimeoutFieldR  150

#define kHostTop      8
#define kHostBot     26
#define kPortTop     32
#define kPortBot     50
#define kTimeoutTop  56
#define kTimeoutBot  74

#define kCtlTop      82
#define kCtlBot     104
#define kConnectBtnR 96
#define kRetryChkX  104
#define kRetryChkR  320

#define kStatusTop  110
#define kStatusBot  124

#define kHealthTop  128
#define kHealthBot  142

#define kConsoleTop 150
#define kConsoleBot 292     /* kWinHeight - kMargin */

#define kHostTextCap  40    /* "255.255.255.255" is 15 chars; headroom so a
                                too-long paste is caught explicitly instead
                                of silently clipped into something that
                                coincidentally validates */
#define kSmallTextCap 24    /* port/timeout: "65535" is 5 chars, "60" is 2 */

typedef enum {
    kFocusHost = 0,
    kFocusPort,
    kFocusTimeout
} FieldFocus;

static WindowPtr gWindow = NULL;
static Boolean   gActive = false;

static TEHandle gHostTE    = NULL;
static TEHandle gPortTE    = NULL;
static TEHandle gTimeoutTE = NULL;
static FieldFocus gFocus   = kFocusHost;

static Rect gHostFieldRect,    gHostReasonRect;
static Rect gPortFieldRect,    gPortReasonRect;
static Rect gTimeoutFieldRect, gTimeoutReasonRect;
static Rect gStatusRect, gHealthRect, gConsoleRect;

/* Live validation results (recomputed on every keystroke in the affected
 * field) and the copies last invalidated-for, so InvalRect fires only when
 * the drawn text would actually differ - guest-ui-start-here.md's idle-work
 * rule, applied at the point of mutation rather than by polling. */
static ConnHostResult    gHostResult,    gHostShown;
static ConnPortResult    gPortResult,    gPortShown;
static ConnTimeoutResult gTimeoutResult, gTimeoutShown;

static ControlHandle gConnectBtn = NULL;
static ControlHandle gRetryChk   = NULL;
static ControlActionUPP gPumpActionUPP = NULL;

/* The redial cadence the checkbox stands for. It used to be the literal 5
 * in toggle_retry and the literal "5s" in the control's title, which agreed
 * only by inspection; the dev settings file can now name a different one,
 * and a checkbox whose label says 5 while the wire redials every 30 is
 * worse than either number - so both read from here. With no settings file
 * this is 5 and nothing about the control changes. */
static unsigned short gRetrySecs = kN68DevRetryDefaultSecs;

/* The dev-only settings file, read once in window_init. gDevLoaded is 0 on
 * every machine that does not have one - which is every machine but a lab
 * bench - and in that state nothing below runs and the window behaves
 * exactly as it did before this file existed (n68_devsettings.h). */
static N68DevSettings gDev;
static int            gDevLoaded = 0;

/* DEFECT 2 (fixed): this used to be gStatusShown[64]. wire_status() reads
 * from wire68.c's g_status[96] (that file's own STATIC BUDGET comment), so
 * any status past 63 chars - the contract's own refuse text, or a routine
 * "Connected: <name> (v<version>)" at 69 chars - silently truncated on
 * copy_bounded's write side while the strcmp below compared that truncated
 * copy against the FULL untruncated wire_status() string. Once truncated,
 * the two could never compare equal again, so every window_idle pass
 * re-invalidated the status rect AND fed a duplicate line into the
 * console - a full repaint at idle-loop rate that visibly froze the 180c.
 * kStatusShownCap is sized past wire68.c's 96-byte budget with headroom
 * (this module has no compile-time access to that private buffer's exact
 * size, so "safely larger than any status this app would ever draw" is the
 * only bound available from here). The comparison in window_idle below is
 * ALSO now truncated-vs-truncated rather than truncated-vs-full, so even a
 * future status that somehow still overflows this buffer converges to a
 * stable match instead of invalidating forever - the sizing alone would not
 * have prevented a recurrence of the same failure at a longer string. */
#define kStatusShownCap 128
static char      gStatusShown[kStatusShownCap];
static WireState  gWireStateShown = kWireIdle;

static N68ConsoleRing gConsole;

/* ---- small local helpers, no libc dependency beyond string.h ---------- */

static void copy_bounded(char *dst, const char *src, int cap)
{
    int i = 0;

    while (src[i] != '\0' && i < cap - 1) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

static TEHandle field_te(FieldFocus f)
{
    switch (f) {
    case kFocusHost:    return gHostTE;
    case kFocusPort:    return gPortTE;
    default:            return gTimeoutTE;
    }
}

static const Rect *field_rect(FieldFocus f)
{
    switch (f) {
    case kFocusHost:    return &gHostFieldRect;
    case kFocusPort:    return &gPortFieldRect;
    default:            return &gTimeoutFieldRect;
    }
}

/* draw_field draws the focus ring at InsetRect(&outer,-2,-2) around
 * field_rect(f) - 2px OUTSIDE the field box on every side. field_rect(f)
 * alone is not what is actually drawn there. */
static Rect field_focus_rect(FieldFocus f)
{
    Rect outer = *field_rect(f);

    InsetRect(&outer, -2, -2);
    return outer;
}

/* Appends one line to the console ring and invalidates its rect. Every
 * call here is a genuine content change (a status transition, a button
 * press) rather than a per-pass poll, so an unconditional InvalRect is
 * exactly the "invalidate on real change" rule, not a violation of it. */
static void console_note(const char *s)
{
    size_t len = strlen(s);

    n68_console_feed(&gConsole, s, len);
    n68_console_feed(&gConsole, "\r", 1);
    if (gConsoleRect.bottom > gConsoleRect.top) {
        InvalRect(&gConsoleRect);
    }
}

/* Copies up to cap-1 bytes of a TE field's text into out (NUL-terminated)
 * and returns the field's TRUE length, which may exceed cap - callers must
 * check that before trusting a validator result on the (possibly
 * truncated) copy. */
static short get_field_text(TEHandle te, char *out, int cap)
{
    short  len;
    short  n;
    Handle h;

    if (te == NULL || cap <= 0) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    len = (*te)->teLength;
    if (len < 0) {
        len = 0;
    }
    n = (len >= (short)cap) ? (short)(cap - 1) : len;
    h = (*te)->hText;
    if (h != NULL && n > 0) {
        HLock(h);
        BlockMoveData(*h, out, n);
        HUnlock(h);
    }
    out[n] = '\0';
    return len;
}

static void revalidate_host(void)
{
    char  buf[kHostTextCap];
    short len = get_field_text(gHostTE, buf, sizeof buf);

    if (len >= (short)sizeof buf) {
        gHostResult.ok = 0;
        gHostResult.addr = 0;
        copy_bounded(gHostResult.reason, "too long", kConnReasonMax);
    } else {
        gHostResult = now_conn_host_validate(buf);
    }
    if (gHostResult.ok != gHostShown.ok
        || strcmp(gHostResult.reason, gHostShown.reason) != 0) {
        gHostShown = gHostResult;
        InvalRect(&gHostReasonRect);
    }
}

static void revalidate_port(void)
{
    char  buf[kSmallTextCap];
    short len = get_field_text(gPortTE, buf, sizeof buf);

    if (len >= (short)sizeof buf) {
        gPortResult.ok = 0;
        gPortResult.port = 0;
        copy_bounded(gPortResult.reason, "too long", kConnReasonMax);
    } else {
        gPortResult = now_conn_port_validate(buf);
    }
    if (gPortResult.ok != gPortShown.ok
        || strcmp(gPortResult.reason, gPortShown.reason) != 0) {
        gPortShown = gPortResult;
        InvalRect(&gPortReasonRect);
    }
}

static void revalidate_timeout(void)
{
    char  buf[kSmallTextCap];
    short len = get_field_text(gTimeoutTE, buf, sizeof buf);

    if (len >= (short)sizeof buf) {
        gTimeoutResult.ok = 0;
        gTimeoutResult.seconds = 0;
        copy_bounded(gTimeoutResult.reason, "too long", kConnReasonMax);
    } else {
        gTimeoutResult = now_conn_timeout_validate(buf);
    }
    if (gTimeoutResult.ok != gTimeoutShown.ok
        || strcmp(gTimeoutResult.reason, gTimeoutShown.reason) != 0) {
        gTimeoutShown = gTimeoutResult;
        InvalRect(&gTimeoutReasonRect);
    }
}

static void revalidate_focused(void)
{
    switch (gFocus) {
    case kFocusHost:    revalidate_host();    break;
    case kFocusPort:    revalidate_port();    break;
    case kFocusTimeout: revalidate_timeout(); break;
    }
}

/* Focus change is the one place the field frame's drawn appearance depends
 * on something other than validity, so it is the one place besides a
 * keystroke that invalidates a field rect outside window_idle. Only the
 * two affected frames move, never the whole window. */
static void set_focus(FieldFocus f)
{
    Rect r;

    if (f == gFocus) {
        return;
    }
    if (gActive) {
        TEDeactivate(field_te(gFocus));
    }
    /* DEFECT 7 (fixed): this used to InvalRect(field_rect(gFocus)), which
     * does not cover the ring draw_field actually paints (2px outside the
     * field box). BeginUpdate clips to the update region, so the old ring
     * was never erased and the new one was never drawn under that region -
     * tab around the fields and rings accumulated. Invalidate the rect that
     * is actually drawn, not the field box it surrounds. */
    r = field_focus_rect(gFocus);
    InvalRect(&r);
    gFocus = f;
    r = field_focus_rect(gFocus);
    InvalRect(&r);
    if (gActive) {
        TEActivate(field_te(gFocus));
    }
}

static void cycle_focus(short shiftDown)
{
    FieldFocus next;

    if (!shiftDown) {
        next = (gFocus == kFocusTimeout) ? kFocusHost : (FieldFocus)(gFocus + 1);
    } else {
        next = (gFocus == kFocusHost) ? kFocusTimeout : (FieldFocus)(gFocus - 1);
    }
    set_focus(next);
}

/* SetControlTitle redraws the control immediately, the same Toolbox-owned
 * exception TEKey/TEClick get - it is not "our" drawing and does not need
 * an InvalRect or a BeginUpdate/EndUpdate bracket. */
static void update_connect_button(WireState st)
{
    Boolean connectable = (st == kWireIdle || st == kWireWaiting);

    if (gConnectBtn != NULL) {
        SetControlTitle(gConnectBtn,
                         connectable ? PSTR("\pConnect") : PSTR("\pDisconnect"));
    }
}

static void handle_connect_toggle(void)
{
    WireState st = wire_state();

    if (st == kWireIdle || st == kWireWaiting) {
        if (gHostResult.ok && gPortResult.ok && gTimeoutResult.ok) {
            wire_set_target(gHostResult.addr, gPortResult.port,
                             (unsigned short)gTimeoutResult.seconds);
            wire_start();
            console_note("connect requested");
        } else {
            /* The reason a field is bad is already on screen next to it -
             * this is not a silent refusal of validation, only of the
             * click, and the console still records that it happened. */
            console_note("connect refused: check field(s) above");
        }
    } else {
        wire_stop();
        console_note("disconnect requested");
    }
}

/* "Retry every Ns" for the current cadence. Only called when a settings
 * file moved the cadence off 5, so with no file the control keeps the exact
 * title NewControl gave it. SetControlTitle redraws immediately - the same
 * Toolbox-owned exception update_connect_button above relies on. */
static void set_retry_title(unsigned short secs)
{
    Str255 title;
    char   text[32];
    long   pos = 0;

    if (gRetryChk == NULL) {
        return;
    }
    if (!now68k_fmt_append_str(text, (long)sizeof text, &pos, "Retry every ")
        || !now68k_fmt_append_long(text, (long)sizeof text, &pos, (long)secs)
        || !now68k_fmt_append_str(text, (long)sizeof text, &pos, "s")
        || pos > 255) {
        return;   /* numfmt refuses rather than truncates; so do we */
    }
    title[0] = (unsigned char)pos;
    BlockMoveData(text, &title[1], pos);
    SetControlTitle(gRetryChk, title);
}

static void console_note_retry(short on)
{
    char text[40];
    long pos = 0;

    if (!on) {
        console_note("retry: off");
        return;
    }
    if (now68k_fmt_append_str(text, (long)sizeof text, &pos, "retry: every ")
        && now68k_fmt_append_long(text, (long)sizeof text, &pos, (long)gRetrySecs)
        && now68k_fmt_append_str(text, (long)sizeof text, &pos, "s")
        && pos < (long)sizeof text) {
        text[pos] = '\0';
        console_note(text);
    }
}

static void toggle_retry(void)
{
    short newVal = (short)(GetControlValue(gRetryChk) ? 0 : 1);

    SetControlValue(gRetryChk, newVal);
    /* gRetrySecs, not a literal 5: the cadence and the label it is drawn
     * from have to be the same number. wire_set_retry still owns the >= 1 s
     * floor (wire68.h) - nothing here clamps or bypasses it. */
    wire_set_retry(newVal, gRetrySecs);
    console_note_retry(newVal);
}

/* Pumps the wire while a finger holds a control down (TrackControl, Connect
 * or Retry) - a NULL action proc here would stop the connection for as long
 * as the mouse stays down (net.h's one-op-in-flight state machine still
 * needs its polling, guest-ui-start-here.md / window.h's transport-pass
 * note). Declared with New/DisposeControlActionUPP rather than cast so the
 * source reads the same as the CFM PPC guest's pump.h, even though on 68K a
 * UPP is the ProcPtr and the cast would also be correct. */
static pascal void pump_action_proc(ControlHandle theControl, short partCode)
{
    (void)theControl;
    (void)partCode;
    wire_idle();
}

/* ---- drawing - all of it runs inside BeginUpdate/EndUpdate ------------
 *
 * QuickDraw clips every call here to the accumulated update region, so this
 * function can unconditionally redraw the whole page's CURRENT state on
 * every updateEvt: the discipline that keeps redraws cheap lives in what
 * gets InvalRect'd (window_idle and the mutation-path helpers above), not
 * in this function deciding what to skip. Nothing here runs outside
 * Begin/EndUpdate - see window_handle_event's updateEvt case, the one
 * painting owner.
 */

static void draw_field(ConstStr255Param label, short labelBaselineY,
                        const Rect *fieldRect, TEHandle te, Boolean focused,
                        const Rect *reasonRect, const char *reason)
{
    MoveTo(kMargin, labelBaselineY);
    DrawString(label);

    FrameRect(fieldRect);
    if (focused) {
        /* An outer ring, not a thicker frame - the classic "this field has
         * the caret" look, and it cannot collide with the label to its
         * left or the reason text to its right at this layout's spacing. */
        Rect outer = *fieldRect;
        InsetRect(&outer, -2, -2);
        FrameRect(&outer);
    }

    if (te != NULL) {
        TEUpdate(fieldRect, te);
    }

    MoveTo(reasonRect->left, reasonRect->bottom - 5);
    DrawText(reason, 0, (short)strlen(reason));
}

static void draw_status(void)
{
    const char *status = wire_status();

    MoveTo(kMargin, kStatusBot - 5);
    DrawText(status, 0, (short)strlen(status));
}

/* DEFECT 13 (fixed): health.c/health.h existed with zero callers - this
 * function used to be named draw_status_and_health and its "health" half
 * actually built a WireStats (frames/bytes/pings/dials/rtt) line instead of
 * any of the machine facts health.h documents. That was a briefing failure,
 * not a deliberate design: the kHealthRect slot is wired to health.h now.
 *
 * health_sample_dynamic() is called from HERE, inside draw_page's
 * BeginUpdate/EndUpdate bracket, and nowhere else - health.h is explicit
 * that TempFreeMem/MaxBlock cost real Memory Manager traps and must be
 * sampled "when the panel actually redraws, never from an unconditional
 * idle-loop poll." This function only ever runs on an actual repaint, so
 * that requirement holds by construction - no idle-loop comparison/
 * InvalRect dance is needed to satisfy it. */
static void draw_health(void)
{
    const HealthStatic *hs = health_static();
    HealthDynamic dyn;
    char line[160];
    long pos = 0;
    int  ok;

    health_sample_dynamic(&dyn);

    ok = now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->machine_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->cpu_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->system_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->vm_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->screen_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, hs->ram_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, dyn.free_str)
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, " ")
      && now68k_fmt_append_str(line, (long)sizeof line, &pos, dyn.largest_str);

    MoveTo(kMargin, kHealthBot - 5);
    DrawText(line, 0, (short)(ok ? pos : 0));
}

static void draw_console(void)
{
    FontInfo fi;
    short    lineHeight;
    short    totalRows, contentRows, i;
    size_t   retained, first, shown;
    unsigned long dropped;
    N68ConsoleLine lines[24];  /* generous cap for a ~292px console pane at
                                  Monaco 9's line height; see the row math
                                  below, which never indexes past `shown` */
    Rect inner;

    FrameRect(&gConsoleRect);
    inner = gConsoleRect;
    InsetRect(&inner, 2, 2);

    TextFont(kFontIDMonaco);
    TextSize(9);
    GetFontInfo(&fi);
    lineHeight = (short)(fi.ascent + fi.descent + fi.leading);
    if (lineHeight <= 0) {
        return;   /* pathological font metrics - nothing sane to draw */
    }

    totalRows = (short)((inner.bottom - inner.top) / lineHeight);
    if (totalRows > (short)(sizeof lines / sizeof lines[0])) {
        totalRows = (short)(sizeof lines / sizeof lines[0]);
    }
    if (totalRows <= 0) {
        return;
    }

    dropped = n68_console_dropped_line_count(&gConsole);
    contentRows = (dropped != 0 && totalRows > 1) ? (short)(totalRows - 1)
                                                   : totalRows;

    retained = n68_console_retained_count(&gConsole);
    first = (retained > (size_t)contentRows) ? retained - (size_t)contentRows : 0;
    shown = n68_console_visible_slice(&gConsole, first, lines, (size_t)contentRows);

    for (i = 0; i < (short)shown; i++) {
        MoveTo(inner.left, (short)(inner.top + fi.ascent + i * lineHeight));
        DrawText(lines[i].text, 0, (short)lines[i].length);
    }

    if (dropped != 0) {
        char buf[48];
        long pos = 0;
        int  failed;

        failed = !now68k_fmt_append_str(buf, (long)sizeof buf, &pos, "(")
              || !now68k_fmt_append_long(buf, (long)sizeof buf, &pos, (long)dropped)
              || !now68k_fmt_append_str(buf, (long)sizeof buf, &pos,
                                         " line(s) dropped: too long)");
        if (!failed) {
            MoveTo(inner.left,
                   (short)(inner.top + fi.ascent + contentRows * lineHeight));
            DrawText(buf, 0, (short)pos);
        }
    }
}

static void draw_page(void)
{
    Rect r;

    if (gWindow == NULL) {
        return;
    }
    r = gWindow->portRect;
    EraseRect(&r);

    TextFont(kFontIDGeneva);
    TextSize(9);

    draw_field(PSTR("\pHost:"), kHostTop + 13, &gHostFieldRect, gHostTE,
               gFocus == kFocusHost, &gHostReasonRect, gHostResult.reason);
    draw_field(PSTR("\pPort:"), kPortTop + 13, &gPortFieldRect, gPortTE,
               gFocus == kFocusPort, &gPortReasonRect, gPortResult.reason);
    draw_field(PSTR("\pTimeout:"), kTimeoutTop + 13, &gTimeoutFieldRect, gTimeoutTE,
               gFocus == kFocusTimeout, &gTimeoutReasonRect, gTimeoutResult.reason);

    draw_status();
    draw_health();
    draw_console();

    UpdateControls(gWindow, gWindow->visRgn);
}

/* ---- the dev-only settings file ---------------------------------------
 *
 * Two halves, because the values land at two different moments in
 * window_init: the field text must be in the TERecs BEFORE the first
 * revalidate_* runs, and the retry/autoconnect settings must be applied
 * AFTER wire_init(), which resets the wire's retry state to its defaults
 * (wire68.c). Applying either at the wrong moment silently does nothing,
 * which is the kind of bug that reads as "the file was ignored".
 */

static void dev_settings_apply_fields(void)
{
    gDevLoaded = now68k_devsettings_load(&gDev);
    if (!gDevLoaded) {
        return;   /* the shipping case, and the silent one */
    }

    if (gDev.have_host && gHostTE != NULL) {
        TESetText(gDev.host_text, (long)strlen(gDev.host_text), gHostTE);
    }
    if (gDev.have_port && gPortTE != NULL) {
        char text[8];
        long pos = 0;

        if (now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                   (long)gDev.port)) {
            TESetText(text, pos, gPortTE);
        }
    }
    /* Timeout is deliberately not a settings key: it is the one field whose
     * right value depends on the network in front of the machine, not on
     * which build is being tested, and connfields.h already gives it a
     * defensible default. */
    if (gDev.have_retry_secs) {
        gRetrySecs = gDev.retry_secs;
    }
}

static void console_note_dev_settings(void)
{
    char text[64];
    long pos = 0;

    if (now68k_fmt_append_str(text, (long)sizeof text, &pos, "dev settings: ")
        && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                  (long)gDev.keys_set)
        && now68k_fmt_append_str(text, (long)sizeof text, &pos,
                                 " applied, ")
        && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                  (long)gDev.bad_lines)
        && now68k_fmt_append_str(text, (long)sizeof text, &pos,
                                 " line(s) ignored")
        && pos < (long)sizeof text) {
        text[pos] = '\0';
        console_note(text);
    }
}

/* The launch-search budget, and the one line that stops it costing someone
 * an hour. A shortened budget makes `launch` report truncated searches for
 * applications that are really there - which is the entire point of the key
 * (proc68.h), and indistinguishable from a broken `launch` if the value is
 * not stated anywhere. So it goes in the console, where a human already
 * reads, AND in the log, which is what gets quoted back after the fact. The
 * default is printed beside it because "1s" only reads as alarming next to
 * the twenty it replaced. */
static void dev_settings_apply_launch_search(void)
{
    /* 96, not the 64 the other note uses: this sentence is ~72 characters
     * with a three-digit budget, and a console line that silently fails to
     * format is exactly the announcement this function exists to make. The
     * console pane is 496 px of Monaco 9 (~80 characters), so it fits on
     * screen too - a line that formats and then draws off the right edge
     * would be the same failure one step later. */
    char text[96];
    long pos = 0;

    if (!gDev.have_launch_search_secs) {
        return;   /* absent: the compiled-in budget, silently, as shipped */
    }

    proc_set_launch_search_seconds(gDev.launch_search_secs);

    /* proc_launch_search_seconds(), not gDev.launch_search_secs: this line
     * must report what is IN FORCE, not what the file asked for. They agree
     * today; if a future bound made them disagree, the honest number is the
     * one the search will actually use. */
    if (now68k_fmt_append_str(text, (long)sizeof text, &pos,
                              "dev settings: launch search ")
        && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                  (long)proc_launch_search_seconds())
        && now68k_fmt_append_str(text, (long)sizeof text, &pos, "s not ")
        && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                  (long)kN68DevLaunchSearchDefaultSecs)
        && now68k_fmt_append_str(text, (long)sizeof text, &pos,
                                 "s - launch may say truncated")
        && pos < (long)sizeof text) {
        text[pos] = '\0';
        console_note(text);
    }
    now68k_log_num("devsettings: launch search seconds",
                    (long)proc_launch_search_seconds());
}

static void dev_settings_apply_wire(void)
{
    if (!gDevLoaded) {
        return;
    }

    dev_settings_apply_launch_search();

    if (gDev.have_retry || gDev.have_retry_secs) {
        short on = gDev.have_retry
                     ? (short)(gDev.retry_on != 0)
                     : (short)(gRetryChk != NULL ? GetControlValue(gRetryChk) : 0);

        if (gRetryChk != NULL) {
            SetControlValue(gRetryChk, on);
        }
        if (gRetrySecs != kN68DevRetryDefaultSecs) {
            set_retry_title(gRetrySecs);
        }
        wire_set_retry(on, gRetrySecs);
    }

    /* One console line saying what the file did, always - including "0
     * applied, 3 line(s) ignored", which is the sentence a human needs when
     * they mistyped a key and are about to blame the build. */
    console_note_dev_settings();
    now68k_log_num("devsettings: keys applied", (long)gDev.keys_set);
    if (gDev.bad_lines != 0) {
        now68k_log_num("devsettings: first ignored line",
                        (long)gDev.first_bad_line);
    }

    if (gDev.have_autoconnect && gDev.autoconnect) {
        /* Exactly what a Connect click does, gated on exactly the same
         * validation - autoconnect must not be a second, laxer path to the
         * wire. If the file gave no host, the fields are in their no-file
         * state and this refuses for the same reason a click would. */
        if (gHostResult.ok && gPortResult.ok && gTimeoutResult.ok) {
            wire_set_target(gHostResult.addr, gPortResult.port,
                             (unsigned short)gTimeoutResult.seconds);
            wire_start();
            console_note("autoconnect: connecting");
        } else {
            console_note("autoconnect skipped: check field(s) above");
        }
    }
}

/* ---- public seam (window.h) -------------------------------------------- */

void window_init(void)
{
    Rect bounds, dest, view, connectR, retryR;

    SetRect(&bounds, kWinLeft, kWinTop, kWinLeft + kWinWidth, kWinTop + kWinHeight);

    /* noGrowDocProc, not documentProc: documentProc reserves a grow box we
     * neither draw nor handle, and a control that is drawn but inert reads
     * as a bug. The page is fixed-size by design. */
    gWindow = NewCWindow(NULL, &bounds, PSTR("\pNOW-68K"), true, noGrowDocProc,
                         (WindowPtr)-1L, true, 0);
    if (gWindow == NULL) {
        now68k_log("window: NewCWindow failed");
        return;
    }
    SetPort(gWindow);
    gActive = true;

    SetRect(&gHostFieldRect,     kFieldX,  kHostTop,    kHostFieldR,    kHostBot);
    SetRect(&gHostReasonRect,    kReasonX, kHostTop,    kRightEdge,     kHostBot);
    SetRect(&gPortFieldRect,     kFieldX,  kPortTop,    kPortFieldR,    kPortBot);
    SetRect(&gPortReasonRect,    kReasonX, kPortTop,    kRightEdge,     kPortBot);
    SetRect(&gTimeoutFieldRect,  kFieldX,  kTimeoutTop, kTimeoutFieldR, kTimeoutBot);
    SetRect(&gTimeoutReasonRect, kReasonX, kTimeoutTop, kRightEdge,     kTimeoutBot);
    SetRect(&gStatusRect,  kMargin, kStatusTop,  kRightEdge, kStatusBot);
    SetRect(&gHealthRect,  kMargin, kHealthTop,  kRightEdge, kHealthBot);
    SetRect(&gConsoleRect, kMargin, kConsoleTop, kRightEdge, kConsoleBot);

    /* DEFECT 16 (fixed): TENew used to run here with whatever the port's
     * txFont/txSize happened to be - on a freshly made port that is
     * txFont=0 (Chicago) and txSize=0 (12pt), and TENew captures that pair
     * into the TERec permanently; TEUpdate/TESetText draw with the TERec's
     * own font, not whatever draw_page sets later. Field height 18 minus
     * InsetRect(3,3) leaves a 12px view, and Chicago 12's line height is
     * ~16px - the typed text was clipped top and bottom. Set the port's
     * font/size to what this page actually uses BEFORE TENew, so every
     * TERec is born with the right metrics. */
    TextFont(kFontIDGeneva);
    TextSize(9);

    /* Single-line fields: destRect far wider than viewRect so TE never
     * word-wraps (there is no second line to wrap into), and TESelView
     * after every edit keeps the caret in view - the standard classic-Mac
     * "one-line scrolling field" recipe (Inside Macintosh: Text). */
    view = gHostFieldRect;    InsetRect(&view, 3, 3); dest = view; dest.right = (short)(dest.left + 2000);
    gHostTE = TENew(&dest, &view);
    view = gPortFieldRect;    InsetRect(&view, 3, 3); dest = view; dest.right = (short)(dest.left + 2000);
    gPortTE = TENew(&dest, &view);
    view = gTimeoutFieldRect; InsetRect(&view, 3, 3); dest = view; dest.right = (short)(dest.left + 2000);
    gTimeoutTE = TENew(&dest, &view);

    if (gHostTE == NULL || gPortTE == NULL || gTimeoutTE == NULL) {
        /* Continue rather than bail: the rest of the panel and the wire
         * are still usable even if a field editor failed to allocate under
         * memory pressure - a dead field reads as inert, not a crash. */
        now68k_log("window: TENew failed for one or more fields");
    }

    /* Port/Timeout start at the project's documented UI defaults
     * (connfields.h: kNowDefaultHostPort, kConnTimeoutDefaultSecs - "a UI
     * default for this field, not a validation bound"). Host stays blank:
     * there is no sensible universal default address, and there are no
     * saved preferences in this pass by deliberate design - the human
     * retypes it every launch. */
    if (gPortTE != NULL) {
        TESetText(kDefaultPortText, (long)(sizeof(kDefaultPortText) - 1), gPortTE);
    }
    if (gTimeoutTE != NULL) {
        TESetText(kDefaultTimeoutText, (long)(sizeof(kDefaultTimeoutText) - 1),
                   gTimeoutTE);
    }
    if (gHostTE != NULL) {
        TEActivate(gHostTE);
    }

    SetRect(&connectR, kMargin, kCtlTop, kConnectBtnR, kCtlBot);
    SetRect(&retryR, kRetryChkX, kCtlTop, kRetryChkR, kCtlBot);
    gConnectBtn = NewControl(gWindow, &connectR, PSTR("\pConnect"), true,
                              0, 0, 1, kPushButProcID, 0);
    gRetryChk = NewControl(gWindow, &retryR, PSTR("\pRetry every 5s"), true,
                            0, 0, 1, kCheckBoxProcID, 0);
    if (gConnectBtn == NULL || gRetryChk == NULL) {
        now68k_log("window: NewControl failed for one or more controls");
    }

    gPumpActionUPP = NewControlActionUPP(pump_action_proc);
    if (gPumpActionUPP == NULL) {
        now68k_log("window: pump action UPP allocation failed");
    }

    n68_console_init(&gConsole);

    /* DEFECT 13 (fixed): health.c/health.h existed with zero callers. Once,
     * here, before the panel first draws - health_init() reads Gestalt and
     * the main GDevice, none of which changes for the life of a run (see
     * health.h), so re-running it from draw_health would be pure jank. */
    health_init();

    /* Before the first revalidate, so the fields validate what the file
     * actually put in them. No file = no change to anything above. */
    dev_settings_apply_fields();

    revalidate_host();
    revalidate_port();
    revalidate_timeout();

    /* wire_init() belongs here, not main.c: this module owns the human-
     * triggered wire lifecycle (Connect/Disconnect/Retry), so it is the
     * natural "once at startup, before any connection work" call site
     * wire68.h asks for - main.c never touches net.h/wire68.h directly. */
    wire_init();

    /* After wire_init, which resets retry state - and before the status
     * snapshot below, so an autoconnected dial is the first state this
     * window ever shows rather than a stale "Not connected". */
    dev_settings_apply_wire();

    gWireStateShown = wire_state();
    update_connect_button(gWireStateShown);
    copy_bounded(gStatusShown, wire_status(), sizeof gStatusShown);
}

void window_dispose(void)
{
    wire_stop();   /* release any live MacTCP stream before the app exits */

    if (gPumpActionUPP != NULL) {
        DisposeControlActionUPP(gPumpActionUPP);
        gPumpActionUPP = NULL;
    }
    if (gHostTE != NULL) {
        TEDispose(gHostTE);
        gHostTE = NULL;
    }
    if (gPortTE != NULL) {
        TEDispose(gPortTE);
        gPortTE = NULL;
    }
    if (gTimeoutTE != NULL) {
        TEDispose(gTimeoutTE);
        gTimeoutTE = NULL;
    }
    /* gConnectBtn/gRetryChk are owned by the window and freed with it -
     * no separate DisposeControl call. */
    if (gWindow != NULL) {
        DisposeWindow(gWindow);
        gWindow = NULL;
    }
}

void window_handle_event(EventRecord *event)
{
    WindowPtr w;
    GrafPtr   save;

    if (gWindow == NULL) {
        return;
    }

    switch (event->what) {
    case updateEvt:
        /* The one painting owner. Nothing else in this file draws outside
         * this bracket - see draw_page's own comment. */
        w = (WindowPtr)event->message;
        GetPort(&save);
        SetPort(w);
        BeginUpdate(w);
        draw_page();
        EndUpdate(w);
        SetPort(save);
        break;

    case activateEvt:
        w = (WindowPtr)event->message;
        if (w == gWindow) {
            Boolean newActive = (event->modifiers & activeFlag) != 0;
            if (newActive != gActive) {
                gActive = newActive;
                /* Nothing this file draws depends visually on gActive: no
                 * Appearance Manager here means controls do not dim, and
                 * the only thing that does change appearance - the
                 * focused field's caret/selection highlight - is TEActivate
                 * / TEDeactivate's own immediate redraw, not ours. So
                 * there is no InvalRect here; the placeholder shell's
                 * whole-portRect invalidate existed only for its own
                 * debug "active"/"inactive" text, which this panel does
                 * not draw. */
                GetPort(&save);
                SetPort(gWindow);
                if (gActive) {
                    TEActivate(field_te(gFocus));
                } else {
                    TEDeactivate(field_te(gFocus));
                }
                SetPort(save);
            }
        }
        break;

    case osEvt:
        /* Suspend/resume arrives here (high byte of message = 0x01). */
        if (((event->message >> 24) & 0xFF) == suspendResumeMessage) {
            Boolean newActive = (event->message & resumeFlag) != 0;
            if (newActive != gActive) {
                gActive = newActive;
                GetPort(&save);
                SetPort(gWindow);
                if (gActive) {
                    TEActivate(field_te(gFocus));
                } else {
                    TEDeactivate(field_te(gFocus));
                }
                SetPort(save);
            }
        }
        break;

    case mouseDown:
    {
        Point         pt;
        ControlHandle ctl;
        short         part;

        GetPort(&save);
        SetPort(gWindow);
        pt = event->where;
        GlobalToLocal(&pt);

        part = FindControl(pt, gWindow, &ctl);
        if (part != 0 && ctl == gConnectBtn) {
            /* TrackControl's action proc pumps the wire for as long as the
             * mouse stays down - a NULL proc here is exactly the deadlock
             * window.h's transport-pass note warns about. */
            if (gPumpActionUPP != NULL
                && TrackControl(ctl, pt, gPumpActionUPP) != 0) {
                handle_connect_toggle();
            }
        } else if (part != 0 && ctl == gRetryChk) {
            if (gPumpActionUPP != NULL
                && TrackControl(ctl, pt, gPumpActionUPP) != 0) {
                toggle_retry();
            }
        } else if (gHostTE != NULL && PtInRect(pt, &gHostFieldRect)) {
            set_focus(kFocusHost);
            TEClick(pt, (event->modifiers & shiftKey) != 0, gHostTE);
            TESelView(gHostTE);
        } else if (gPortTE != NULL && PtInRect(pt, &gPortFieldRect)) {
            set_focus(kFocusPort);
            TEClick(pt, (event->modifiers & shiftKey) != 0, gPortTE);
            TESelView(gPortTE);
        } else if (gTimeoutTE != NULL && PtInRect(pt, &gTimeoutFieldRect)) {
            set_focus(kFocusTimeout);
            TEClick(pt, (event->modifiers & shiftKey) != 0, gTimeoutTE);
            TESelView(gTimeoutTE);
        }
        /* Note for the record, not a bug to fix here: like DragWindow and
         * GrowWindow (pump.h's un-pumpable list), classic TEClick's own
         * drag-to-select loop takes no callback either, so a held-down
         * text selection also stalls the wire briefly. It is bounded by
         * how long a human holds the mouse down inside a short field, the
         * same shape the un-pumpable list already accepts. */
        SetPort(save);
        break;
    }

    case keyDown:
    case autoKey:
    {
        char c = (char)(event->message & charCodeMask);

        /* DEFECT 8 (fixed): this used to SetPort(gWindow) only around the
         * TEKey branch, and even there restored the saved port BEFORE
         * calling revalidate_focused() - which calls InvalRect on whatever
         * port happened to be current at that moment. The Tab and Return/
         * Enter branches set no port at all before cycle_focus/set_focus
         * (InvalRect, TEActivate/TEDeactivate) and handle_connect_toggle
         * (console_note -> InvalRect). InvalRect writes into
         * WindowPeek(thePort)->updateRgn - whatever port is current, not
         * necessarily gWindow, once anything else (a desk accessory from
         * the Apple menu) has changed the current port. One bracket around
         * the whole switch body fixes every branch at once. */
        GetPort(&save);
        SetPort(gWindow);
        if (c == kTabCharCode) {
            cycle_focus((event->modifiers & shiftKey) != 0);
        } else if (c == kReturnCharCode || c == kEnterCharCode) {
            handle_connect_toggle();
        } else if (field_te(gFocus) != NULL) {
            TEKey((CharParameter)c, field_te(gFocus));
            TESelView(field_te(gFocus));
            revalidate_focused();
        }
        SetPort(save);
        break;
    }

    default:
        break;
    }
}

void window_idle(void)
{
    const char *status;
    WireState   st;
    GrafPtr     save;

    if (gWindow == NULL) {
        return;
    }

    wire_idle();

    /* DEFECT 8 (fixed): only the TEIdle call below used to be bracketed;
     * everything after it - InvalRect(&gStatusRect), console_note's own
     * InvalRect, and update_connect_button's SetControlTitle (which draws
     * immediately) - ran under whatever port happened to be current. One
     * bracket around the whole idle body instead of a per-call one. */
    GetPort(&save);
    SetPort(gWindow);

    if (field_te(gFocus) != NULL) {
        TEIdle(field_te(gFocus));   /* caret blink - the standard TE idiom
                                        for this, not "our" redraw */
    }

    status = wire_status();
    {
        /* DEFECT 2 (fixed): compare the copy actually stored (truncated to
         * kStatusShownCap) against a freshly truncated copy of the current
         * status, never the truncated copy against the raw untruncated
         * source - see kStatusShownCap's comment for why that comparison
         * could never converge once a status exceeded the old cap. */
        char truncated[kStatusShownCap];

        copy_bounded(truncated, status, sizeof truncated);
        if (strcmp(truncated, gStatusShown) != 0) {
            memcpy(gStatusShown, truncated, sizeof truncated);
            InvalRect(&gStatusRect);
            console_note(status);   /* wire_status() is documented as "the
                                        human-facing summary of whatever
                                        just happened" - exactly what the
                                        console's scrollback history should
                                        record */
        }
    }

    st = wire_state();
    if (st != gWireStateShown) {
        gWireStateShown = st;
        update_connect_button(st);
    }

    /* No idle-driven InvalRect(&gHealthRect) here on purpose: gHealthRect
     * now shows health.h's readout (DEFECT 13), and health_sample_dynamic()
     * is documented as cheap-but-not-free - it is called from draw_health,
     * which only runs inside BeginUpdate/EndUpdate, so the dynamic facts
     * refresh whenever the panel repaints for any reason and never cost
     * anything on a pass where nothing else changed. */

    SetPort(save);
}

void window_show_about(void)
{
    /* Placeholder until the About box exists; logging it keeps the menu
     * item honest rather than silently inert. window_show_about "exists
     * and may stay a log line" per this deliverable's brief. */
    now68k_log("window: about requested");
}
