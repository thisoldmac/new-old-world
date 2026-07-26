/*
 * proc68.c - implements proc68.h: list, quit-by-name, launch-by-name.
 *
 * Process Manager, Apple Event Manager and File Manager only. No
 * allocation (fixed, budgeted buffers throughout - see each one's size
 * comment), no printf family (this file's own append_ascii/set_detail,
 * not numfmt.h - the sentences built here always carry a name that must
 * be sanitized on the way in, which numfmt.h's plain now68k_fmt_append_str
 * does not do; see set_detail's comment), ASCII only on every string that
 * reaches the wire or the console - enforced, not just intended, per
 * DEFECT 9 below.
 *
 * proc_quit_args.{c,h} (copied from the PowerPC guest, see that file's
 * header) are NOT called from here. proc68.h's proc_quit_named already
 * takes a parsed name and a wait_ticks count, not a raw argument line -
 * there is no string left to parse by the time this file sees the call.
 * The parser is copied into proc/ so the future command dispatcher (which
 * turns a console line or a command.request's JSON into these arguments)
 * has it available without re-deriving the grammar; wiring it up is that
 * dispatcher's job, not this file's. See the deliverable report for the
 * full reasoning - this is flagged there rather than silently worked
 * around by inventing a second, undeclared entry point into this file.
 */
#include "proc68.h"

#include <AEDataModel.h>
#include <AEInteraction.h>
#include <AppleEvents.h>
#include <Events.h>
#include <Files.h>
#include <LowMem.h>
#include <OSUtils.h>
#include <StringCompare.h>
#include <TextUtils.h>
#include <string.h>

#include "wire68.h"
/* For the launch-search budget's bounds and its ONE statement of the default,
 * in seconds. This header is Toolbox-free, so including it here costs
 * nothing but the constants. */
#include "n68_devsettings.h"

/* HFS's own name limit (31 characters + NUL), matching ProcEntry.name's
 * size in proc68.h. Not proc_quit_args.h's kProcQuitNameMax - this file
 * does not include that header (see the top-of-file comment on why). */
enum { kProcNameMax = 32 };

/* ---- Pascal/C string plumbing ------------------------------------------ */

/* Copies a Pascal string into a NUL-terminated C buffer, truncated to fit.
 * Every process/file name handled here is bounded by HFS's 31-character
 * limit, but GetProcessInformation's own contract wants a Str255-sized
 * destination (see ProcessInfoRec's field comment in Processes.h - a
 * Str31 there is an overflow the API does not know to avoid), so this
 * takes the length byte at face value and truncates on the way OUT
 * instead of trusting the source was ever short. */
static void pstr_to_c(ConstStr255Param p, char *out, long cap)
{
    long n = p[0];

    if (n > cap - 1) {
        n = cap - 1;
    }
    if (n < 0) {
        n = 0;
    }
    memcpy(out, p + 1, (size_t)n);
    out[n] = '\0';
}

/* Two names are the same process name if IUEqualString says 0 (equal) -
 * the ordering it returns otherwise is not meaningful here. Script- and
 * case-insensitive, matching how the Finder and the Process Manager
 * already compare these names to each other. */
static int names_equal(ConstStr255Param a, ConstStr255Param b)
{
    return IUEqualString(a, b) == 0;
}

/* Reads one process's name (Pascal, Str255-sized destination per
 * ProcessInfoRec's contract). Returns false when the PSN names nothing -
 * the only liveness test the Process Manager offers, and the reason a
 * stale PSN fails closed rather than reporting on whatever now holds
 * that serial number. */
static Boolean read_process_name(const ProcessSerialNumber *psn, Str255 name)
{
    ProcessInfoRec info;

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    return GetProcessInformation(psn, &info) == noErr;
}

/* DEFECT 9 FIX: appends s into buf[*pos, cap) like now68k_fmt_append_str,
 * but maps every high-bit byte (0x80-0xFF) to '?' first. proc68.h promises
 * detail carries no high-bit characters, and two different kinds of name
 * land in it: the caller's raw argument (UTF-8 over the wire - an accented
 * or symbol character arrives as a multi-byte sequence, every byte of
 * which has the high bit set) and MacRoman process/file names read back
 * from the Toolbox (whose OWN extended characters, e.g. bullet or an
 * accented letter, are high-bit bytes by definition of the encoding).
 * set_detail is the one place both funnel through on their way into
 * detail, so this is where the promise gets enforced rather than trusted
 * to hold by construction at every call site. */
static int append_ascii(char *buf, long cap, long *pos, const char *s)
{
    if (s == NULL) {
        return 1;
    }
    while (*s != '\0') {
        if (*pos < 0 || *pos >= cap) {
            return 0;
        }
        buf[(*pos)++] = ((unsigned char)*s >= 0x80) ? '?' : *s;
        ++s;
    }
    return 1;
}

/* Appends a small unsigned decimal. Not numfmt.h for the same reason the
 * rest of this file is not: one append helper family, one set of bounds
 * conventions. Digits are ASCII by construction, so this does not go
 * through append_ascii's high-bit mapping. Only used for the launch-search
 * budget, which is bounded to three digits by proc68.h; the buffer is sized
 * for a full unsigned long anyway rather than for today's caller. */
static int append_uint(char *buf, long cap, long *pos, unsigned long value)
{
    char digits[12];
    int  n = 0;

    do {
        digits[n++] = (char)('0' + (value % 10));
        value /= 10;
    } while (value != 0 && n < (int)sizeof digits);

    while (n > 0) {
        if (*pos < 0 || *pos >= cap) {
            return 0;
        }
        buf[(*pos)++] = digits[--n];
    }
    return 1;
}

