#ifndef NOW_AXRESOLVE_H
#define NOW_AXRESOLVE_H

/* Naming an element without naming a pointer, and finding it again.

   Ported from archive/mirror-standalone-2026-08-09/guest/app/src/axresolve.c and the identity half of
   its axref.c. What this module owns is the policy every consumer of
   the walk needs and none should re-invent: traversal limits, cycle
   detection, what "the second button called OK" means, and how a
   reference goes stale.

   WHAT DELIBERATELY DID NOT CROSS. Upstream's axref.c also carries a
   TEXT GRAMMAR - `ax2/<psn>/window:<title>#<n>/control:<title>#<n>/
   node:<hash>`, with a percent-encoder and a strict parser. That is a
   wire format, and the wire is the one thing the integration plan's
   stop condition says stays ours ("Mirror-shaped families in NOW's
   conventions, not a verbatim copy of its protocol"). NOW's scene IR
   already spells an element id its own way (scene.h: `<psn>/<title>
   #<idx>`), and two grammars for one concept is how a fold-in rots. So
   the STRUCT and the FINGERPRINT cross - they are semantics - and the
   spelling stays with whoever writes the wire.

   THE FINGERPRINT IS THE INTERESTING PART. Titles and occurrences name
   an element the way a person would, which is exactly why they survive
   a redraw and exactly why they can silently start naming a DIFFERENT
   element after the window list changes. The fingerprint is an opaque
   hash of the addresses the reference was minted against; when it no
   longer matches, the title still resolves but the thing behind it has
   moved, and the honest answer is Stale rather than a confident wrong
   one. That is the same instinct as the anchor oracle's Ambiguous.

   Toolbox-free, like everything else here. */

#include "axwalk.h"

enum {
    /* Bounds on a walk over another process's heap. Reaching either is
       NotFound rather than a partial answer: a resolver that gave up
       halfway and reported success would be resolving to whatever it
       happened to have seen. */
    kNowAxResolveMaxWindows = 16,
    /* 32 UNTIL 2026-08-07, AND IT WAS THE WHOLE OF WHY A TAB COULD NOT
       BE DRIVEN. A control past this bound cannot be resolved, so
       `now_obs_walk_control_ref` refuses to mint for it and the scene
       reports it with no `ref` - correctly, because a token that cannot
       resolve is decoration. Measured on the emulator: the Appearance
       control panel's chain is 73 controls long and the TAB STRIP is
       number 71, so the one control a person most wants to click was the
       far side of this number. 41 of that desktop's 82 controls carried
       a reference and the rest were addressable by nothing.

       It is now `kNowSceneMaxControls`, and stating it as the same
       number is the point rather than a coincidence: what a scene can
       CARRY and what an act can REACH were two independent constants,
       and the smaller one silently decided the product's drivability
       without appearing in any claim. This is the same defect shape as
       the control-frame cap that lived in three places. */
    kNowAxResolveMaxControls = 96
};

typedef enum {
    kNowAxResolveOk = 0,
    kNowAxResolveNotFound = -10,
    kNowAxResolveCycle = -11,     /* the chain pointed back at itself */
    kNowAxResolveStale = -12      /* found by name; the addresses moved */
} NowAxResolveStatus;

/* A pointer-free reference to one control inside one window of one
   process. `*_occurrence` is 0-based among elements sharing a title. */
typedef struct {
    unsigned long psn_hi;
    unsigned long psn_lo;
    unsigned char window_title[kNowAxTitleMax + 1];
    size_t        window_title_len;
    unsigned int  window_occurrence;
    unsigned char control_title[kNowAxTitleMax + 1];
    size_t        control_title_len;
    unsigned int  control_occurrence;
    unsigned long node_fingerprint;
} NowAxRef;

typedef struct {
    unsigned long   window_address;
    unsigned long   control_handle;
    unsigned int    window_z;          /* index in the window chain */
    unsigned int    visible_window_z;  /* index among VISIBLE windows */
    NowAxWindow     window;
    NowAxControl    control;
} NowAxResolved;

/* Occurrence counting, exposed because a producer walking the tree must
   assign the same numbers a resolver will later look for. One entry per
   distinct title; `next` returns this title's 0-based occurrence and
   bumps the count. */
typedef struct {
    unsigned long hash;
    unsigned int  occurrence_count;
    unsigned char length;
    unsigned char title[kNowAxTitleMax];
} NowAxTitleEntry;

typedef struct {
    NowAxTitleEntry *entries;
    unsigned int     count;
    unsigned int     capacity;
} NowAxTitleCounter;

void now_ax_title_counter_reset(NowAxTitleCounter *counter,
                                NowAxTitleEntry *entries,
                                unsigned int capacity);
int now_ax_title_counter_next(NowAxTitleCounter *counter, const void *title,
                              size_t length, unsigned int *occurrence);

/* The opaque node hash. Truncated to 32 bits deliberately: it is a
   change detector, never an identity. */
unsigned long now_ax_ref_fingerprint(unsigned long psn_hi,
                                     unsigned long psn_lo,
                                     unsigned long window_address,
                                     unsigned long control_handle);

/* Walks the window chain from `window_list` looking for the referenced
   control. Bounded, cycle-checked, and it refuses rather than guesses:
   a chain longer than the caps is NotFound, a repeated address is
   Cycle, and a title match whose addresses no longer hash to the
   reference's fingerprint is Stale. */
int now_ax_resolve_ref(const NowAxMemory *memory, unsigned long window_list,
                       const NowAxRef *ref, NowAxResolved *out);

#endif /* NOW_AXRESOLVE_H */
