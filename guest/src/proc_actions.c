#include "proc_actions.h"

#include <stdio.h>
#include <string.h>

#include <Carbon.h>

#include "proc_quit_args.h"
#include "wire.h"

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

/* Collects every live process named `want`, skipping NOW itself. Returns
   the count, or -1 if there are more matches than kMaxTargets.
   `skipped_self` says whether the walk passed over us, which is what
   tells "no such process" apart from "you asked us to quit ourselves". */
static int gather_targets(const char *want, QuitTarget *out,
                          Boolean *skipped_self)
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
        if (is_self) {
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

    found = gather_targets(args.name, targets, &skipped_self);
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