/* Writes as much of a-b-c as fits into detail[0, cap), NUL-terminated.
 * b and c may be NULL to skip. Every ProcOutcome path uses this so a
 * short detail_cap truncates the sentence instead of overrunning it.
 * Sanitizes through append_ascii (DEFECT 9) - a and b and c may each
 * contain a name, and none of them are trusted to already be ASCII. */
static void set_detail(char *detail, long cap, const char *a, const char *b,
                       const char *c)
{
    long pos = 0;

    if (detail == NULL || cap <= 0) {
        return;
    }
    (void)(append_ascii(detail, cap, &pos, a != NULL ? a : "")
           && append_ascii(detail, cap, &pos, b)
           && append_ascii(detail, cap, &pos, c));
    if (pos >= cap) {
        pos = cap - 1;
    }
    if (pos < 0) {
        pos = 0;
    }
    detail[pos] = '\0';
}

/* ---- proc_list ----------------------------------------------------------
 *
 * GetNextProcess enumerates the Process Manager's list starting from the
 * oldest still-running process (the one launched first - typically the
 * Finder/system process) through to the most recently launched. proc68.h
 * asks for NEWEST first, which is the more useful order both for a human
 * skimming the list and for a redeploy loop's "did my last launch land"
 * check, so this walks into a scratch array in native order and reverses
 * on the way out.
 *
 * NOTE: the oldest-to-newest enumeration order is documented behavior I
 * recall from Inside Macintosh: Processes but could not re-verify against
 * the actual text or a live machine in this pass - flagged in the
 * deliverable report as wanting a metal/emulator check. Getting it
 * backwards would only mis-order the human-facing list, not break
 * proc_quit_named's correctness (which matches by name, not position).
 */

/* A 4 MB System 7.1 machine hosts a handful of processes at once (System,
 * Finder, NOW-68K itself, maybe two or three more) - this is generous
 * headroom, not a real ceiling, and costs 48 * sizeof(ProcEntry) bytes of
 * stack (48 * 40 = 1920 bytes), not heap. */
enum { kProcListScratchMax = 48 };

long proc_list(ProcEntry *out, long cap)
{
    ProcEntry scratch[kProcListScratchMax];
    ProcessSerialNumber psn;
    Str255 name;
    long total = 0;
    long take;
    long i;

    if (out == NULL || cap <= 0) {
        return 0;
    }

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (total < kProcListScratchMax && GetNextProcess(&psn) == noErr) {
        if (!read_process_name(&psn, name)) {
            continue;           /* gone mid-walk; the next list will agree */
        }
        scratch[total].psn = psn;
        pstr_to_c(name, scratch[total].name, sizeof scratch[total].name);
        ++total;
    }

    take = total < cap ? total : cap;
    for (i = 0; i < take; ++i) {
        out[i] = scratch[total - 1 - i];
    }
    return take;
}

/* ---- proc_list_rows -----------------------------------------------------
 *
 * proc_list's walk with a full ProcessInfoRec read per process, for the
 * wire's process.listing. Everything it produces is plain C (see
 * n68_proclist.h) - no PSN, no Str31, nothing this file's caller would
 * need the Toolbox to interpret.
 */

/* Spelled out rather than written 'FNDR': a multi-character constant warns
 * under -Werror, which this build treats as fatal. Same two the PowerPC
 * guest's serve_process_list classifies on, so both guests answer "finder"
 * for the same process. */
#define PROC68_4CC(a, b, c, d)                                        \
    (((unsigned long)(a) << 24) | ((unsigned long)(b) << 16)          \
     | ((unsigned long)(c) << 8) | (unsigned long)(d))

enum {
    kProcTypeFinder = PROC68_4CC('F', 'N', 'D', 'R'),
    kProcSigFinder  = PROC68_4CC('M', 'A', 'C', 'S')
};

/* A 4CC to four printable characters. An unprintable byte becomes '.'
 * here rather than being dropped, so the field keeps its width and a
 * human can still see that the process HAS a type; n68_proclist.c
 * sanitizes again on the way into JSON, which is where the promise that
 * matters (valid UTF-8 for the host's decoder) is actually kept. */
static void fourcc_to_text(unsigned long code, char out[5])
{
    int i;

    for (i = 0; i < 4; ++i) {
        char c = (char)((code >> (24 - i * 8)) & 0xFFUL);

        out[i] = (c >= 0x20 && c <= 0x7E) ? c : '.';
    }
    out[4] = '\0';
}

