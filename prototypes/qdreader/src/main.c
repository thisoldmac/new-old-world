/*
 * QD Reader - the throwaway Carbon application that reads (and arms) QD
 * Probe's shared block.
 *
 * NOT a NOW component, and deliberately not inside the NOW guest: the
 * probe it talks to is the P3 spike, whose whole charter is to be a
 * separate failure domain from the shipping extension. A reader living
 * in NOW would couple the product to the spike it is insulated from. So
 * this has its own file name, its own creator ('QDrd'), and is deleted
 * when the probe is. See README.md.
 *
 * WHY CARBON/PPC RATHER THAN 68K. The probe exists to answer one
 * question: can a NATIVE POWERPC caller reach a bare 68K bottleneck
 * pointer? A 68K reader could display the counters but could only ever
 * make 68K QuickDraw calls, so its own drawing would answer a question
 * nobody asked. Built Carbon/PPC and armed at itself, this application
 * IS the experiment: the rectangles it draws are drawn by native
 * PowerPC QuickDraw under CarbonLib, and rect_calls moving is the
 * answer rather than a report of somebody else's answer.
 *
 * WHAT IT TARGETS. Arming is keyed on A5, and the honest answer to
 * "where does a small application get an A5" is:
 *
 *   - Its own: read in its own context, at the moment it arms. This is
 *     the default and the only self-sufficient mode.
 *   - A foreign one: TYPED IN as hex, obtained out of band (NOW's
 *     anchor plane, AXPeek). Nothing in this application can enumerate
 *     another process's A5, and it does not pretend to - reading low
 *     memory in OUR context yields OUR A5 and never theirs. Enumerating
 *     other processes' anchors is NOW's plane, and reaching for it here
 *     would be exactly the coupling this file exists to avoid.
 *
 * ON LMGetCurrentA5(). We cannot call it: this toolchain's LowMem.h
 * marks it CALL_NOT_IN_CARBON ("CarbonLib: not available"), so a Carbon
 * build has no such entry point. We read low memory 0x904 directly
 * instead, which is what that accessor's inline is (0x2EB8 0x0904 =
 * MOVEA.L $0904,A7-pushed), and which is the same class of fixed-address
 * read spikes/census-metal already performs on OS 9. It is valid for
 * OUR OWN context only, and only on classic Mac OS; this application is
 * classic-only by construction. It is never valid as a way to learn a
 * FOREIGN process's A5, which is why the foreign path is typed.
 */

#include <Carbon.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* --- the probe's block, copied ------------------------------------------
 *
 * This is QD Probe's QDProbeShared at version 2, transcribed. A copy of
 * a resident layout is only ever as good as the check that the resident
 * layout is the one copied - which is what gate() is for, and why every
 * field below the first two is unreadable until it passes.
 */

#define QDPROBE_4CC(a, b, c, d)                                       \
    (((unsigned long)(a) << 24) | ((unsigned long)(b) << 16)          \
     | ((unsigned long)(c) << 8) | (unsigned long)(d))

enum {
    kQDProbeGestalt = (long)QDPROBE_4CC('Q', 'D', 'p', 'r'),
    kQDProbeMagic = (long)QDPROBE_4CC('Q', 'D', 'p', 'r'),
    kQDProbeVersion = 2
};

typedef struct {
    unsigned long magic;
    unsigned long version;
    unsigned long heartbeat;
    unsigned long arm;            /* ours (commit word) */
    unsigned long arm_a5;         /* ours */
    unsigned long arm_expiry;     /* ours */
    unsigned long armed_ports;
    unsigned long rect_calls;     /* THE ANSWER */
    unsigned long patches;
    unsigned long restores;
    unsigned long skipped;
    unsigned long stranded;
    unsigned long unscoped;
    unsigned long foreign;
    unsigned long expiries;
} QDProbeShared;

/* volatile: the commit order below is a protocol, not an optimisation
   opportunity. A jGNE pass can land between any two of our stores, so
   the compiler must not reorder or coalesce them. (One CPU, one
   resident reader - ordering is all we need; there is no barrier to
   issue.) */
static volatile QDProbeShared *g_block;

