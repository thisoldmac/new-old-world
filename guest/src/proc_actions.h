#ifndef NOW_PROC_ACTIONS_H
#define NOW_PROC_ACTIONS_H

#include <Processes.h>

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

#endif /* NOW_PROC_ACTIONS_H */
