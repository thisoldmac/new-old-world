#ifndef NOW_PROC_HIDE_ARGS_H
#define NOW_PROC_HIDE_ARGS_H

#include "proc_quit_args.h"      /* kProcQuitNameMax: a process name is a
                                    Str31, stated once for every verb that
                                    takes one */

/* `hide`'s argument line and its outcome vocabulary — everything about the
   verb that does not touch the Toolbox, so the host cc compiles it and the
   bounds get watched failing here rather than on the PowerBook
   (now-guest-ppc/tests/proc_hide_args_test.c).

   The grammar is `quit`'s, for `quit`'s reason: the NAME IS THE WHOLE REST
   OF THE LINE, so spaces need no quoting and any flag is therefore
   LEADING. A trailing flag is indistinguishable from the last word of a
   process name, and process names have spaces in them.

   The outcome vocabulary lives here rather than beside the composition
   because it is the half that can lie. An outcome maps to a state word, to
   an error code or none, and to ok true/false; the wire renders those and
   the console renders the sentence. Three renderings of one decision, and
   the decision is testable without a Macintosh — which matters more here
   than for `front`, because this verb's whole discipline is that it may
   not claim an effect it did not observe. */

typedef enum {
    kProcHideActionHide = 0,   /* the default: the verb is called `hide` */
    kProcHideActionShow,       /* --show */
    kProcHideActionStatus      /* --status: read it, change nothing */
} NowProcHideAction;

typedef struct {
    char name[kProcQuitNameMax];  /* the process name to match, never "" */
    NowProcHideAction action;
} ProcHideArgs;

/* Parses `arg` (everything after the command name) into `out`. Returns 1
   on success; on failure returns 0 and writes a one-line reason into `msg`
   (bounded by `cap`, NUL-terminated). `msg` may not be NULL. */
int now_proc_hide_parse(const char *arg, ProcHideArgs *out,
                        char *msg, long cap);

/* --- what happened -------------------------------------------------------

   Ordered so that "the machine is in the asked-for state, and we watched it
   get there" is everything below kProcHideUnconfirmed. A caller measuring
   this verb tests `outcome < kProcHideUnconfirmed`; nothing else may be read
   as done. */
typedef enum {
    /* Observed, by a read-back the same flag drives. */
    kProcHideHidden = 0,      /* asked to hide; IsProcessVisible says hidden */
    kProcHideShown,           /* asked to show; IsProcessVisible says visible */
    kProcHideReadHidden,      /* --status: it is hidden */
    kProcHideReadVisible,     /* --status: it is visible */
    /* Asked, and the read-back does not agree. */
    kProcHideUnconfirmed,     /* ShowHideProcess took it and nothing changed */
    /* Refused before anything was asked. */
    kProcHideNotRunning,      /* nothing of that name is running */
    kProcHideAmbiguous,       /* several matches; refused rather than guess */
    kProcHideRefused,         /* ShowHideProcess itself returned an OSErr */
    kProcHideUnavailable,     /* this CarbonLib does not export the call */
    kProcHideBadArgs
} NowProcHideOutcome;

/* The state word the wire reports, e.g. "hidden". Never NULL. */
const char *now_proc_hide_state(NowProcHideOutcome outcome);

/* The contract error code, or NULL when the result is ok. The two are one
   decision — `ok` is exactly "this returns NULL" — so they cannot drift
   into a reply that carries an error code and ok:true. */
const char *now_proc_hide_error(NowProcHideOutcome outcome);

/* What the read-back said, for the reply's own row: "yes", "no", or
   "unknown" when nothing was observed. A caller reads this rather than the
   sentence, and an outcome that observed nothing must not answer "no" —
   "not seen visible" is not "hidden". */
const char *now_proc_hide_visible_word(NowProcHideOutcome outcome);

#endif /* NOW_PROC_HIDE_ARGS_H */
