#ifndef NOW_OBSERVE_H
#define NOW_OBSERVE_H

/* The reference layer's four surfaces, and the one call the act plane
   makes.

   THE SPLIT, which is the same one peek_oracle.c/peek_read.c and
   axwalk/axprocess.c already make: everything that DECIDES is pure and
   lives next door (obsref.c, obsresolve.c); this file only obtains -
   which processes exist, where their partitions are, what the anchor
   plane says. Nothing here is a policy, and nothing next door touches
   the Toolbox. It is the only reason the interesting half of a
   foreign-memory reference layer is testable without a Macintosh.

   THE FOUR SURFACES:

     observe   walk, and MINT a reference for every window and control
               found. The only thing in the product that creates a
               reference - which is what makes "observation-minted"
               true rather than aspirational.
     handle    take one reference back to a live WindowPtr /
               ControlHandle, revalidating first, refusing distinctly.
     axtree    the read surface over the same walk: the tree, with the
               references already minted for it.
     axsnap    the cheap one - who is front, whether the plane can see
               it, and how many references are live. No walk.

   SELF IS NOT OBSERVABLE HERE, and it is a limit to state rather than
   hide: NOW is a Carbon application, so its own window records are not
   at the classic offsets this walk reads (axprocess.h says the same).
   Asking for our own PSN binds and walks to nothing. A reference to
   NOW's own UI would need the Window Manager, not a foreign walk. */

/* NOTHING HERE IS REGISTERED YET, and that is deliberate rather than
   unfinished: this layer was built while three other threads held
   src/commands/, src/core/wire.c and contract/, and a fifth hand in
   those files is how a fold-in produces conflicts instead of code. What
   registration costs, exactly, in the order it has to happen:

     1. contract/asyncapi.yaml, x-commands: four entries - `observe`,
        `handle`, `axtree`, `axsnap`. A command not declared there is
        looked up by the host's capability ledger, missed, and reported
        permanently unavailable in a sentence that reads as a fact about
        the Macintosh (MirrorActProjections.swift records that exact
        failure happening). `handle` takes a required string `ref`;
        `observe` and `axtree` an optional string `scope` of
        "front" (default) or "all"; `axsnap` takes nothing.
     2. src/commands/cmd_help.c: four rows with `wire` = 1. That table is
        how the host settles whether a connected guest serves a command,
        so a row missing here makes the verb unavailable even once it is
        served.
     3. src/commands/commands.c: `#include "observe.h"` and four branches
        in now_command_run - each one call, because each function below
        writes the whole command.result itself:

            now_observe_command(request_json, id, out, cap);
            now_observe_handle_command(request_json, id, out, cap);
            now_observe_axtree_command(request_json, id, out, cap);
            now_observe_axsnap_command(request_json, id, out, cap);

     4. src/main.c: now_observe_init() at startup. OPTIONAL - every
        entry point below arms the registry lazily - but doing it early
        seeds the session secret from a wider clock than the first
        request's, and the seed is the reason a reference cannot be
        forged.

   WHAT THE ACT PLANE CALLS is neither of the JSON surfaces: it is
   now_observe_resolve_window / now_observe_resolve_element, below, and
   the contract is that a verdict other than kNowObsOk means the act is
   refused with `why` - not retried, not re-derived from the reference's
   titles, and never aimed at whatever happens to be frontmost. */

#include <Carbon.h>

#include "obsresolve.h"

/* Arms the session registry. Call once, at startup, before anything can
   ask for a reference. Safe to call twice; the second call is ignored,
   because re-seeding would silently invalidate every live reference. */
void now_observe_init(void);

/* The resolution the ACT PLANE consumes. On kNowObsOk - and only then -
   `window` and `control` are live and may be dispatched to; on every
   other verdict they are NULL and `why` says which check refused.

   `control` is NULL for a window reference by construction, not by
   failure: a window reference names no control, and a caller that needs
   one should have asked for an element reference. */
typedef struct {
    NowObsVerdict       verdict;
    NowObsWhy           why;
    ProcessSerialNumber psn;
    WindowPtr           window;
    ControlHandle       control;
    NowAxResolved       detail;    /* bounds, titles, z-order; Ok only */
} NowObsHandle;

/* Resolve one reference. `len` may be 0 to mean strlen(reference).
   These are the two calls the act plane makes before it dispatches
   anything, and the contract is blunt: if verdict is not kNowObsOk,
   there is nothing to act on and the act must be refused with `why`
   rather than retried, re-derived, or aimed at whatever is frontmost. */
void now_observe_resolve_window(const char *reference, long len,
                                NowObsHandle *out);
void now_observe_resolve_element(const char *reference, long len,
                                 NowObsHandle *out);

/* The four command surfaces. Each writes ONE complete command.result
   JSON message into out, echoing id, exactly as commands.c's own
   handlers do - so registering them is one table row and one call each,
   with no envelope logic on the caller's side.

   `request_json` is the raw command.request (may be NULL). observe and
   axtree read an optional "scope" of "front" (default) or "all"; handle
   reads a required "ref". */
void now_observe_command(const char *request_json, long id, char *out,
                         long cap);
void now_observe_handle_command(const char *request_json, long id, char *out,
                                long cap);
void now_observe_axtree_command(const char *request_json, long id, char *out,
                                long cap);
void now_observe_axsnap_command(const char *request_json, long id, char *out,
                                long cap);

#endif /* NOW_OBSERVE_H */
