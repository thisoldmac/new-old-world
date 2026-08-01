#ifndef NOW_MACH_ACTIVATE_ARGS_H
#define NOW_MACH_ACTIVATE_ARGS_H

/* `activate` - front a process BY IDENTITY.
   ------------------------------------------------------------------
   NOW already fronts a process by NAME (`front`, proc_actions.h), and
   that verb stays exactly as it is. This one is not a second spelling of
   it; it is the other half of a distinction this project makes
   everywhere else:

     A NAME can be ambiguous, and `front` refuses rather than guessing
     when two things match. Two copies of the same application, or a
     document window's owner versus a helper, are a name collision a
     person can shrug at and a driver cannot.

     A PSN names ONE process. It is what an observation MINTS - the app
     list, the scene's per-process rows and the switcher all carry it -
     and addressing the thing you observed rather than the thing whose
     name matches is the same identity-not-position rule the act plane's
     references exist for.

   There is exactly ONE SetFrontProcess in this guest and it is
   now_proc_bring_to_front(). This verb composes around it; it does not
   re-implement it. That is the difference between a second addressing
   mode and a second implementation, and only the first one is wanted.

   THE HOST ALREADY SENDS THIS. MirrorKit's ActionDispatcher answers a
   click on an Application-menu row with a request named `activate`
   carrying `serialHi`/`serialLo` (ActionModel.click -> .activate(psn:)).
   Nothing in this guest served that name, so the switcher path had no
   guest to talk to. The wire name and the two argument names here are
   the host's, unchanged, for that reason.

   Toolbox-free on purpose, like proc_quit_args.c and act_args.c: the
   parse and the outcome vocabulary are compiled by the host cc, so the
   ways they can be wrong get watched failing in
   now-guest-ppc/tests/mach_activate_args_test.c. */

/* A parsed process serial number, and whether one was really given.
   A PSN of 0.0 is kNoProcess and is NOT a legal target - which is why
   presence is carried rather than inferred from a zero. */
typedef struct {
    unsigned long hi;
    unsigned long lo;
    int           present;
} NowMachPsnArg;

/* Parse the request. The typed fields `serialHi` / `serialLo` win; a
   console line of two whole numbers ("activate 0 8781") is the human
   spelling and is read only when the typed fields are absent, which is
   the same precedence every other command in this guest uses.

   Returns 1 when a usable PSN was found. `out` is always written. */
int now_mach_psn_parse(const char *request_json, const char *line,
                       NowMachPsnArg *out);

/* Did the caller TRY to name a process at all?

   For the verbs where a PSN is optional (`actselftest` means the front
   process when none is given), "no PSN" and "a PSN I could not read" are
   different requests and must not share an answer: silently testing the
   front process because the caller's serial number was malformed
   produces a confident verdict about the wrong process. Presence is
   asked here, once, rather than inferred from a failed parse. */
int now_mach_psn_offered(const char *request_json, const char *line);

/* What happened, in the closed set a caller may see. The order matters
   in one place only: everything at or below kNowMachActivateAlreadyFront
   means the machine is in the asked-for state. */
typedef enum {
    kNowMachActivateDone = 0,      /* asked, and confirmed frontmost      */
    kNowMachActivateAlreadyFront,  /* it was already there; nothing asked */
    /* Asked, and not observable yet. A cooperative switch happens when we
       yield, so this is a real and expected reading - not a failure, and
       not a success either. It keeps its own word for the same reason
       kProcFrontUnconfirmed does. */
    kNowMachActivateUnconfirmed,
    /* Refused before anything was asked. */
    kNowMachActivateNoSuchProcess, /* the PSN names nothing alive         */
    kNowMachActivateBackgroundOnly,/* modeOnlyBackground: it cannot front */
    kNowMachActivateRefused,       /* SetFrontProcess itself failed       */
    kNowMachActivateBadArgs
} NowMachActivateOutcome;

/* The facts the Toolbox half comes back with, and nothing else:
   whether the process was found, whether it declares itself
   background-only, whether it was already frontmost, whether
   SetFrontProcess was called and what it returned, and whether the
   re-read then named it.

   `set_err` is an OSErr as a plain int so this file needs no Carbon. */
typedef struct {
    int found;
    int background_only;
    int was_front;
    int set_called;
    int set_err;
    int confirmed_front;
} NowMachActivateFacts;

/* Judge them. Pure. */
NowMachActivateOutcome now_mach_activate_verdict(
    const NowMachActivateFacts *f);

/* Is the machine in the asked-for state? One place, so three callers
   cannot each pick a different boundary. */
int now_mach_activate_is_front(NowMachActivateOutcome o);

/* The wire code and the sentence. Never "unknown" for a declared
   outcome. */
const char *now_mach_activate_code(NowMachActivateOutcome o);
const char *now_mach_activate_message(NowMachActivateOutcome o);

#endif /* NOW_MACH_ACTIVATE_ARGS_H */
