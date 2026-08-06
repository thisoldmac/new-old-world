#include "proc_actions.h"

#include <stdio.h>
#include <string.h>

#include <Carbon.h>
#include <CodeFragments.h>

#include "proc_hide_args.h"
#include "proc_quit_args.h"
#include "wire.h"

/* --- the Process Manager's visibility calls ------------------------------

   Declared here because the Universal Interfaces on this toolchain's
   include path are 3.4, and these two arrived in 3.4.1. The text is that
   header's, copied rather than paraphrased so the selector travels with the
   prototype:

     Universal Interfaces 3.4.1, Processes.h ll. 542-545
       ShowHideProcess()   Availability: CarbonLib 1.5 and later,
                           Non-Carbon CFM: not available
       IsProcessVisible()  selector 0x005F, same availability

   THREEWORDINLINE macros away on this target (PowerPC, CFM) — it is here to
   record the selector, which is otherwise the one fact about this route
   that lives nowhere in the tree. The import itself is resolved through
   CarbonLib's import library; see now-guest-ppc/CMakeLists.txt for why that
   needs a line of its own, and why NOW_HAVE_SHOWHIDEPROCESS can be 0. */
#if NOW_HAVE_SHOWHIDEPROCESS
EXTERN_API( OSErr )
ShowHideProcess(
  const ProcessSerialNumber *  PSN,
  Boolean                      visible)     THREEWORDINLINE(0x3F3C, 0x0060, 0xA88F);

EXTERN_API( Boolean )
IsProcessVisible(const ProcessSerialNumber * PSN)
                                            THREEWORDINLINE(0x3F3C, 0x005F, 0xA88F);
#endif

OSErr now_proc_bring_to_front(const ProcessSerialNumber *psn)
{
    return SetFrontProcess(psn);
}

OSErr now_proc_ask_quit(const ProcessSerialNumber *psn)
{
    AEAddressDesc target;
    AppleEvent event;
    AppleEvent reply;
    OSErr err;

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
       still the most force the platform safely allows. */
    err = AESend(&event, &reply, kAENoReply | kAENeverInteract,
                 kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&event);
    return err;
}

/* --- quit by name -------------------------------------------------------- */

/* Several copies of one application can be running (two SimpleTexts from
   two folders), but not many; a small fixed array is the whole story and
   costs no allocation on a 56 MB machine. Beyond this the answer is
   "narrow it down", not a bigger buffer. */
enum { kMaxTargets = 8 };

typedef struct {
    ProcessSerialNumber psn;
    Str31 name;
} QuitTarget;

/* Reads one process's name into `name` (Pascal). Returns false when the
   PSN names nothing — which is the ONLY liveness test available, and the
   reason a stale PSN fails closed rather than driving whatever now holds
   that serial. */
static Boolean process_name(const ProcessSerialNumber *psn, Str31 name)
{
    ProcessInfoRec info;

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    return GetProcessInformation(psn, &info) == noErr;
}

/* Is this target still the process we asked to quit? A PSN can be reused
   by something launched in the meantime, so the name is compared too:
   "live but differently named" is gone, not still running. Wrong in the
   safe direction either way — we never report gone for a live target. */
static Boolean target_is_live(const QuitTarget *t)
{
    Str31 now;

    if (!process_name(&t->psn, now)) {
        return false;
    }
    return EqualString(now, t->name, false, true);
}

static void pascal_to_c(ConstStr255Param p, char *out, long cap)
{
    long n = p[0];

    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(out, p + 1, (size_t)n);
    out[n] = '\0';
}

/* Yields the processor for `ticks` without dequeuing a single event.
   ------------------------------------------------------------------
   This is the load-bearing line of the whole command. A 'quit' Apple
   Event sits in the target's queue until the Process Manager schedules
   it, and on a cooperatively scheduled machine that only happens while
   somebody else is inside WaitNextEvent. Returning to our own event loop
   is not an option (we are called from inside a command), and running a
   nested dispatch loop would re-enter the console that called us.

   An event mask of 0 threads that needle: the sleep yields, nothing is
   dequeued, and the human's clicks and keys stay queued for the main
   loop to handle when we return. The cost is that our window does not
   redraw for the duration - bounded by kProcQuitWaitMax, and listed in
   docs/nested-loops.md with the other stalls. */
static void yield_ticks(UInt32 ticks)
{
    EventRecord event;

    now_wire_pump();
    (void)WaitNextEvent(0, &event, ticks, NULL);
}