long proc_list_rows(N68ProcRow *out, long cap)
{
    ProcessSerialNumber psn;
    ProcessSerialNumber front;
    ProcessSerialNumber self;
    Boolean have_front;
    Boolean have_self;
    Str255 name;
    long count = 0;
    long i;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    have_front = (GetFrontProcess(&front) == noErr);
    /* Marking our own row is what lets a caller name THIS process without
     * guessing at the file name it was deployed under - see n68_proclist.h
     * on is_self. gather_targets already does the same SameProcess check
     * for the quit refusal; this is the same fact, reported instead of
     * only acted on. */
    have_self = (GetCurrentProcess(&self) == noErr);

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        N68ProcRow *row;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;       /* gone mid-walk; the next list will agree */
        }

        if (count < cap) {
            row = &out[count++];
        } else {
            /* Full. Drop the OLDEST rather than the newest - see the
             * header. GetNextProcess runs oldest-to-newest, so out[0] is
             * the oldest we still hold. */
            for (i = 1; i < cap; ++i) {
                out[i - 1] = out[i];
            }
            row = &out[cap - 1];
        }

        memset(row, 0, sizeof *row);
        pstr_to_c(name, row->name, (long)sizeof row->name);
        fourcc_to_text((unsigned long)info.processType, row->code);
        fourcc_to_text((unsigned long)info.processSignature, row->creator);
        if ((unsigned long)info.processType == kProcTypeFinder
            || (unsigned long)info.processSignature == kProcSigFinder) {
            row->kind = kN68ProcKindFinder;
        } else if ((info.processMode & modeOnlyBackground) != 0) {
            row->kind = kN68ProcKindBackground;
        } else {
            row->kind = kN68ProcKindApplication;
        }
        row->size_kb = (long)(info.processSize / 1024);
        row->psn_high = (unsigned long)psn.highLongOfPSN;
        row->psn_low = (unsigned long)psn.lowLongOfPSN;
        if (have_front) {
            Boolean is_front = false;

            (void)SameProcess(&psn, &front, &is_front);
            row->front = (unsigned char)(is_front ? 1 : 0);
        }
        if (have_self) {
            Boolean is_self = false;

            (void)SameProcess(&psn, &self, &is_self);
            row->is_self = (unsigned char)(is_self ? 1 : 0);
        }
    }

    /* Native order is oldest-first; proc68.h promises newest-first, and
     * this reverses in place with one row of scratch rather than the
     * second full-size array proc_list needs (that one must ALSO drop the
     * overflow from the wrong end, which this loop already did above). */
    for (i = 0; i < count / 2; ++i) {
        N68ProcRow tmp = out[i];

        out[i] = out[count - 1 - i];
        out[count - 1 - i] = tmp;
    }
    return count;
}

/* ---- proc_quit_named ----------------------------------------------------
 *
 * The composition proc68.h specifies: list, match by name, re-validate
 * the PSN, ask, RE-LIST. See that header for why every step matters; this
 * comment only covers what is NOT obvious from reading the code.
 */

/* Several copies of one application can be running, but not many; this
 * mirrors the PowerPC guest's kMaxTargets=8 - "if you have more than
 * that, narrow it down" rather than a bigger buffer. Unlike the PowerPC
 * guest, proc68.h's proc_quit_named has no --all, so ANY count above 1 is
 * already kProcAmbiguous; 8 is headroom for an honest count in the detail
 * message, not a limit this file ever acts on beyond "more than one". */
enum { kProcQuitMaxTargets = 8 };

typedef struct {
    ProcessSerialNumber psn;
    Str255              name;
} QuitTarget;

/* Re-checks that a previously-found target is still the same running
 * process. A PSN can be recycled by something launched in the meantime,
 * so the name is compared too - "live but differently named" counts as
 * gone, never as still running (wrong in the safe direction only). */
static Boolean target_still_live(const QuitTarget *t)
{
    Str255 now;

    if (!read_process_name(&t->psn, now)) {
        return false;
    }
    return names_equal(now, t->name) ? true : false;
}

/* Yields without dequeuing a single event - see proc68.h and the header's
 * own comment on proc_quit_named for why an event mask of 0 is not
 * optional here: taking a keystroke or click on the target's behalf would
 * steal input from the front application, and this function is called
 * from inside command handling, not the main event loop, so there is no
 * safe nested dispatch to enter. Pumps the wire each pass so the
 * connection is not stalled for the whole wait. */
/* DEFECT 3 FIX: wire_idle() can walk all the way through control-frame
 * dispatch to a NEW command's handler - and both commands this file
 * exposes call yield_ticks (proc_quit_named's confirm wait, and
 * cat_search_find's between-slice pump during launch). If the host
 * pipelines a second quit/launch while the first is still waiting here,
 * that handler calls yield_ticks again, which would call wire_idle again,
 * still on the first call's stack: yield_ticks -> wire_idle ->
 * service_live -> drain_frames -> handle_control_message ->
 * handle_command_request -> dispatcher -> run_quit -> proc_quit_named ->
 * yield_ticks, unbounded in depth and bounded in TIME only by
 * wait_ticks (up to 20s per level - long enough for the host to queue
 * several more). Measured at ~3.7 KB of stack per level; main.c's
 * MaxApplZone() leaves no slack between the stack and the heap, so this
 * was not a stack overflow that would trip a sniffer - it was silent
 * corruption of live heap blocks. `pumping` is set for the DURATION of
 * the wire_idle() call, at the one place in this file that can re-enter
 * it (this function is the sole caller of wire_idle in proc68.c, from
 * both re-entry paths), so a nested call skips the pump instead of
 * recursing into it; WaitNextEvent(0, ...) still runs every level, so
 * the ticks-based wait it exists for keeps making real progress even
 * when the pump is skipped. Mirrors the PowerPC guest's now_wire_pump
 * guard (wire.c, branch thread/guest-quit-command) - same hazard, same
 * fix, just scoped to this file's own entry point instead of wire_idle
 * itself. */
static void yield_ticks(long ticks)
{
    static Boolean pumping = false;
    EventRecord event;

    if (!pumping) {
        pumping = true;
        wire_idle();
        pumping = false;
    }
    (void)WaitNextEvent(0, &event, (unsigned long)ticks, NULL);
}

/* Sends the 'quit' Apple Event. noErr means DELIVERED, never that the
 * application has gone - proc68.h's whole reason for existing. */
static OSErr ask_quit(const ProcessSerialNumber *psn)
{
    AEAddressDesc target;
    AppleEvent    event;
    AppleEvent    reply;
    OSErr         err;

    err = AECreateDesc(typeProcessSerialNumber, psn, sizeof *psn, &target);
    if (err != noErr) {
        return err;
    }
    err = AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target,
                             kAutoGenerateReturnID, kAnyTransactionID,
                             &event);
    AEDisposeDesc(&target);
    if (err != noErr) {
        return err;
    }
    /* No reply, no interaction: a cooperative quit the app may decline is
     * still the most force this platform safely allows. */
    err = AESend(&event, &reply, kAENoReply | kAENeverInteract,
                kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&event);
    return err;
}

