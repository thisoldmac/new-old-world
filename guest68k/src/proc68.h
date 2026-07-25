/*
 * proc68.h - launching and quitting applications on the PowerBook, for
 * NOW-68K's first two commands.
 *
 * This is the testing loop, not a feature: every probe run on this machine is
 * deploy -> quit the FTP server -> measure -> relaunch, and doing that by hand
 * each cycle is what makes people stop running probes.
 *
 * THE ONE RULE THIS HEADER EXISTS TO ENFORCE: a quit reply must never claim
 * success for a process that is still running.
 *
 * Quitting is a REQUEST. It sends a 'quit' Apple Event, and an application
 * holding an unsaved document stops to ask the human about it and keeps
 * running - having received, understood, and declined. AESend returning noErr
 * means the event was DELIVERED and nothing more. So the composition is
 *
 *      list -> match by name -> re-validate the PSN -> ask -> RE-LIST
 *
 * and the re-list is the load-bearing step. A quit that reported success while
 * the target was still up would silently poison every measurement built on top
 * of it, from the first iteration, and the poisoning would look like flaky
 * hardware rather than a lying command.
 *
 * The PowerPC guest solved this first (branch thread/guest-quit-command); its
 * argument grammar lives Toolbox-free in guest/src/proc_quit_args.c precisely
 * so this client mirrors that file instead of deriving a second grammar that
 * drifts. Copy it, do not rewrite it.
 */
#ifndef NOW68K_PROC68_H
#define NOW68K_PROC68_H

#include <Processes.h>

/* What actually happened. The distinction between kProcGone and
 * kProcStillRunning is the whole point of the header - both mean the Apple
 * Event was delivered without error. */
typedef enum {
    kProcGone = 0,        /* asked, and it is no longer running - success */
    kProcNotRunning,      /* nothing matched; the asked-for state already held */
    kProcStillRunning,    /* asked, delivered, and it declined or is prompting */
    kProcSentUnconfirmed, /* asked, but the confirm window expired undecided */
    kProcAmbiguous,       /* several matches; refused rather than guess one */
    kProcRefusedSelf,     /* the target is us; a second copy is a fair target,
                             this instance is not */
    kProcUndeliverable,   /* AESend itself failed */
    kProcBadArgs
} ProcOutcome;

/* Ask the named application to quit, then confirm by re-listing.
 *
 * name is matched against running process names. The confirm wait must PUMP
 * THE WIRE while it runs (wire_idle) or the connection stalls for its whole
 * duration - and it must yield with an event mask of ZERO so it dequeues
 * nothing: taking a keystroke or a click here would steal input from the
 * front application and enter a nested dispatch we are not prepared for.
 * The target only processes the Apple Event when the cooperative scheduler
 * gets round to it, so yielding is not optional - without it the re-list
 * always reports still-running and the command always lies in the other
 * direction.
 *
 * Bounded: give up after wait_ticks and report kProcSentUnconfirmed rather
 * than blocking the guest indefinitely on someone else's Save dialog.
 *
 * detail receives a short ASCII sentence for the human - it is drawn in the
 * console and sent on the wire, so no high-bit characters. */
ProcOutcome proc_quit_named(const char *name, long wait_ticks,
                            char *detail, long detail_cap);

/* Launch an application by name. A bare name is resolved by an exact-name
 * search of the startup volume; a value containing a colon is treated as a
 * full HFS path and used directly. Non-APPL targets are refused rather than
 * launched, because launching a document opens whatever claims it and that is
 * not what the caller asked for.
 *
 * Returns 0 on success, else a Toolbox error worth reporting verbatim.
 * NOTE: a whole-volume catalog search is expensive on a 4 MB machine with a
 * BlueSCSI-backed disk, and a Finder-wide search has wedged this fleet before.
 * Bound the search and say so in detail if it was truncated. */
short proc_launch_named(const char *name, char *detail, long detail_cap);

/* The bare-name search's TOTAL wall-clock budget, in seconds, for the dev
 * settings file to shorten (n68_devsettings.h :: launch-search-seconds).
 *
 * This exists for one reason: the truncation report - the branch that says a
 * search ran out of time rather than pretending a clean "not found" - has
 * never executed on any machine, because the catalog on the machine we have
 * finishes in about two seconds against a twenty-second budget. A branch
 * nobody has watched is a branch nobody knows the behaviour of, and the way
 * to watch this one is to make the budget expire on purpose.
 *
 * The compiled-in default is the SHIPPED behaviour and is what these return
 * when no settings file says otherwise; a value outside
 * kN68DevLaunchSearchMin/MaxSecs is ignored, leaving the default in place,
 * because a settings file must never leave the application worse off than
 * having none. The per-call slice bound is NOT settable and does not move:
 * the double bound is what keeps a whole-volume search from wedging the
 * machine, and only the outer one is being made adjustable.
 *
 * A caller that shortens this MUST make the value visible to the human
 * (window.c prints it in the console and the log). A one-second budget makes
 * `launch` fail to find applications that are really there, and the only
 * thing worse than that in the lab is that happening unannounced. */
void           proc_set_launch_search_seconds(unsigned short seconds);
unsigned short proc_launch_search_seconds(void);

/* Running processes, newest first, for the human and for the quit matcher.
 * Fills up to cap entries and returns the count. Names are Pascal strings
 * converted to C, truncated to 31 characters (the HFS limit they came from). */
typedef struct {
    char                name[32];
    ProcessSerialNumber psn;
} ProcEntry;

long proc_list(ProcEntry *out, long cap);

#endif /* NOW68K_PROC68_H */
