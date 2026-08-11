#ifndef NOW_ACT_INFLIGHT_H
#define NOW_ACT_INFLIGHT_H

/* One act at a time: the interlock that replaced an accident.
   ------------------------------------------------------------------
   The act plane is a SINGLE cell (contract/peek_table.h: `NowPeekActCell
   act;` — one struct member, not an array). Until 2026-08-06 nothing in
   the code enforced that only one request could occupy it, and nothing
   had to: the guest waited for a target to take an act inside
   `act_yield()`, which did NOT service the wire, so a second act command
   sat in the socket until the first had finished and the cell was idle.
   docs/no-hijack-criterion.md §4 says this in as many words — "the
   single cell is protected by the guest app's threading model, not by an
   interlock" — and names the change that would remove the protection:
   "the guest app ever servicing the wire from inside the act wait".

   That change has now been made deliberately, because the non-pumping
   wait cost up to ten seconds of dead wire per act and lapsed the anchor
   plane's own ten-second owner lease. See docs/no-hijack-criterion.md
   ("2026-08-06, the trade") for what was given up and by whom.

   This is what stands in its place. It is a claim/release latch, not a
   queue and not a lock: a second act arriving while one is in flight is
   REFUSED with a reason, never blocked and never queued. Refusing is the
   right answer rather than a poor one — the second request would have to
   wait out the first's deadline anyway, and a caller told "busy" can
   decide, whereas a caller made to wait cannot.

   WHAT IT COVERS: a second act verb dispatched from inside the first
   act's pump cannot reach the cell, so it cannot overwrite the armed
   request's identity fields (arm_point_h/v, control_handle, window_ptr,
   target_a5) underneath a patch that is already live.

   WHAT IT DOES NOT COVER, stated because a guard whose limits are not
   written down gets read as a guarantee:

     * NON-act commands served during the pump. `scene`, `ps`, a file
       transfer — all of those now run while an act is armed. They do not
       touch the act cell, but they do observe a machine mid-act.
     * A SECOND APPLICATION linking this plane. The shared table lives in
       the system heap and the resident half does not authenticate its
       writer, so this latch is per-process state and says nothing about
       another process's writes. That is the other removal
       docs/no-hijack-criterion.md §4 names, and it is untouched.
     * The pending-press hijack of §4's last section. That is a property
       of the guard's identity clause, not of how many requests are in
       flight, and this latch neither helps nor hurts it.

   Pure C on purpose: no Toolbox, no contract types, so the host `cc` can
   compile and run it (now-guest-shared/tests/now_act_inflight_test.c). */

typedef struct {
    int           armed;     /* non-zero while one act owns the cell */
    unsigned long claims;    /* claims granted, since boot */
    unsigned long refusals;  /* claims refused because one was in flight */
} NowActInflight;

/* Take the cell. Returns 1 if this caller now owns it, 0 if another act
   already does — in which case nothing is changed but the refusal count.
   Never blocks. */
int now_act_inflight_claim(NowActInflight *state);

/* Give it back. IDEMPOTENT, deliberately: the release rides
   now_act_withdraw(), which several paths call more than once and some
   call without a matching claim, and a latch that counted those would
   fail open on exactly the paths that matter. */
void now_act_inflight_release(NowActInflight *state);

/* Is an act in flight right now? The question the cell accessor asks. */
int now_act_inflight_busy(const NowActInflight *state);

unsigned long now_act_inflight_claims(const NowActInflight *state);
unsigned long now_act_inflight_refusals(const NowActInflight *state);

#endif /* NOW_ACT_INFLIGHT_H */