/* Collects every live, non-self process named `name`. Returns the count,
 * capped at kProcQuitMaxTargets (a count above that is still reported as
 * "more than N", not silently clamped to N). *self_seen says whether the
 * walk passed over NOW itself under this name, which is what tells "no
 * such process" apart from "you asked NOW to quit itself".
 *
 * DEFECT 5 FIX (half 1): *unreadable_out counts rows GetProcessInformation
 * could not read mid-walk. A row failing to read is NOT proof it was not
 * our target - it might have BEEN it, on its way out from under us, or
 * behind some other transient Process Manager hiccup. Silently treating
 * every unreadable row as "not a match" (the old behavior) let a read
 * failure that happened to land on the target masquerade as "nothing
 * named X is running" with count 0 - the caller could not tell that case
 * apart from a genuinely empty walk. Now it can. */
static long gather_targets(const char *name, QuitTarget *out,
                           Boolean *self_seen, long *unreadable_out)
{
    ProcessSerialNumber psn;
    ProcessSerialNumber self;
    Str255              wanted;
    Str255              found_name;
    long                count = 0;
    long                unreadable = 0;

    *self_seen = false;
    *unreadable_out = 0;
    CopyCStringToPascal(name, wanted);
    if (GetCurrentProcess(&self) != noErr) {
        self.highLongOfPSN = 0;
        self.lowLongOfPSN = kNoProcess;
    }

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&psn) == noErr) {
        Boolean is_self = false;

        if (!read_process_name(&psn, found_name)) {
            ++unreadable;              /* could not confirm this ISN'T the
                                         * target - see the function
                                         * comment; not "gone mid-walk"
                                         * without more evidence than we
                                         * have */
            continue;
        }
        if (!names_equal(found_name, wanted)) {
            continue;
        }
        (void)SameProcess(&psn, &self, &is_self);
        if (is_self) {
            *self_seen = true;         /* a SECOND copy of NOW is a fair
                                         * target; THIS instance is not */
            continue;
        }
        if (count < kProcQuitMaxTargets) {
            out[count].psn = psn;
            memcpy(out[count].name, found_name, (size_t)found_name[0] + 1);
        }
        ++count;
    }
    *unreadable_out = unreadable;
    return count;
}

ProcOutcome proc_quit_named(const char *name, long wait_ticks,
                            char *detail, long detail_cap)
{
    QuitTarget targets[kProcQuitMaxTargets];
    Boolean    self_seen = false;
    long       found;
    long       unreadable = 0;
    long       i;
    OSErr      err;
    unsigned long started;

    if (name == NULL || name[0] == '\0' || strlen(name) >= kProcNameMax) {
        set_detail(detail, detail_cap,
                   "quit: bad process name (empty, or over 31 characters)",
                   NULL, NULL);
        return kProcBadArgs;
    }

    /* DEFECT 5 FIX (half 2): names_equal is IUEqualString against the
     * Process Manager's MacRoman Str255. A host sending the target as
     * UTF-8 (any name with an accented or symbol character, over a JSON
     * wire) arrives here as bytes with the high bit set, which is not a
     * MacRoman string and can never truthfully match one - the walk below
     * would find nothing and report kProcNotRunning, ok:true, for a
     * process that is in fact running. Refuse outright instead of
     * comparing something we cannot represent; kProcBadArgs is the
     * existing outcome closest to "the argument, as given, cannot be
     * used" (proc68.h has no dedicated encoding-error code, and this fix
     * round is scoped to proc68.c, not the header). */
    for (i = 0; name[i] != '\0'; ++i) {
        if ((unsigned char)name[i] >= 0x80) {
            set_detail(detail, detail_cap,
                       "quit: process name has a non-ASCII byte - refusing "
                       "an unsafe MacRoman comparison", NULL, NULL);
            return kProcBadArgs;
        }
    }

    found = gather_targets(name, targets, &self_seen, &unreadable);

    if (found == 0) {
        if (self_seen) {
            set_detail(detail, detail_cap,
                       "quit: NOW will not ask itself to quit", NULL, NULL);
            return kProcRefusedSelf;
        }
        if (unreadable > 0) {
            /* DEFECT 5 FIX (half 1, continued): a row could not be read
             * while walking for `name` - it might have been the target.
             * kProcNotRunning claims the asked-for state is confirmed;
             * that has not been established, so this refuses to guess
             * rather than report success. kProcAmbiguous is the nearest
             * existing "refuse rather than guess" outcome (also ok:false
             * at the wire) - see the header note on kProcBadArgs above
             * for why this reuses an existing code instead of adding
             * one. */
            set_detail(detail, detail_cap,
                       "quit: could not read every running process while "
                       "looking for ", name,
                       " - can't confirm it isn't one of them");
            return kProcAmbiguous;
        }
        /* Not an error: the asked-for state (not running) already holds -
         * exactly what a redeploy loop wants to hear when the previous
         * pass already took the process down. */
        set_detail(detail, detail_cap,
                   "quit: nothing named ", name, " is running");
        return kProcNotRunning;
    }
    if (found > 1) {
        set_detail(detail, detail_cap,
                   "quit: several processes are named ", name,
                   " - refusing to guess which one");
        return kProcAmbiguous;
    }

    /* Re-validate: the listing above is already in the past. A target
     * that died in the gap between gather_targets and here was simply
     * never asked - which leaves the machine in the asked-for state
     * (not running), so this reports kProcNotRunning, not kProcGone
     * (which the header reserves for a confirmed post-ask departure). */
    if (!target_still_live(&targets[0])) {
        set_detail(detail, detail_cap, "quit: ", name,
                   " went away before it could be asked");
        return kProcNotRunning;
    }

    err = ask_quit(&targets[0].psn);
    if (err != noErr) {
        set_detail(detail, detail_cap,
                   "quit: the Mac would not deliver a quit request to ",
                   name, NULL);
        return kProcUndeliverable;
    }

    if (wait_ticks <= 0) {
        /* No confirm window requested: delivered, deliberately
         * unconfirmed. This is the one path that does not re-list. */
        set_detail(detail, detail_cap, "quit: asked ", name,
                   "; not confirmed (wait_ticks <= 0)");
        return kProcSentUnconfirmed;
    }

    /* Confirm by re-reading the Process Manager - the only thing able to
     * tell a granted quit from a declined one. Bounded by wait_ticks;
     * each pass yields with an empty event mask (yield_ticks) and pumps
     * the wire so this wait does not stall the connection. */
    /* Unsigned throughout, deliberately: TickCount() is a UInt32 that
     * wraps roughly every 828 days of uptime, and (TickCount() - started)
     * computed in unsigned arithmetic stays correct across that wrap by
     * C's modular-overflow rule, where a signed difference or a
     * signed-cast deadline comparison would not be. Matches the PPC
     * guest's own UInt32 started/deadline pattern in proc_actions.c. */
    started = (unsigned long)TickCount();
    for (;;) {
        if (!target_still_live(&targets[0])) {
            set_detail(detail, detail_cap, "quit: ", name, " is gone");
            return kProcGone;
        }
        if ((unsigned long)TickCount() - started >= (unsigned long)wait_ticks) {
            break;
        }
        yield_ticks(2);
    }

    /* The outcome that must never read as success: delivered, and still
     * there at the deadline - declined, or sitting on a Save dialog. */
    set_detail(detail, detail_cap, "quit: ", name,
               " is still running - declined, or busy");
    return kProcStillRunning;
}

