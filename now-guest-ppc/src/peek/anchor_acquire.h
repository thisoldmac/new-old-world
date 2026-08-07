#ifndef NOW_ANCHOR_ACQUIRE_H
#define NOW_ANCHOR_ACQUIRE_H

#include <Carbon.h>

#include "peek_table.h"

/* **Making a machine nobody has driven observable.**
 *
 * THE DEFECT (docs/open-issues.md, 2026-08-07): the anchor plane captures
 * a process's A5 while that process pumps its event loop, and on a
 * cooperatively scheduled Macintosh a background application with a long
 * sleep does not pump until something wakes it. So on a freshly booted
 * Mac the resident's filter ran 451 armed passes and scanned the slot
 * table ONCE — it was never inside a foreign process at all — and the
 * Mirror showed NOW's own window with an honest, useless "not observed"
 * beside everything else. One `activate` of the Finder flipped it and it
 * latched. The Mirror could only show you a machine you had already
 * driven.
 *
 * THE CURE, and why this one: `WakeUpProcess` sets a process's sleep
 * timer to zero and makes it eligible for time. It does not front it, it
 * does not send it anything, it draws nothing and a person watching the
 * screen sees no difference — which fronting each process in turn, the
 * other way to make this happen, could never claim. It is the Process
 * Manager's own primitive for exactly this, it is in CarbonLib 1.0, and
 * this application already calls it on its own PSN from the Open
 * Transport notifier (wire.c). The woken process returns from
 * WaitNextEvent with a null event, the resident's jGNE filter runs in its
 * context, and the anchor is captured. It latches, like the fronting
 * did.
 *
 * WHAT IT COSTS, and the rationing that keeps it there. A wake is one
 * trap. The expensive part is the YIELD that lets the woken process run,
 * and it is rationed twice: a process holding an anchor is never a
 * candidate, so a settled machine wakes nobody and the sweep is one
 * process enumeration; and a process that was woken and did not answer is
 * remembered and never WAITED on again, because six faceless background
 * processes on this machine have no event loop and waiting out a deadline
 * for them would charge every scene the price of the first one forever.
 *
 * DEGRADATION IS HONEST AND UNCHANGED. No resident, or the plane not
 * armed, and this returns having done nothing: the scene then says "not
 * observed" exactly as it does today. Nothing here is a new dependency,
 * and nothing here can make a process appear that was not going to. */

typedef struct {
    unsigned long sweeps;        /* calls that found at least one candidate */
    unsigned long woken;         /* WakeUpProcess calls made */
    unsigned long landed;        /* candidates that held an anchor after */
    unsigned long unanswered;    /* candidates remembered as non-pumping */
    unsigned long wait_ticks;    /* ticks spent yielding, cumulative */
} NowAcquireStats;

/* Wake every process that the anchor plane has not captured yet.
 *
 * `may_wait` non-zero permits a bounded yield so first-time candidates
 * can pump before the caller reads them; zero wakes and returns at once,
 * leaving the capture to land in the caller's own idle. The wire's scene
 * path waits (its answer is wanted NOW); the Processes page does not (it
 * re-walks on a cadence anyway, and it is called from an idle).
 *
 * Safe to call when the extension is absent, when the plane is dark, and
 * as often as a caller likes. */
void now_peek_anchor_acquire(int may_wait);

/* Forget which processes did not answer, so they are all owed another
   wake. Called when the writer session changes — a new session is a new
   view of the machine, and a verdict from the old one is not evidence. */
void now_peek_anchor_acquire_reset(void);

void now_peek_anchor_acquire_stats(NowAcquireStats *out);

#endif /* NOW_ANCHOR_ACQUIRE_H */
