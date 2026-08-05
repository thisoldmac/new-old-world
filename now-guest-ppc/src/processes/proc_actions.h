#ifndef NOW_PROC_ACTIONS_H
#define NOW_PROC_ACTIONS_H

#include <Processes.h>

#include "proc_hide_args.h"        /* NowProcHideOutcome, and the vocabulary
                                      both faces render it through */

/* The two process actions that are honest on this platform, factored out
   so the Processes page (acting on its selection) and the host-driven
   wire verbs (acting on a PSN off the wire) share ONE implementation
   rather than two copies of the same Apple Event. */

/* Bring a process to the front. Thin over SetFrontProcess. */
OSErr now_proc_bring_to_front(const ProcessSerialNumber *psn);

/* Ask a process to quit: a 'quit' Apple Event it is free to decline or
   take its time over. noErr means the event was SENT, never that the
   application has gone. */
OSErr now_proc_ask_quit(const ProcessSerialNumber *psn);

/* --- one process by name, for a caller that will not act on it ----------

   `transitions start Finder` needs a PSN and nothing else: it hands the
   resolved A5 to a resident and never sends the process an event. That
   is a smaller question than quit's or front's, and it gets its own
   entry point rather than a second walk — the walk is the part that must
   not drift (see gather_targets), and a console that invented its own
   matcher is precisely what docs/command-parity.md forbids.

   Ambiguity is REFUSED rather than resolved to the first match. Arming a
   resident inside whichever SimpleText the Process Manager happened to
   list first is a wrong answer that looks like a right one. */
typedef enum {
    kProcFindOne = 0,         /* exactly one live process, `psn` written */
    kProcFindNotRunning,      /* nothing by that name is running         */
    kProcFindAmbiguous,       /* several matches; this Mac will not guess */
    kProcFindNoName           /* an empty argument names nothing         */
} NowProcFindOutcome;

/* Writes `psn` only on kProcFindOne. NOW itself is a fair target here —
   reading a process is not quitting it. */
NowProcFindOutcome now_proc_find_by_name(const char *want,
                                         ProcessSerialNumber *psn);

/* --- quit by name: the composition ---------------------------------------

   process.quit takes a PSN, and a PSN is only meaningful while the
   process it names is alive. A person (or an agent's measurement loop)
   has a NAME. Bridging those is a composition — list, match, quit,
   re-list — and every step of it can fail differently:

     no match          nothing by that name is running
     several matches   quitting an arbitrary one is worse than refusing
     a race            the match died between the list and the send
     ourselves         quitting NOW mid-reply severs the reply
     declined          'quit' is a REQUEST; a dirty document wins

   The last one is the reason this returns an outcome rather than an
   OSErr. `now_proc_ask_quit` returning noErr means "the Apple Event was
   delivered" and nothing more; a measurement loop that reads that as
   "the process is gone" is poisoned from the first iteration. So the
   composition re-lists after asking and reports which actually
   happened.

   The wait is cooperative in the literal sense: the target only sees the
   event when the Process Manager next schedules it, and on classic Mac
   OS that only happens because WE yield. The loop therefore yields, and
   the guest's own window does not redraw for its duration (bounded,
   human-initiated, and recorded in docs/nested-loops.md). The wire stays
   serviced by now_wire_pump() when the console is the caller; when the
   WIRE is the caller the pump's reentrancy guard makes it a no-op, which
   is correct — conn_service is already on the stack. */

typedef enum {
    /* The machine is in the asked-for state. */
    kProcQuitGone = 0,        /* asked, and confirmed gone by a re-list */
    kProcQuitNotRunning,      /* nothing by that name was running at all */
    /* Asked, outcome not (or not yet) confirmed. */
    kProcQuitSent,            /* --no-wait: delivered, deliberately unverified */
    kProcQuitStillRunning,    /* still there at the deadline: declined or busy */
    /* Refused before anything was asked. */
    kProcQuitAmbiguous,       /* several matches and no --all */
    kProcQuitRefusedSelf,     /* the only match was NOW itself */
    kProcQuitBadArgs,         /* see proc_quit_args.h */
    kProcQuitSendFailed       /* the Apple Event Manager would not deliver */
} NowProcQuitOutcome;

/* Runs the whole composition for `arg` — the raw argument line, whose
   grammar is proc_quit_args.h's ("[--all] [--wait N | --no-wait] NAME",
   name last and whole). Writes one line of plain language into `msg`
   (bounded, NUL-terminated) for EVERY outcome including the good ones,
   because the caller renders that line and nothing else.

   Callers that only need "is the machine in the asked-for state" can
   test `outcome <= kProcQuitNotRunning`; a measurement loop must treat
   kProcQuitSent and kProcQuitStillRunning as NOT that. */
NowProcQuitOutcome now_proc_quit_by_name(const char *arg, char *msg, long cap);