/* ---- proc_quit_psn -------------------------------------------------------
 *
 * The same three steps proc_quit_named ends with - re-validate, refuse
 * self, ask - with the first half (walk, match a name, refuse ambiguity)
 * gone, because a PSN has already done that job. See proc68.h for why
 * this one does not confirm.
 */
ProcOutcome proc_quit_psn(unsigned long psn_high, unsigned long psn_low,
                          char *detail, long detail_cap)
{
    ProcessSerialNumber psn;
    ProcessSerialNumber self;
    Str255              name;
    char                cname[kProcNameMax];
    Boolean             is_self = false;
    OSErr               err;

    psn.highLongOfPSN = psn_high;
    psn.lowLongOfPSN = psn_low;

    /* Re-validation IS the liveness check here: a PSN the Process Manager
     * will not read is not a live process. The name comes back with it,
     * for the sentence a person reads - the caller named a number, and
     * "asked FTP Server to quit" is what makes the log legible later. */
    if (!read_process_name(&psn, name)) {
        set_detail(detail, detail_cap,
                   "quit: that process is no longer running", NULL, NULL);
        return kProcNotRunning;
    }
    pstr_to_c(name, cname, (long)sizeof cname);

    if (GetCurrentProcess(&self) != noErr) {
        /* We could not learn our own PSN, so we cannot prove the target
         * is not us - and asking ourselves to quit would sever the reply
         * mid-send. Refusing is the only answer that cannot do that. */
        set_detail(detail, detail_cap,
                   "quit: could not read this process's own identity - "
                   "refusing rather than risk quitting NOW itself",
                   NULL, NULL);
        return kProcRefusedSelf;
    }
    (void)SameProcess(&psn, &self, &is_self);
    if (is_self) {
        set_detail(detail, detail_cap,
                   "quit: NOW will not ask itself to quit", NULL, NULL);
        return kProcRefusedSelf;
    }

    err = ask_quit(&psn);
    if (err != noErr) {
        set_detail(detail, detail_cap,
                   "quit: the Mac would not deliver a quit request to ",
                   cname, NULL);
        return kProcUndeliverable;
    }

    /* Delivered. NOT gone - the target sees the event when the
     * cooperative scheduler next reaches it, and may decline. The caller
     * confirms with process.list. */
    set_detail(detail, detail_cap, "quit: asked ", cname,
               " to quit; confirm with process.list");
    return kProcSentUnconfirmed;
}

/* ---- proc_launch_named ---------------------------------------------------
 *
 * A colon in `name` means a full HFS path, used directly. Otherwise this
 * resolves a bare name against the startup volume's catalog, refusing
 * anything that is not an application (fdType 'APPL') before launching
 * it - opening whatever claims a document is not what "launch <name>"
 * asked for.
 *
 * proc68.h derives this from the CONTRACT (launch's x-command), not from
 * the PowerPC guest, per the task's instruction; the contract's launch
 * grammar additionally supports a leading "-v VERSION" disambiguator and
 * "#n" stored-match resolution that proc68.h's simpler, flag-free
 * proc_launch_named(name, ...) signature has no room for. Flagged in the
 * deliverable report, not silently added here - the header is
 * authoritative and this file implements exactly what it declares.
 */

/* PBCatSearchSync's ioSearchTime bounds ONE call; a search can span many
 * calls via ioCatPosition. The whole-disk-search wedge this project has
 * already hit once means the OVERALL wall-clock budget matters more than
 * any single call's slice - this mirrors the contract's own catsearch
 * command, independently bounded "at ~20 s per pass on a disk that
 * cannot answer faster". 60 ticks/call keeps the guest's window and wire
 * serviced between slices (via yield_ticks/wire_idle) rather than
 * blocking the whole budget in one Toolbox call. */