/* Collects every live process named `want`. Returns the count, or -1 if
   there are more matches than kMaxTargets. `skipped_self` says whether
   the walk passed over us, which is what tells "no such process" apart
   from "you asked us to quit ourselves".

   `skip_self` is false for `front`: quitting this process would sever
   the reply mid-send, and bringing it forward severs nothing, so NOW is
   a fair target for one verb and not the other. It is a parameter rather
   than two walks because the walk is the part that must not drift. */
static int gather_targets(const char *want, QuitTarget *out,
                          Boolean *skipped_self, Boolean skip_self)
{
    ProcessSerialNumber psn;
    ProcessSerialNumber self;
    Str255 wanted;
    Str31 name;
    int count = 0;

    *skipped_self = false;
    /* Str255, not Str31, because CopyCStringToPascal cannot be told a cap
       and is DECLARED to write one - a Str31 here is an overflow the
       compiler is right to name, even with the parser's 31-character
       refusal standing behind it. EqualString compares by length byte, so
       a Str255 holding a short name matches a Str31 fine. */
    CopyCStringToPascal(want, wanted);
    if (GetCurrentProcess(&self) != noErr) {
        self.highLongOfPSN = 0;
        self.lowLongOfPSN = kNoProcess;
    }

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&psn) == noErr) {
        Boolean is_self = false;

        if (!process_name(&psn, name)) {
            continue;              /* it went away mid-walk; not ours to
                                      mourn - the next list will agree */
        }
        if (!EqualString(name, wanted, false, true)) {
            continue;
        }
        (void)SameProcess(&psn, &self, &is_self);
        if (is_self && skip_self) {
            /* Deliberate, not incidental: a second COPY of NOW is a
               legitimate target, but this one is the one holding the
               reply. */
            *skipped_self = true;
            continue;
        }
        if (count == kMaxTargets) {
            return -1;
        }
        out[count].psn = psn;
        memcpy(out[count].name, name, (size_t)name[0] + 1);
        ++count;
    }
    return count;
}

/* One live process by name, for a caller that is not going to act on it
   through an Apple Event - see proc_actions.h. The walk is `gather_targets`
   because there is only one walk; what differs is what the caller does
   with the result, and ambiguity is refused here exactly as it is for
   quit rather than resolved to whichever copy the Process Manager listed
   first. NOW itself is a fair target: reading a process is not quitting
   it. */
NowProcFindOutcome now_proc_find_by_name(const char *want,
                                         ProcessSerialNumber *psn)
{
    QuitTarget targets[kMaxTargets];
    Boolean skipped_self = false;
    int found;

    if (want == NULL || want[0] == '\0' || psn == NULL) {
        return kProcFindNoName;
    }
    found = gather_targets(want, targets, &skipped_self, false);
    if (found < 0) {
        return kProcFindAmbiguous;
    }
    if (found == 0) {
        return kProcFindNotRunning;
    }
    if (found > 1) {
        return kProcFindAmbiguous;
    }
    *psn = targets[0].psn;
    return kProcFindOne;
}