enum {
    kGateAbsent,          /* Gestalt says no probe */
    kGateBadPointer,      /* Gestalt answered with something unusable */
    kGateNotProbe,        /* magic mismatch */
    kGateStale,           /* version < 2: an old INIT is resident */
    kGateNewer,           /* version > 2 (or wild): we are the old one */
    kGateOK
};
static int g_gate = kGateAbsent;
static unsigned long g_seen_magic;
static unsigned long g_seen_version;

/* --- window and log ----------------------------------------------------- */

enum {
    kWinWidth = 520,
    kWinHeight = 400,
    kLineHeight = 12,
    kFirstLine = 16,
    kMaxLines = 26,
    kNoteLines = 4,
    /* A request's life. Short on purpose: the dead-man's switch is what
       retires a request if this application dies mid-experiment, and a
       long deadline is a long window in which a recycled A5 could be
       mistaken for the target. Re-arm rather than raise this. */
    kArmTicks = 1800          /* 30 s */
};

static WindowRef g_window;
static char g_lines[kMaxLines][80];
static int g_count;
static char g_notes[kNoteLines][80];
static int g_note_count;
static unsigned long g_typed;     /* hex being typed for a foreign A5 */
static int g_typed_digits;
static Rect g_test_rect;

static void line(const char *fmt, ...)
{
    va_list args;

    if (g_count >= kMaxLines) {
        return;
    }
    va_start(args, fmt);
    vsnprintf(g_lines[g_count], sizeof g_lines[0], fmt, args);
    va_end(args);
    ++g_count;
}

/* Newest note first; four of them, so a refusal stays on screen long
   enough to read but never scrolls the panel away. */
static void note(const char *fmt, ...)
{
    va_list args;
    int i;

    for (i = kNoteLines - 1; i > 0; --i) {
        memcpy(g_notes[i], g_notes[i - 1], sizeof g_notes[0]);
    }
    va_start(args, fmt);
    vsnprintf(g_notes[0], sizeof g_notes[0], fmt, args);
    va_end(args);
    if (g_note_count < kNoteLines) {
        ++g_note_count;
    }
}

/* --- the gate ------------------------------------------------------------
 *
 * magic AND version, as ONE check. Matching the magic alone confirms we
 * found a QD Probe, not that we found one whose block we understand -
 * and the two failures are not the same instruction:
 *
 *   version < 2  a STALE INIT is resident. The answer is a COLD BOOT,
 *                not a proceed. Writing our v2 request into a v1 block
 *                would put arm_a5 where armed_ports lives and
 *                arm_expiry where rect_calls lives, and then set arm -
 *                and a v1 probe seeing a bare arm patches EVERY port it
 *                meets, silently, while we believe we named one target.
 *                (v1 did carry a version word; a block with no version
 *                word at all reads as garbage here and lands in
 *                kGateNewer, which refuses just as hard.)
 *   version > 2  we are older than what is installed. Rebuild the
 *                reader; do not write.
 *
 * Every write path asks armed() first, so a failed gate means this
 * application can only ever display two words: the magic and the
 * version it actually found.
 */
static void gate(void)
{
    long response = 0;
    QDProbeShared *block;

    g_block = NULL;
    g_seen_magic = 0;
    g_seen_version = 0;

    if (Gestalt((OSType)kQDProbeGestalt, &response) != noErr) {
        g_gate = kGateAbsent;
        return;
    }
    block = (QDProbeShared *)response;
    /* An odd or null pointer is not a block. Cheap, and the difference
       between a diagnosis and a bus error. */
    if (block == NULL || ((unsigned long)block & 1UL) != 0) {
        g_gate = kGateBadPointer;
        return;
    }
    g_seen_magic = block->magic;
    g_seen_version = block->version;
    if (g_seen_magic != (unsigned long)kQDProbeMagic) {
        g_gate = kGateNotProbe;
        return;
    }
    if (g_seen_version < (unsigned long)kQDProbeVersion) {
        g_gate = kGateStale;
        return;
    }
    if (g_seen_version > (unsigned long)kQDProbeVersion) {
        g_gate = kGateNewer;
        return;
    }
    g_block = (volatile QDProbeShared *)block;
    g_gate = kGateOK;
}

static Boolean usable(void)
{
    return (Boolean)(g_gate == kGateOK && g_block != NULL);
}