/* --- front by name: the same composition, one verb gentler --------------

   process.front takes a PSN for the same reason process.quit does, and a
   person has the same NAME they had before, so the bridge is the same
   one: list, match, re-validate, act, re-check.

   Two things differ from quit, and both are decisions rather than
   omissions:

     NOT RUNNING IS A FAILURE HERE. quit's "nothing by that name" is
     ok:true, because the asked-for state (not running) already holds.
     You cannot front what is not there, and a caller whose next step
     assumes a window is up must not read it as done.

     NOW ITSELF IS A FAIR TARGET. quit refuses its own process because
     the reply would be severed mid-send; bringing NOW forward severs
     nothing, and "front NOW" is a reasonable thing for a person at a
     host console to type.

   The confirm is the same cooperative wait: SetFrontProcess returning
   noErr means the switch was SCHEDULED, and on this platform it happens
   when we yield. So this yields, briefly and boundedly, and then re-reads
   GetFrontProcess — the only thing that can tell a completed switch from
   an accepted request. */
typedef enum {
    kProcFrontDone = 0,       /* asked, and confirmed frontmost */
    kProcFrontUnconfirmed,    /* accepted, and not frontmost at the deadline */
    kProcFrontNotRunning,     /* nothing by that name is running */
    kProcFrontAmbiguous,      /* several matches; refused rather than guess */
    kProcFrontRefused,        /* SetFrontProcess itself failed */
    kProcFrontBadArgs
} NowProcFrontOutcome;

/* The seconds this waits for the switch to land before reporting
   kProcFrontUnconfirmed. Short on purpose: a process switch that has not
   happened in two seconds of yielded time is not going to, where a quit
   may legitimately sit on a Save dialog for much longer. */
#define kProcFrontWaitSecs 2

/* Runs the composition for `arg` — the whole rest of the line, which is
   the name; there are no flags. Writes one line of plain language into
   `msg` for EVERY outcome, good ones included, because the caller renders
   that line and nothing else. */
NowProcFrontOutcome now_proc_front_by_name(const char *arg, char *msg,
                                           long cap);

/* --- hide / show by name: the same composition, over a weak import -------

   Hiding an application is ordinary on a Macintosh — a person does it from
   the Application menu — and until this landed NOW had no route that
   reproduced it. Two are measured dead and written up in
   docs/open-issues.md: AppleScript's `set visible` is refused by the
   Finder's object model, and commanding menu -16489 dispatches without
   effect because the Application menu is SYSTEM-owned (MenuSelect calls
   SystemMenu, so a patch on the front application's MenuSelect never sees
   the choice). This is the Process Manager's own call, which is what the
   Application menu itself ends up in.

   THE CALL IS WEAK-IMPORTED AND MUST BE CHECKED BEFORE IT IS USED.
   ShowHideProcess and IsProcessVisible arrived in CarbonLib 1.5; our floor
   is 1.6, so they exist across the whole target range — but a weak import
   that a running CarbonLib cannot resolve is address zero, and calling it
   is a jump to zero. `now_proc_hide_available()` is that check, and the
   verb refuses BY NAME rather than crashing when it says no. They are one
   capability, not two: a mutation whose effect cannot be observed cannot
   settle, so if either symbol is missing the whole verb is unavailable.

   IsProcessVisible is not decoration. ProcessInfoRec has no visibility
   field at all, so nothing else on this machine can answer "is it hidden?"
   — and the flag it reads is the same one Mac OS 8's own
   AdjustApplicationMenu tests when it decides whether Hide is enabled. One
   flag, both readers.

   The bridge from a NAME is `quit`'s and `front`'s, unchanged: list,
   match, re-validate, act, read back. Refusing several matches is the same
   refusal for the same reason. NOW itself is a fair target, as it is for
   `front` and unlike `quit`: hiding this process severs nothing — a hidden
   application still gets scheduled, so the wire keeps being served — where
   quitting it would cut the reply mid-send. */

/* Whether this CarbonLib resolved BOTH symbols. When it returns false,
   `which` (if not NULL) is filled with the name of the first one that did
   not, so the refusal can say it. */
Boolean now_proc_hide_available(const char **which);

/* Runs the composition for `arg` — the whole rest of the line, whose
   grammar is proc_hide_args.h's. Writes one line of plain language into
   `msg` for EVERY outcome, good ones included, because the console renders
   that line and nothing else. */
NowProcHideOutcome now_proc_hide_by_name(const char *arg, char *msg,
                                         long cap);

/* The seconds the read-back is given before an accepted call is reported
   kProcHideUnconfirmed. Shorter than `front`'s: ShowHideProcess sets the
   layer's visible flag, and IsProcessVisible reads that flag rather than
   the screen, so the two should already agree on return. The wait is for
   the case where they do not — cheap when it is not needed, and the
   difference between "we asked" and "we watched it happen" when it is. */
#define kProcHideWaitSecs 1

#endif /* NOW_PROC_ACTIONS_H */