NowProcQuitOutcome now_proc_quit_by_name(const char *arg, char *msg, long cap)
{
    ProcQuitArgs args;
    QuitTarget targets[kMaxTargets];
    char shown[kProcQuitNameMax];
    Boolean skipped_self = false;
    int found;
    int asked = 0;
    int i;

    if (!now_proc_quit_parse(arg, &args, msg, cap)) {
        return kProcQuitBadArgs;
    }

    found = gather_targets(args.name, targets, &skipped_self, true);
    if (found < 0) {
        snprintf(msg, (size_t)cap,
                 "quit: more than %d processes are named \"%.31s\"",
                 kMaxTargets, args.name);
        return kProcQuitAmbiguous;
    }
    if (found == 0) {
        if (skipped_self) {
            snprintf(msg, (size_t)cap,
                     "quit: NOW will not ask itself to quit - use File > Quit");
            return kProcQuitRefusedSelf;
        }
        /* Not an error. The asked-for state is "not running", and it
           already holds - which is exactly what a redeploy loop wants to
           hear when the previous pass already took the process down. */
        snprintf(msg, (size_t)cap,
                 "quit: nothing named \"%.31s\" is running (see \"ps\")",
                 args.name);
        return kProcQuitNotRunning;
    }
    if (found > 1 && !args.all) {
        snprintf(msg, (size_t)cap,
                 "quit: %d processes are named \"%.24s\" - add --all",
                 found, args.name);
        return kProcQuitAmbiguous;
    }

    pascal_to_c(targets[0].name, shown, sizeof shown);

    for (i = 0; i < found; ++i) {
        /* The race the contract warns about: the listing above is already
           in the past. Re-validate, and treat a target that died in the
           gap as one we no longer need to ask. */
        if (!target_is_live(&targets[i])) {
            continue;
        }
        if (now_proc_ask_quit(&targets[i].psn) != noErr) {
            snprintf(msg, (size_t)cap,
                     "quit: the Mac would not deliver a quit request to "
                     "\"%.31s\"", shown);
            return kProcQuitSendFailed;
        }
        ++asked;
    }
    if (asked == 0) {
        snprintf(msg, (size_t)cap,
                 "quit: \"%.31s\" went away before it could be asked", shown);
        return kProcQuitNotRunning;
    }
    if (!args.confirm) {
        snprintf(msg, (size_t)cap,
                 "quit: asked \"%.31s\" to quit; NOT confirmed (--no-wait)",
                 shown);
        return kProcQuitSent;
    }

    /* Confirm by re-reading the Process Manager, which is the only thing
       that can tell a granted quit from a declined one. */
    {
        UInt32 started = TickCount();
        UInt32 deadline = started + (UInt32)args.wait_secs * 60;
        int live;
        long elapsed;

        for (;;) {
            live = 0;
            for (i = 0; i < found; ++i) {
                if (target_is_live(&targets[i])) {
                    ++live;
                }
            }
            if (live == 0 || TickCount() >= deadline) {
                break;
            }
            yield_ticks(2);
        }
        elapsed = (long)(TickCount() - started) * 100 / 60;   /* tenths */
        if (live == 0) {
            if (found > 1) {
                snprintf(msg, (size_t)cap,
                         "quit: %d processes named \"%.20s\" are gone "
                         "(%ld.%ld s)", found, shown, elapsed / 10,
                         elapsed % 10);
            } else {
                snprintf(msg, (size_t)cap, "quit: \"%.31s\" is gone (%ld.%ld s)",
                         shown, elapsed / 10, elapsed % 10);
            }
            return kProcQuitGone;
        }
        /* The outcome that must never read as success: the event was
           delivered and the process is still there. An app with an unsaved
           document is sitting on a Save dialog right now. */
        snprintf(msg, (size_t)cap,
                 "quit: \"%.24s\" is STILL RUNNING after %d s - declined, or "
                 "asking about unsaved work", shown, args.wait_secs);
        return kProcQuitStillRunning;
    }
}

/* --- front by name ------------------------------------------------------- */

/* The name, trimmed and unquoted. `front` has no flags, so this is the
   whole grammar and it does not need proc_quit_args.c: that parser exists
   to keep --all / --wait / --no-wait from being read as the last word of
   a process name, and there is nothing here to confuse. It still enforces
   the same 31-character ceiling, because a longer argument cannot match
   any process and saying so beats comparing a truncation. */
static Boolean front_name(const char *arg, char *out, long cap, char *msg,
                          long msg_cap)
{
    long len;

    while (*arg == ' ' || *arg == '\t') {
        ++arg;
    }
    len = (long)strlen(arg);
    while (len > 0 && (arg[len - 1] == ' ' || arg[len - 1] == '\t')) {
        --len;
    }
    if (len >= 2 && arg[0] == '"' && arg[len - 1] == '"') {
        ++arg;
        len -= 2;
    }
    if (len == 0) {
        snprintf(msg, (size_t)msg_cap,
                 "front: what? (the name of a running process, as \"ps\" "
                 "shows it)");
        return false;
    }
    if (len >= cap) {
        snprintf(msg, (size_t)msg_cap,
                 "front: no process name is longer than %ld characters",
                 cap - 1);
        return false;
    }
    memcpy(out, arg, (size_t)len);
    out[len] = '\0';
    return true;
}

static Boolean is_frontmost(const ProcessSerialNumber *psn)
{
    ProcessSerialNumber front;
    Boolean same = false;

    if (GetFrontProcess(&front) != noErr) {
        return false;
    }
    (void)SameProcess(psn, &front, &same);
    return same;
}