/* --- A5 ----------------------------------------------------------------- */

/* OUR OWN A5, read in OUR OWN context. See the header: CarbonLib does
   not export LMGetCurrentA5, so this is that accessor's inline done by
   hand. Never a foreign process's A5 - there is no context in which
   this read means somebody else. */
/* The address is held in a volatile variable rather than written as a
   literal because GCC 14 rejects a dereference of a constant low address
   outright (-Werror=array-bounds: "source object is likely at address
   zero"). That diagnostic is right about ordinary C and wrong about this
   machine; routing the address through a volatile is the narrow way to
   say "I mean this address" without switching the warning off for the
   whole file. */
static volatile unsigned long g_a5_lowmem = 0x904UL;

static unsigned long own_a5(void)
{
    volatile unsigned long *p = (volatile unsigned long *)g_a5_lowmem;

    return *p;
}

/* --- the commit protocol ------------------------------------------------
 *
 *   to arm:    arm_a5 and arm_expiry FIRST, then arm LAST
 *   to disarm: arm FIRST
 *
 * A jGNE pass can land between any two stores. That order is the only
 * thing that stops a live `arm` from ever pairing with the previous
 * request's target, and it is not optional.
 */
static void arm_at(unsigned long a5, const char *what)
{
    unsigned long expiry;

    if (!usable()) {
        note("refused: no usable block (see the gate above)");
        return;
    }
    /* Arming with no target does nothing, deliberately. The probe would
       refuse this itself and count it as `unscoped` - we refuse it here
       too so that a typo does not have to travel to the resident code to
       be caught. */
    if (a5 == 0) {
        note("refused: arm with no target names nothing");
        return;
    }
    /* An A5 is a pointer; an odd one is a typo, not a target. */
    if ((a5 & 1UL) != 0) {
        note("refused: A5 %08lX is odd - typo?", a5);
        return;
    }
    expiry = (unsigned long)TickCount() + (unsigned long)kArmTicks;
    if (expiry == 0) {
        expiry = 1;               /* 0 means "expired on sight" */
    }
    g_block->arm_a5 = a5;
    g_block->arm_expiry = expiry;
    g_block->arm = 1;             /* commit, last */
    note("armed %s A5 %08lX for %d ticks", what, a5, (int)kArmTicks);
}

static void disarm(void)
{
    if (!usable()) {
        note("refused: no usable block (see the gate above)");
        return;
    }
    g_block->arm = 0;             /* commit word first */
    /* arm_a5 / arm_expiry are left alone on purpose: they are inert
       without `arm`, and the next arm rewrites both before setting it
       again. Clearing them here would be a second store racing the pass
       that is about to restore our ports. */
    note("disarmed - ports come back when the target next pumps");
}

/* --- the panel ----------------------------------------------------------- */

static const char *gate_word(void)
{
    switch (g_gate) {
    case kGateAbsent:     return "NOT INSTALLED";
    case kGateBadPointer: return "BAD POINTER";
    case kGateNotProbe:   return "NOT A QD PROBE";
    case kGateStale:      return "STALE INIT - COLD BOOT";
    case kGateNewer:      return "READER TOO OLD";
    default:              return "ok";
    }
}

