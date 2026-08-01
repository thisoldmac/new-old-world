#ifndef NOW_OBSRESOLVE_H
#define NOW_OBSRESOLVE_H

/* Turning a reference back into a live element - or refusing, precisely.

   STALENESS IS REFUSED, NEVER REPAIRED. A window that closed and
   reopened is a DIFFERENT window even when it wears the same title in
   the same position, and a resolver that quietly re-aimed at the new one
   would be exactly the "whatever is frontmost" surface the reference
   exists to prevent, hidden behind a reference-shaped argument. So every
   check below fails closed, and none of them has a repair path.

   THE FIVE VERDICTS ARE THE VOCABULARY, taken from peek_oracle.h because
   this plane already has one set of words for "the honest answer is not
   a pointer" and a second would be a translation layer nobody maintains:

     Ok          the reference names this element, still
     NotFound    nothing here answers to it
     Ambiguous   more than one thing could, and nothing distinguishes
                 them - refused rather than guessed
     Mismatch    something answers, and contradicts the reference
     Stale       found by name; the addresses behind it moved

   A resolve that could not say WHICH of those failed would be worse than
   one that simply refused, because "it didn't work" is indistinguishable
   from "you named the wrong thing" and only one of those is the caller's
   bug. Each verdict therefore carries a `why` naming the exact check
   that stopped it, and the mapping from why to verdict is a table in one
   place rather than a judgement at each call site.

   Toolbox-free. It takes the bound seam, the oracle's answer and the
   process fingerprint as ARGUMENTS, which is why every one of the
   verdicts below - including the ones a real machine cannot be asked to
   produce on demand - is reachable from a host test. */

#include "axresolve.h"
#include "obsref.h"

typedef enum {
    kNowObsOk = 0,
    kNowObsNotFound,
    kNowObsAmbiguous,
    kNowObsMismatch,
    kNowObsStale
} NowObsVerdict;

/* Which check stopped it. The order is the order they run in. */
typedef enum {
    kNowObsWhyNone = 0,
    kNowObsWhyMalformed,        /* not a well-formed reference of this kind */
    kNowObsWhyUnminted,         /* well-formed, never minted here, or evicted */
    kNowObsWhyNoProcess,        /* the PSN names no live process */
    kNowObsWhyNoPlane,          /* the anchor plane is absent or unarmed */
    kNowObsWhyNoAnchor,         /* the process has not pumped since arming */
    kNowObsWhyOracleAmbiguous,  /* two anchor slots claim the partition */
    kNowObsWhyOracleMismatch,   /* the slot describes another address space */
    kNowObsWhyUnreadable,       /* bound, but the anchor's roots fail checks */
    kNowObsWhyProcessRecycled,  /* the PSN is live and is a DIFFERENT program */
    kNowObsWhyNoWindowList,     /* the process has no windows at all now */
    kNowObsWhyElementGone,      /* the title/occurrence names nothing now */
    kNowObsWhyCycle,            /* the chain pointed back at itself */
    kNowObsWhyUnreadableRecord, /* a record failed the memory boundary */
    kNowObsWhyAddressesMoved    /* found by name; the fingerprint disagrees */
} NowObsWhy;

/* How the process bound, in this layer's own words. The impure caller
   translates peek_read.c's NowPeekReadStatus into these, so nothing here
   has to include a Carbon-flavoured header to be tested. */
typedef enum {
    kNowObsBindOk = 0,
    kNowObsBindNoProcess,
    kNowObsBindNoPlane,
    kNowObsBindNoAnchor,
    kNowObsBindAmbiguous,
    kNowObsBindMismatch,
    kNowObsBindUnreadable
} NowObsBindStatus;

/* The machine as it is NOW, against which the reference is re-proved. */
typedef struct {
    NowObsBindStatus   bind;
    unsigned long      process_fingerprint;  /* recomputed this instant */
    unsigned long      window_list;          /* the process's chain head */
    const NowAxMemory *memory;               /* the validated read seam */
} NowObsLive;

typedef struct {
    NowObsVerdict verdict;
    NowObsWhy     why;
    /* Filled on Ok only. The other four leave it zeroed on purpose:
       there is no honest value to put in it, and a half-filled result is
       how a refusal gets acted on anyway. */
    NowAxResolved resolved;
} NowObsResolution;

/* Walks the window chain for a WINDOW reference: title and occurrence,
   bounded and cycle-checked exactly as now_ax_resolve_ref is, then the
   same fingerprint test with a zero control handle.

   This exists because now_ax_resolve_ref resolves all the way down to a
   control and a window reference has none - upstream hit the same wall
   and wrote the same second walk. Returns the kNowAxResolve* vocabulary
   so the two are interchangeable at the call site. */
int now_obs_resolve_window(const NowAxMemory *memory,
                           unsigned long window_list, const NowAxRef *ref,
                           NowAxResolved *out);

/* The whole path: shape, lookup, process identity, anchor verdict, walk,
   fingerprint. `out` is always fully initialised. */
void now_obs_resolve(const NowObsRegistry *registry, NowObsKind kind,
                     const char *text, size_t len, const NowObsLive *live,
                     NowObsResolution *out);

/* The verdict as a short lowercase word, and the reason as a sentence a
   person can act on. Never NULL, never allocates. */
const char *now_obs_verdict_name(NowObsVerdict verdict);
const char *now_obs_why_text(NowObsWhy why);

#endif /* NOW_OBSRESOLVE_H */
