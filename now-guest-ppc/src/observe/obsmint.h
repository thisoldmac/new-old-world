#ifndef NOW_OBSMINT_H
#define NOW_OBSMINT_H

/* Turning an address a walk is HOLDING into a reference - the seam the
   scene walk mints through.

   WHY THERE IS A SECOND CALLER AT ALL. There are two walks over this
   machine and there is one registry. observe.c walks to answer a person
   asking "what is there", and emits a tree with a reference beside every
   node. scene_walk.c walks to produce IR v1, and until now emitted the
   same controls with NO reference - so a rendered scene drew buttons
   nobody could name, and every act against one was refused as
   `needsObservation`. Both walks see the same elements; only one of them
   was allowed to say so.

   The fix is NOT a second minter. That defect already happened once here
   (src/act/act_ref.c minted the same token shape from a second table)
   and the whole reference layer was unified to remove it. This file is
   the one place a walk turns an address into a reference, it lives
   inside src/observe/ with the registry, and it is what scene_walk.c
   calls. tests/one_minter_source_test.py names it explicitly.

   WHAT A CALLER MUST GIVE UP TO USE IT. Nothing about the identity is
   taken on trust: the titles, the occurrence numbers and the
   fingerprints are re-derived HERE, from the same chain a resolution
   will walk, by the same arithmetic. A caller passes an address; it does
   not get to say what that address is called.

   AND THE BOUND THAT MATTERS. Resolution walks at most
   kNowAxResolveMaxWindows windows and kNowAxResolveMaxControls controls
   before it answers NotFound. An element past either bound therefore
   CANNOT be resolved, so minting a reference for it would hand a caller
   a string that is decoration rather than an address. Every call below
   refuses instead, and a refusal is an ABSENT key on the producer's
   side - which reads as "not minted", which is true.

   Toolbox-free, like everything else that decides: the memory seam, the
   process fingerprint and the clock all arrive as arguments, which is
   why a native test can mint a reference and then resolve it. */

#include "axwalk.h"
#include "obsref.h"

/* One walk's minting state. `registry` is the session's one registry,
   never a copy; the rest is re-aimed per process. */
typedef struct {
    NowObsRegistry    *registry;
    const NowAxMemory *memory;
    unsigned long      window_list;
    unsigned long      psn_hi;
    unsigned long      psn_lo;
    unsigned long      process_fingerprint;
    unsigned long      ticks;          /* the caller's clock, at mint */
    unsigned long      granted;        /* references handed out */
    unsigned long      refused;        /* elements this walk could not name */
} NowObsWalk;

/* Opens the walk and its registry epoch. Everything minted or interned
   between here and now_obs_walk_end is safe from this walk's own
   eviction; past the table the calls below refuse rather than evict
   (obsref.h). A NULL registry is legal and makes every call below a
   refusal - which is how a producer that has no reference layer
   available emits a scene with every `ref` absent rather than a scene
   with invented ones. */
void now_obs_walk_begin(NowObsWalk *walk, NowObsRegistry *registry);

/* Aims the walk at ONE process. Called again per process; the epoch
   stays open across all of them, because the bound that matters is the
   whole scene's, not one application's. */
void now_obs_walk_aim(NowObsWalk *walk, const NowAxMemory *memory,
                      unsigned long window_list, unsigned long psn_hi,
                      unsigned long psn_lo,
                      unsigned long process_fingerprint, unsigned long ticks);

/* Closes the epoch. The references stay valid; they merely become
   evictable by the next walk. */
void now_obs_walk_end(NowObsWalk *walk);

/* A reference for one window / one control of one window, written to
   `out` (at least kNowObsTokenMax bytes). Returns 1 with `out` set, or 0
   - and then this element HAS no reference and the producer must leave
   the key absent rather than emit an empty string.

   It returns 0 for every reason an element cannot honestly be named: no
   registry, no seam, an address not on this process's chain, a chain
   that failed validation or pointed back at itself, an element past the
   resolver's own bounds, or a registry with no slot left this walk. */
int now_obs_walk_window_ref(NowObsWalk *walk, unsigned long window_address,
                            char *out, size_t cap);
int now_obs_walk_control_ref(NowObsWalk *walk, unsigned long window_address,
                             unsigned long control_handle, char *out,
                             size_t cap);

#endif /* NOW_OBSMINT_H */