enum {
    /* commands68.c has its own identical kTicksPerSecond. Not lifted into a
     * shared header in this pass because that means editing a file this
     * thread does not own, and 60 ticks to the second is a fixed property of
     * the machine rather than a limit anyone may change - the failure mode
     * AGENTS.md's "state a limit once" warns about (two copies drifting)
     * cannot occur here. Worth folding together the next time both files are
     * open anyway. */
    kTicksPerSecond           = 60,
    kLaunchSearchSliceTicks   = 60,     /* ~1 s per PBCatSearchSync call */
    /* ~20 s total, catsearch's bound. DERIVED, not typed: the number lives
     * once, in n68_devsettings.h, because the settings file's default when
     * the key is absent and the constant compiled in here must be the same
     * twenty seconds or the file's "absent means unchanged" promise is a
     * lie. */
    kLaunchSearchBudgetTicks  = kN68DevLaunchSearchDefaultSecs * kTicksPerSecond,
    kLaunchSearchMaxRetries   = 3,      /* catChangedErr: restart, bounded */
    kLaunchRootWalkMaxIndex   = 512     /* fallback: root-level entries only,
                                         * see the comment on root_walk() */
};

/* The budget actually in force: the compiled-in default until the dev
 * settings file overrides it (proc68.h). Four bytes of file-static, and the
 * only mutable state in this file. The per-call slice above is NOT settable
 * - see proc68.h on why only the outer bound moves. */
static unsigned long gLaunchSearchBudgetTicks = kLaunchSearchBudgetTicks;

void proc_set_launch_search_seconds(unsigned short seconds)
{
    /* Re-validated here rather than trusted from the parser. The parser is
     * the only caller today, but a bound that lives only in the caller is a
     * bound that disappears the first time someone adds a second caller -
     * and the value this one guards is the one that stops a whole-volume
     * search from running unbounded. */
    if (seconds < kN68DevLaunchSearchMinSecs
        || seconds > kN68DevLaunchSearchMaxSecs) {
        return;                         /* leave the shipped default alone */
    }
    gLaunchSearchBudgetTicks = (unsigned long)seconds * kTicksPerSecond;
}

unsigned short proc_launch_search_seconds(void)
{
    return (unsigned short)(gLaunchSearchBudgetTicks / kTicksPerSecond);
}

/* True if spec names a real file whose Finder type is 'APPL' (the literal
 * multi-char constant, matching log.c's 'ttxt'/'TEXT' precedent - this
 * toolchain's -Wall -Wextra -Werror does not flag it). On any error (does
 * not exist, is a folder, catalog read failed) this returns false and
 * leaves *err_out set for the caller to report - "not an application" and
 * "does not exist" are different sentences even though both refuse to
 * launch. */
static Boolean is_application(const FSSpec *spec, OSErr *err_out)
{
    CInfoPBRec pb;

    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = (StringPtr)spec->name;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;       /* resolve by name+dirID, not index */
    *err_out = PBGetCatInfoSync(&pb);
    if (*err_out != noErr) {
        return false;
    }
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        *err_out = paramErr;            /* it is a folder, not a file */
        return false;
    }
    if (pb.hFileInfo.ioFlFndrInfo.fdType != 'APPL') {
        *err_out = paramErr;
        return false;
    }
    return true;
}

static OSErr launch_spec(FSSpec *spec)
{
    LaunchParamBlockRec lpb;

    memset(&lpb, 0, sizeof lpb);
    lpb.launchBlockID = extendedBlock;
    lpb.launchEPBLength = extendedBlockLen;
    lpb.launchAppSpec = spec;
    /* launchContinue: NOW-68K keeps running after the launch (without it,
     * LaunchApplication's single-app-era default is to quit the caller).
     * launchNoFileFlags: no custom Finder file flags are being passed.
     * launchDontSwitch is deliberately NOT set - the contract's launch
     * command brings the launched app to the front, and so does this. */
    lpb.launchControlFlags = launchContinue | launchNoFileFlags;
    lpb.launchAppParameters = NULL;
    return LaunchApplication(&lpb);
}

/* Full HFS path (name contains ':'): parsed directly via FSMakeFSSpec's
 * documented idiom for a full pathname (vRefNum=0, dirID=0 lets the File
 * Manager resolve the leading volume name itself). */
static short launch_full_path(const char *name, char *detail, long cap)
{
    Str255 path;
    FSSpec spec;
    OSErr  err;

    if (strlen(name) > 255) {
        set_detail(detail, cap, "launch: path over 255 characters", NULL,
                   NULL);
        return paramErr;
    }
    CopyCStringToPascal(name, path);
    err = FSMakeFSSpec(0, 0, path, &spec);
    if (err != noErr) {
        set_detail(detail, cap, "launch: ", name, " not found");
        return err;
    }
    if (!is_application(&spec, &err)) {
        set_detail(detail, cap, "launch: ", name,
                   " is not an application - refusing to launch it");
        return err != noErr ? err : paramErr;
    }
    err = launch_spec(&spec);
    if (err != noErr) {
        set_detail(detail, cap, "launch: the Toolbox refused ", name, NULL);
        return err;
    }
    set_detail(detail, cap, "launch: ", name, " launched");
    return noErr;
}

/* Fallback for a bare name when PBCatSearchSync is unusable: an INDEXED
 * walk of the startup volume's ROOT directory only via PBGetCatInfoSync
 * (ioFDirIndex 1, 2, 3, ...), stopping at kLaunchRootWalkMaxIndex. This
 * is deliberately NOT a recursive descent into subfolders - the fleet
 * note this project already carries is that a whole-disk, Finder-style
 * search hung a machine hard enough to need a physical reboot, and a
 * shallow, indexed, hard-capped walk is the bounded shape that caution
 * asks for. It is a narrower search than PBCatSearchSync's (which covers
 * every folder), and every caller that falls back to this MUST say so in
 * detail rather than reporting a plain "not found". */