NowProcFrontOutcome now_proc_front_by_name(const char *arg, char *msg,
                                           long cap)
{
    QuitTarget targets[kMaxTargets];
    char name[kProcQuitNameMax];
    char shown[kProcQuitNameMax];
    Boolean skipped_self = false;
    int found;

    if (!front_name(arg != NULL ? arg : "", name, (long)sizeof name, msg,
                    cap)) {
        return kProcFrontBadArgs;
    }

    /* skip_self false: see proc_actions.h. NOW is a fair target here. */
    found = gather_targets(name, targets, &skipped_self, false);
    if (found < 0) {
        snprintf(msg, (size_t)cap,
                 "front: more than %d processes are named \"%.31s\"",
                 kMaxTargets, name);
        return kProcFrontAmbiguous;
    }
    if (found == 0) {
        /* NOT ok, where quit's equivalent is: the asked-for state does
           not hold and cannot be made to. */
        snprintf(msg, (size_t)cap,
                 "front: nothing named \"%.31s\" is running (see \"ps\")",
                 name);
        return kProcFrontNotRunning;
    }
    if (found > 1) {
        /* No --all: "bring them all to the front" is not a thing one
           screen can do, so several matches is a refusal with no flag to
           override it. */
        snprintf(msg, (size_t)cap,
                 "front: %d processes are named \"%.24s\" - narrow it down",
                 found, name);
        return kProcFrontAmbiguous;
    }

    pascal_to_c(targets[0].name, shown, sizeof shown);

    /* The same race the contract warns about: the walk above is already
       in the past. */
    if (!target_is_live(&targets[0])) {
        snprintf(msg, (size_t)cap,
                 "front: \"%.31s\" went away before it could be fronted",
                 shown);
        return kProcFrontNotRunning;
    }
    if (now_proc_bring_to_front(&targets[0].psn) != noErr) {
        snprintf(msg, (size_t)cap,
                 "front: the Mac would not bring \"%.31s\" forward", shown);
        return kProcFrontRefused;
    }

    /* noErr means the switch was SCHEDULED. It happens when we yield, and
       GetFrontProcess is the only thing that can tell the two apart. */
    {
        UInt32 deadline = TickCount() + (UInt32)kProcFrontWaitSecs * 60;

        for (;;) {
            if (is_frontmost(&targets[0].psn)) {
                snprintf(msg, (size_t)cap, "front: \"%.31s\" is frontmost",
                         shown);
                return kProcFrontDone;
            }
            if (TickCount() >= deadline) {
                break;
            }
            yield_ticks(2);
        }
    }
    snprintf(msg, (size_t)cap,
             "front: asked for \"%.24s\"; it is NOT frontmost after %d s",
             shown, kProcFrontWaitSecs);
    return kProcFrontUnconfirmed;
}

/* --- hide / show by name -------------------------------------------------- */

Boolean now_proc_hide_available(const char **which)
{
#if NOW_HAVE_SHOWHIDEPROCESS
    /* A function designator is never null in standard C, so GCC folds
       `ShowHideProcess == 0` to false and optimises the whole guard away -
       verified by reading the generated PowerPC at -O1 and -O2, where the
       comparison simply is not there. Laundering the address through a
       volatile local defeats that: the compiler must load the pointer from
       the TOC word CFM actually filled in, and an unresolved weak import
       is kUnresolvedCFragSymbolAddress (zero) in exactly that word.

       Both symbols or neither - see proc_actions.h. */
    void *const volatile show_hide = (void *)ShowHideProcess;
    void *const volatile is_visible = (void *)IsProcessVisible;

    if (show_hide == (void *)kUnresolvedCFragSymbolAddress) {
        if (which != NULL) {
            *which = "ShowHideProcess";
        }
        return false;
    }
    if (is_visible == (void *)kUnresolvedCFragSymbolAddress) {
        if (which != NULL) {
            *which = "IsProcessVisible";
        }
        return false;
    }
    return true;
#else
    /* Built against an import library that does not carry the symbols at
       all, so there is nothing to be weak about. Same refusal, one layer
       earlier, and it names the same thing a person would look for. */
    if (which != NULL) {
        *which = "ShowHideProcess";
    }
    return false;
#endif
}