static void build_panel(void)
{
    unsigned long now = (unsigned long)TickCount();
    unsigned long age;

    g_count = 0;
    line("QD Reader - throwaway, deleted with the probe");
    line("");

    switch (g_gate) {
    case kGateAbsent:
        line("Gestalt 'QDpr': %s", gate_word());
        line("");
        line("Either the INIT is not in Extensions, or it did not load.");
        line("INITs load at boot only - install and COLD boot.");
        break;
    case kGateBadPointer:
        line("Gestalt 'QDpr': %s", gate_word());
        line("");
        line("The selector answered with something that is not a block.");
        break;
    case kGateNotProbe:
        line("Gestalt 'QDpr': %s", gate_word());
        line("");
        line("magic   %08lX   (want %08lX)", g_seen_magic,
             (unsigned long)kQDProbeMagic);
        line("Something else owns this selector. Nothing read, nothing");
        line("written - every other field would be a guess.");
        break;
    case kGateStale:
    case kGateNewer:
        line("Gestalt 'QDpr': %s", gate_word());
        line("");
        line("magic   %08lX  ok", g_seen_magic);
        line("version %lu   (this reader speaks %d, EXACTLY)",
             g_seen_version, (int)kQDProbeVersion);
        line("");
        if (g_gate == kGateStale) {
            line("A stale INIT is resident. COLD BOOT - do not proceed.");
            line("Our v%d request written into a v%lu block would land",
                 (int)kQDProbeVersion, g_seen_version);
            line("arm_a5 on armed_ports and arm_expiry on rect_calls,");
            line("then set arm - and a v1 probe with a bare arm patches");
            line("EVERY port it meets, while we believe we named one.");
        } else {
            line("The resident probe is newer than this reader. Rebuild");
            line("the reader. Reading past `version` would be a guess at");
            line("a layout we do not have.");
        }
        line("");
        line("No counter below is shown, and no write is possible.");
        break;
    default:
        break;
    }

    if (!usable()) {
        line("");
        line("G rescan   Q quit");
        return;
    }

    age = now - g_block->heartbeat;
    line("Gestalt 'QDpr'  magic ok  version %lu  ok", g_seen_version);
    line("heartbeat %lu  (%lu ticks ago - %s)", g_block->heartbeat, age,
         age <= 30UL ? "running" : "STALLED: loaded but not pumping");
    line("");
    line("rect_calls %lu   <- THE ANSWER: nonzero means a native PPC",
         g_block->rect_calls);
    line("                    caller reached a bare 68K bottleneck");
    line("");
    line("arm %lu   arm_a5 %08lX   arm_expiry %lu",
         g_block->arm, g_block->arm_a5, g_block->arm_expiry);
    line("armed_ports %lu   patches %lu   restores %lu",
         g_block->armed_ports, g_block->patches, g_block->restores);
    line("skipped %lu   stranded %lu",
         g_block->skipped, g_block->stranded);
    line("refusals: unscoped %lu   foreign %lu   expiries %lu",
         g_block->unscoped, g_block->foreign, g_block->expiries);
    line("  (unscoped/foreign climb once per pass while a bad request");
    line("   stands - a misaddressed arm is loud, not silent)");
    line("");
    line("our A5 %08lX      typed %08lX (%d digits)",
         own_a5(), g_typed, g_typed_digits);
    line("");
    line("S arm self   0-9 A-F type   F arm typed   X clear typed");
    line("D disarm     T test rect    G rescan      Q quit");
}

/* Pad to a fixed width so a shorter line overwrites the longer one it
   replaces - see draw(): we cannot rely on erasing. Done by hand rather
   than with "%-70s", which GCC cannot prove fits. */
enum { kPadWidth = 70 };

static void draw_padded(const char *s, int y)
{
    Str255 text;
    size_t n = strlen(s);
    size_t i;

    if (n > (size_t)kPadWidth) {
        n = (size_t)kPadWidth;
    }
    text[0] = (unsigned char)kPadWidth;
    memcpy(text + 1, s, n);
    for (i = n; i < (size_t)kPadWidth; ++i) {
        text[1 + i] = ' ';
    }
    MoveTo(12, y);
    DrawString(text);
}

static void draw(void)
{
    int i;
    int y;

    SetPortWindowPort(g_window);
    /* NOT EraseRect. While a port of ours is patched, the probe's proc
       finds saved_procs == 0 (it only ever patches ports whose grafProcs
       was NULL) and draws nothing at all - so every rect operation in
       this window, erases included, silently does nothing. That is the
       expected visible signature, not a bug in this file; see README.
       srcCopy text overwrites its own background, so the panel stays
       legible either way. */
    TextMode(srcCopy);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    y = kFirstLine;
    for (i = 0; i < g_count; ++i) {
        draw_padded(g_lines[i], y);
        y += kLineHeight;
    }
    y += 4;
    for (i = 0; i < g_note_count; ++i) {
        draw_padded(g_notes[i], y);
        y += kLineHeight;
    }
}

/* The experiment itself: rectangles drawn by native PowerPC QuickDraw.
   With a request armed at our own A5 and our window's port patched,
   rect_calls must climb - and these rectangles must VANISH, because the
   probe's proc has no saved chain to tail-call. Both together are the
   answer; either alone is worth reporting. */