static Boolean root_walk_find(short vol, const char *name, FSSpec *out)
{
    Str255 wanted;
    long   index;

    CopyCStringToPascal(name, wanted);
    for (index = 1; index <= kLaunchRootWalkMaxIndex; ++index) {
        CInfoPBRec pb;
        Str255     entry;
        OSErr      err;

        memset(&pb, 0, sizeof pb);
        entry[0] = 0;
        pb.hFileInfo.ioNamePtr = entry;
        pb.hFileInfo.ioVRefNum = vol;
        pb.hFileInfo.ioDirID = fsRtDirID;
        pb.hFileInfo.ioFDirIndex = (short)index;
        err = PBGetCatInfoSync(&pb);
        if (err == fnfErr) {
            break;                      /* past the last root-level entry */
        }
        if (err != noErr) {
            continue;                   /* skip an unreadable entry, not
                                          * the whole walk */
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            continue;                   /* a folder, not a candidate */
        }
        if (pb.hFileInfo.ioFlFndrInfo.fdType != 'APPL') {
            continue;
        }
        if (!names_equal(entry, wanted)) {
            continue;
        }
        out->vRefNum = vol;
        out->parID = fsRtDirID;
        memcpy(out->name, entry, (size_t)entry[0] + 1);
        return true;
    }
    return false;
}

/* Primary path for a bare name: PBCatSearchSync over the whole startup
 * volume, bounded to gLaunchSearchBudgetTicks total wall-clock time
 * regardless of what its return codes turn out to mean at the boundary -
 * see the comment above kLaunchSearchBudgetTicks. Returns true and fills
 * *out on a match; false with *truncated set if the budget ran out before
 * either a match or a confirmed end-of-catalog; false with *truncated
 * clear if PBCatSearchSync itself is unusable on this volume (caller
 * should fall back to root_walk_find) or if the catalog was swept
 * completely with no match. */
static Boolean cat_search_find(short vol, const char *name, FSSpec *out,
                               Boolean *unusable, Boolean *truncated)
{
    CSParam        csp;
    CInfoPBRec     lower;
    CInfoPBRec     upper;
    Str255         wanted;
    FSSpec         match;
    unsigned long  budget_start;       /* unsigned - see the wraparound
                                        * comment in proc_quit_named */
    int            retries = 0;

    *unusable = false;
    *truncated = false;
    CopyCStringToPascal(name, wanted);

    /* DEFECT 6 FIX: with fsSBFlFndrInfo set, ioSearchInfo2 (`upper`) is
     * NOT an upper range bound for the Finder-info fields - it is a
     * BITMASK against ioSearchInfo1 (`lower`)'s values (Inside Macintosh:
     * Files). `upper = lower` made the mask equal to 'APPL' itself, so
     * only the BITS SET in 'APPL' were required to match, and any fdType
     * that is a superset of those bits (an ordinary document can easily
     * be one) passed the filter. The mask must be all-ones on fdType to
     * require an EXACT match; the other FndrInfo fields stay at their
     * memset zero (don't-care - unchanged from before). */
    memset(&lower, 0, sizeof lower);
    lower.hFileInfo.ioNamePtr = wanted;
    lower.hFileInfo.ioFlFndrInfo.fdType = 'APPL';

    memset(&upper, 0, sizeof upper);
    upper.hFileInfo.ioFlFndrInfo.fdType = (OSType)0xFFFFFFFFUL;
    /* Also DEFECT 6: fsSBFlAttrib was absent from ioSearchBits, so
     * ioFlAttrib was never compared at all - and hFileInfo.ioFlFndrInfo
     * overlaps dirInfo.ioDrUsrWds at the same offset in CInfoPBRec's
     * union, so a folder whose ioDrUsrWds bytes happened to satisfy the
     * (now-exact) fdType test could still match and get launched as if
     * it were the application. ioFlAttrib is a bitmask field too; mask in
     * only ioDirMask, with lower's corresponding bit left 0 (from the
     * memset above), so the test becomes "the directory bit must be OFF"
     * - files only, folders excluded regardless of what else is set. */
    upper.hFileInfo.ioFlAttrib = ioDirMask;

    memset(&csp, 0, sizeof csp);
    csp.ioNamePtr = NULL;
    csp.ioVRefNum = vol;
    csp.ioMatchPtr = &match;
    csp.ioReqMatchCount = 1;
    csp.ioSearchBits = fsSBFullName | fsSBFlFndrInfo | fsSBFlAttrib;
    csp.ioSearchInfo1 = &lower;
    csp.ioSearchInfo2 = &upper;
    csp.ioSearchTime = kLaunchSearchSliceTicks;
    csp.ioCatPosition.initialize = 0;

    budget_start = (unsigned long)TickCount();
    for (;;) {
        OSErr err = PBCatSearchSync(&csp);

        /* DEFECT 4 FIX: PBCatSearchSync can return eofErr (end of
         * catalog reached) on the SAME call that also delivers its last
         * match - ioActMatchCount is not tied to err being noErr. The
         * old code checked ioActMatchCount only under err == noErr, so a
         * matching application that was the last (or only) hit before
         * end-of-catalog was silently dropped and reported "not found".
         * Check the match count first, regardless of which of the two
         * successful-ish codes came back. */
        if ((err == noErr || err == eofErr) && csp.ioActMatchCount >= 1) {
            *out = match;
            return true;
        }
        if (err == eofErr) {
            return false;               /* whole catalog swept, no match -
                                          * a real "not found", not a
                                          * truncation */
        }
        if (err == catChangedErr) {
            if (++retries > kLaunchSearchMaxRetries) {
                *unusable = true;       /* too unstable to trust; fall back
                                          * rather than spin on it */
                return false;
            }
            memset(&csp.ioCatPosition, 0, sizeof csp.ioCatPosition);
            continue;
        }
        if (err != noErr) {
            *unusable = true;           /* CatSearch not supported on this
                                          * volume/driver - fall back */
            return false;
        }
        /* err == noErr, 0 matches: this slice's time ran out before
         * either a match or end-of-catalog. Resume via ioCatPosition,
         * which PBCatSearchSync updates in place, as long as the overall
         * budget allows. */
        if ((unsigned long)TickCount() - budget_start
            >= gLaunchSearchBudgetTicks) {
            *truncated = true;
            return false;
        }
        yield_ticks(0);                 /* pump the wire between slices;
                                          * 0 ticks - do not add idle time
                                          * on top of the search itself */
    }
}