NowProcHideOutcome now_proc_hide_by_name(const char *arg, char *msg, long cap)
{
    ProcHideArgs args;
    QuitTarget targets[kMaxTargets];
    char shown[kProcQuitNameMax];
    Boolean skipped_self = false;
    const char *missing = "ShowHideProcess";
    int found;

    if (!now_proc_hide_parse(arg, &args, msg, cap)) {
        return kProcHideBadArgs;
    }
    if (!now_proc_hide_available(&missing)) {
        /* By name, and with the reason, because "hide did nothing" is the
           report this verb exists to stop anyone filing again. */
        snprintf(msg, (size_t)cap,
                 "hide: this Mac's CarbonLib does not export %.24s - it "
                 "needs CarbonLib 1.5 or later", missing);
        return kProcHideUnavailable;
    }

    /* skip_self false: NOW is a fair target here, as it is for `front`.
       See proc_actions.h. */
    found = gather_targets(args.name, targets, &skipped_self, false);
    if (found < 0) {
        snprintf(msg, (size_t)cap,
                 "hide: more than %d processes are named \"%.31s\"",
                 kMaxTargets, args.name);
        return kProcHideAmbiguous;
    }
    if (found == 0) {
        /* NOT ok, and not `quit`'s reading of the same sentence: hiding
           something that is not running is not a state that can hold. */
        snprintf(msg, (size_t)cap,
                 "hide: nothing named \"%.31s\" is running (see \"ps\")",
                 args.name);
        return kProcHideNotRunning;
    }
    if (found > 1) {
        /* No --all. Hiding an arbitrary one of several is worse than doing
           nothing, and the same refusal `front` makes. */
        snprintf(msg, (size_t)cap,
                 "hide: %d processes are named \"%.24s\" - narrow it down",
                 found, args.name);
        return kProcHideAmbiguous;
    }

    pascal_to_c(targets[0].name, shown, sizeof shown);

    /* The race the contract warns about: the walk above is already in the
       past, and a PSN can be reused. */
    if (!target_is_live(&targets[0])) {
        snprintf(msg, (size_t)cap,
                 "hide: \"%.31s\" went away before it could be reached",
                 shown);
        return kProcHideNotRunning;
    }

#if NOW_HAVE_SHOWHIDEPROCESS
    if (args.action == kProcHideActionStatus) {
        Boolean visible = IsProcessVisible(&targets[0].psn);

        snprintf(msg, (size_t)cap, "hide: \"%.31s\" is %s", shown,
                 visible ? "visible" : "hidden");
        return visible ? kProcHideReadVisible : kProcHideReadHidden;
    }

    {
        Boolean want = (Boolean)(args.action == kProcHideActionShow);
        UInt32 deadline = TickCount() + (UInt32)kProcHideWaitSecs * 60;
        OSErr err = ShowHideProcess(&targets[0].psn, want);

        if (err != noErr) {
            /* Report the code. It is documented to refuse for some
               processes and nobody here knows which, so swallowing it
               would throw away the only evidence of why. */
            snprintf(msg, (size_t)cap,
                     "hide: the Mac would not %s \"%.24s\" (error %d)",
                     want ? "show" : "hide", shown, (int)err);
            return kProcHideRefused;
        }
        for (;;) {
            /* Normalised on both sides: a classic Toolbox Boolean is
               "nonzero is true", not "1 is true", and comparing the two
               bytes directly would read a true of 0xFF as disagreement. */
            Boolean now_visible =
                (Boolean)(IsProcessVisible(&targets[0].psn) != 0);

            if (now_visible == want) {
                snprintf(msg, (size_t)cap, "hide: \"%.31s\" is now %s", shown,
                         want ? "visible" : "hidden");
                return want ? kProcHideShown : kProcHideHidden;
            }
            if (TickCount() >= deadline) {
                break;
            }
            yield_ticks(2);
        }
        /* Accepted and nothing moved. Never reported as done: the whole
           point of reading the flag back is that a dispatch may not claim
           an effect. */
        snprintf(msg, (size_t)cap,
                 "hide: asked to %s \"%.20s\"; it is still %s after %d s",
                 want ? "show" : "hide", shown, want ? "hidden" : "visible",
                 kProcHideWaitSecs);
        return kProcHideUnconfirmed;
    }
#else
    /* Unreachable: now_proc_hide_available() returned false above. Here so
       the file compiles the same shape either way. */
    snprintf(msg, (size_t)cap,
             "hide: this build has no ShowHideProcess import");
    return kProcHideUnavailable;
#endif
}

/* --- this application's own visibility ----------------------------------

   See proc_actions.h for the measurement this exists for. Deliberately
   silent: every caller is a route with its own reporting, and a machine
   whose CarbonLib cannot show a process is one where the window simply
   does not come back — which the caller's own read-back already says. */
void now_proc_show_self(void)
{
#if NOW_HAVE_SHOWHIDEPROCESS
    ProcessSerialNumber self;

    if (!now_proc_hide_available(NULL)) {
        return;
    }
    if (GetCurrentProcess(&self) != noErr) {
        return;
    }
    /* Normalised the way now_proc_hide_by_name normalises it: a classic
       Toolbox Boolean is "nonzero is true". */
    if (IsProcessVisible(&self) != 0) {
        return;
    }
    (void)ShowHideProcess(&self, true);
#endif
}