static void test_rect(void)
{
    SetPortWindowPort(g_window);
    PenSize(2, 2);
    FrameRect(&g_test_rect);
    PenSize(1, 1);
    note("drew a test rect (gone = our proc ran and had no chain)");
}

static void key(char c)
{
    if (c >= 'a' && c <= 'z') {
        c = (char)(c - 'a' + 'A');
    }
    if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
        int v = (c <= '9') ? (c - '0') : (c - 'A' + 10);

        if (g_typed_digits < 8) {
            g_typed = (g_typed << 4) | (unsigned long)v;
            ++g_typed_digits;
        }
        return;
    }
    switch (c) {
    case 'S':
        arm_at(own_a5(), "self (this application)");
        break;
    case 'X':
        g_typed = 0;
        g_typed_digits = 0;
        break;
    case 'D':
        disarm();
        break;
    case 'T':
        test_rect();
        break;
    case 'G':
        gate();
        note("rescanned Gestalt: %s", gate_word());
        break;
    default:
        break;
    }
}

/* 'F' is handled here rather than in key() only because it collides
   with the hex digit F. A typed A5 is committed by RETURN, which no
   digit can be. */
static void commit_typed(void)
{
    if (g_typed_digits == 0) {
        note("refused: nothing typed - a bare arm names nothing");
        return;
    }
    arm_at(g_typed, "typed (foreign)");
}

/* Disarm, then keep pumping until the probe has actually restored our
   ports. Quitting with our port still patched leaves an entry pointing
   into a heap that is about to go away - the leaked-entry case the probe
   accepts on purpose, and the one thing this application can do to not
   cause it. Bounded, because the guarantee does not exist: if it does
   not come back, say so rather than hang. */
static void drain(void)
{
    unsigned long deadline;
    EventRecord event;

    if (!usable()) {
        return;
    }
    disarm();
    deadline = (unsigned long)TickCount() + 180UL;
    while (g_block->armed_ports != 0) {
        if ((long)((unsigned long)TickCount() - deadline) >= 0) {
            note("WARNING: %lu port(s) still patched at quit",
                 g_block->armed_ports);
            return;
        }
        WaitNextEvent(everyEvent, &event, 2, NULL);
        SetPortWindowPort(g_window);
    }
}

int main(void)
{
    EventRecord event;
    Rect bounds;
    Str255 title;
    Boolean running = true;

    InitCursor();
    SetRect(&bounds, 30, 50, 30 + kWinWidth, 50 + kWinHeight);
    CreateNewWindow(kDocumentWindowClass, kWindowCloseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return 1;
    }
    CopyCStringToPascal("QD Reader", title);
    SetWTitle(g_window, title);
    ShowWindow(g_window);
    SelectWindow(g_window);
    SetPortWindowPort(g_window);
    SetRect(&g_test_rect, kWinWidth - 90, kWinHeight - 60,
            kWinWidth - 20, kWinHeight - 20);

    gate();
    note("%s", gate_word());

    while (running) {
        if (WaitNextEvent(everyEvent, &event, 10, NULL)) {
            switch (event.what) {
            case updateEvt:
                BeginUpdate(g_window);
                build_panel();
                draw();
                EndUpdate(g_window);
                break;
            case keyDown:
            case autoKey: {
                char c = (char)(event.message & charCodeMask);

                if (c == '\r' || c == 3) {
                    commit_typed();
                } else if (c == 8) {
                    g_typed = 0;
                    g_typed_digits = 0;
                } else if (c == 'q' || c == 'Q') {
                    running = false;
                } else {
                    key(c);
                }
                break;
            }
            case mouseDown: {
                WindowRef which;
                short part = FindWindow(event.where, &which);

                if (part == inGoAway && TrackGoAway(which, event.where)) {
                    running = false;
                } else if (part == inDrag) {
                    DragWindow(which, event.where, NULL);
                }
                break;
            }
            default:
                break;
            }
        }
        /* Keep OUR window's port current. The probe patches whatever
           port is current on the pass in which it sees our A5, so the
           port under test is only our window's if we leave it set. */
        SetPortWindowPort(g_window);
        build_panel();
        draw();
    }

    drain();
    return 0;
}