static short launch_bare_name(const char *name, char *detail, long cap)
{
    /* DEFECT 7 FIX: LMGetBootDrive() returns a DRIVE NUMBER. Several File
     * Manager calls (PBGetCatInfo, PBHGetVInfo, and PBCatSearch as used
     * by cat_search_find/root_walk_find below) accept a drive number in a
     * vRefNum-shaped field via the standard volume-designator convention
     * and resolve it themselves - but nothing downstream of a match does
     * that resolution for us: root_walk_find stuffs `vol` straight into
     * the FSSpec it returns (out->vRefNum = vol), and that FSSpec is
     * handed directly to LaunchApplication, which wants a real volume
     * reference number, not a drive number. GetVInfo() is the documented
     * one-line conversion from a drive number to the vRefNum naming the
     * same volume (the old comment here called this "unverified" - it
     * is not; this is that verification). Resolving once, up front, and
     * using the real vRefNum for the whole function is simpler than
     * trusting each downstream consumer's tolerance for the drive-number
     * convention individually. */
    Str255  boot_vol_name;
    short   vol;
    long    boot_free_bytes;
    FSSpec  spec;
    Boolean unusable = false;
    Boolean truncated = false;
    OSErr   err;

    boot_vol_name[0] = 0;
    err = GetVInfo(LMGetBootDrive(), boot_vol_name, &vol, &boot_free_bytes);
    if (err != noErr) {
        set_detail(detail, cap,
                   "launch: could not identify the startup volume", NULL,
                   NULL);
        return err;
    }

    if (cat_search_find(vol, name, &spec, &unusable, &truncated)) {
        /* DEFECT 6 FIX (belt half): cat_search_find's own fdType filter
         * is now an exact bitmask (see that function), but this was the
         * one launch path that skipped is_application() before
         * launch_spec() entirely, trusting the search filter alone.
         * Re-checking here costs one cheap PBGetCatInfoSync call and
         * means a second bug in the search mask can never again launch a
         * non-application on its own - belt and braces is correct when
         * the alternative is launching a random document or folder. */
        if (!is_application(&spec, &err)) {
            set_detail(detail, cap, "launch: ", name,
                       " is not an application - refusing to launch it");
            return err != noErr ? err : paramErr;
        }
        err = launch_spec(&spec);
        if (err != noErr) {
            set_detail(detail, cap, "launch: the Toolbox refused ", name,
                       NULL);
            return err;
        }
        set_detail(detail, cap, "launch: ", name, " launched");
        return noErr;
    }

    if (truncated) {
        /* The budget is NAMED in the sentence, not just alluded to. Once it
         * is settable from a file, "the time budget" could be twenty
         * seconds or one, and those are two entirely different pieces of
         * news: the first says the volume is enormous or the disk is sick,
         * the second says someone left a lab settings file in place. The
         * number is the difference between them, and this line is where a
         * human is looking when they need it. */
        char tail[96];
        long pos = 0;

        if (append_ascii(tail, (long)sizeof tail, &pos, " truncated at the ")
            && append_uint(tail, (long)sizeof tail, &pos,
                           (unsigned long)proc_launch_search_seconds())
            && append_ascii(tail, (long)sizeof tail, &pos,
                            "s search budget - not found so far, may exist "
                            "deeper in the catalog")
            && pos < (long)sizeof tail) {
            tail[pos] = '\0';
            set_detail(detail, cap, "launch: search of ", name, tail);
        } else {
            set_detail(detail, cap, "launch: search of ", name,
                       " truncated at the time budget - not found so far, "
                       "may exist deeper in the catalog");
        }
        return paramErr;
    }

    if (unusable && root_walk_find(vol, name, &spec)) {
        err = launch_spec(&spec);
        if (err != noErr) {
            set_detail(detail, cap, "launch: the Toolbox refused ", name,
                       NULL);
            return err;
        }
        set_detail(detail, cap, "launch: ", name,
                   " launched (found by the root-only fallback search - "
                   "PBCatSearch was unusable on this volume)");
        return noErr;
    }

    if (unusable) {
        set_detail(detail, cap, "launch: ", name,
                   " not found in the startup volume's ROOT folder only "
                   "- PBCatSearch was unusable, so subfolders were not "
                   "searched");
        return paramErr;
    }

    set_detail(detail, cap, "launch: nothing named ", name,
               " is on the startup volume");
    return paramErr;
}

short proc_launch_named(const char *name, char *detail, long detail_cap)
{
    if (name == NULL || name[0] == '\0') {
        set_detail(detail, detail_cap, "launch: no target given", NULL,
                   NULL);
        return paramErr;
    }
    if (strchr(name, ':') != NULL) {
        return launch_full_path(name, detail, detail_cap);
    }
    return launch_bare_name(name, detail, detail_cap);
}
