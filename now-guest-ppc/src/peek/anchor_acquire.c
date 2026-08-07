/*
 * anchor_acquire.c - see anchor_acquire.h. The Toolbox half: enumerate
 * processes, wake the ones the plane has not captured, yield briefly so
 * they pump. Every rule it obeys about WHO and HOW LONG lives in
 * anchor_acquire_logic.c, where a native test can watch it fail.
 */

#include "anchor_acquire.h"

#include <Processes.h>
#include <string.h>

#include "anchor_acquire_logic.h"
#include "axprocess.h"
#include "peek.h"

/* How long a sweep may yield waiting for first-time candidates.
 *
 * A ceiling, not a cost: the loop leaves the moment every candidate has
 * an anchor, and on a machine whose processes all pump that is the first
 * or second yield. It is paid in full only when some candidate never
 * answers, and only once for that process — which is what makes 30 ticks
 * affordable at all. Half a second is also the same order as
 * kNowSceneArmSettleTicks, the other bounded wait on this path, which is
 * deliberate: two waits on one request should not add up to something a
 * person notices as a stall. */
enum { kNowAcquireWaitTicks = 30 };

/* Each yield. Two ticks is enough for the Process Manager to give every
   eligible process a slice, and short enough that landing early is
   detected promptly. Mask zero: we want the scheduler, not the events —
   the same yield act_client.c and now_peek_settle use, and for the same
   reason. Dequeuing an event here would steal it from the main loop. */
enum { kNowAcquireYieldTicks = 2 };

static NowAcquireSeen g_seen;
static NowAcquireStats g_stats;
static int g_seen_ready;

void now_peek_anchor_acquire_reset(void)
{
    now_acquire_seen_reset(&g_seen, (NowPeekU32)now_peek_session_epoch());
    g_seen_ready = 1;
}

void now_peek_anchor_acquire_stats(NowAcquireStats *out)
{
    if (out != NULL) {
        *out = g_stats;
    }
}

/* Does this process hold a usable anchor right now? Ok only: Stale is an
   anchor that exists, which is all this question asks, but a process
   whose anchor has aged out of trust is one a wake genuinely refreshes -
   so Stale counts as held here and the oracle's own callers decide what
   to do with it. */
static int has_anchor(const ProcessSerialNumber *psn)
{
    NowAxContext ctx;
    NowPeekReadStatus status = now_ax_bind_process(psn, &ctx);

    return status == kNowPeekReadOk;
}

void now_peek_anchor_acquire(int may_wait)
{
    const NowPeekTable *table;
    ProcessSerialNumber self;
    ProcessSerialNumber psn;
    ProcessSerialNumber candidates[kNowAcquireMaxRemembered];
    short waited[kNowAcquireMaxRemembered];
    short count = 0;
    short wait_count = 0;
    short i;
    NowPeekU32 started;
    NowPeekU32 deadline;

    /* A new writer session is a new view of the machine, so a verdict of
       "this one does not pump" taken under the old one is not evidence
       and every process is owed another wake. The cache expires ITSELF
       rather than being told to; peek.c cannot know about every cache. */
    if (!g_seen_ready
        || g_seen.session_epoch != (NowPeekU32)now_peek_session_epoch()) {
        now_peek_anchor_acquire_reset();
    }
    /* No resident, or a resident whose plane is not actually armed, and
       there is nothing a wake could capture. Waking anyway would be pure
       disturbance charged to a machine for no observation at all. */
    table = now_peek_table();
    if (table == NULL
        || (table->arm_active & (NowPeekU32)kNowPeekTableCapAnchors) == 0) {
        return;
    }
    if (GetCurrentProcess(&self) != noErr) {
        return;
    }
    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (count < (short)kNowAcquireMaxRemembered
           && GetNextProcess(&psn) == noErr) {
        Boolean same = false;

        /* Ourselves: peek_read.c answers for self through the Window
           Manager, we are already pumping by definition, and waking the
           process that is running is a no-op with a trap's price. */
        if (SameProcess(&psn, &self, &same) == noErr && same) {
            continue;
        }
        if (has_anchor(&psn)) {
            continue;                 /* already captured; latched */
        }
        candidates[count] = psn;
        /* First-time candidates are the only ones a wait is spent on. A
           remembered one is still WOKEN — free, and it is how a process
           that gains an event loop later is eventually caught — but the
           deadline is not extended on its account. */
        if (!now_acquire_seen_contains(&g_seen,
                                       (NowPeekU32)psn.highLongOfPSN,
                                       (NowPeekU32)psn.lowLongOfPSN)) {
            waited[wait_count++] = count;
        }
        count++;
    }
    if (count == 0) {
        return;                       /* a settled machine costs one walk */
    }
    for (i = 0; i < count; ++i) {
        if (WakeUpProcess(&candidates[i]) == noErr) {
            g_stats.woken++;
        }
    }
    g_stats.sweeps++;
    started = (NowPeekU32)TickCount();
    if (may_wait && wait_count > 0) {
        deadline = started + (NowPeekU32)kNowAcquireWaitTicks;
        for (;;) {
            EventRecord ev;
            short landed = 0;

            for (i = 0; i < wait_count; ++i) {
                if (has_anchor(&candidates[waited[i]])) {
                    ++landed;
                }
            }
            if (!now_acquire_keep_waiting(wait_count, landed,
                                          (NowPeekU32)TickCount(), deadline)) {
                break;
            }
            (void)WaitNextEvent(0, &ev, (UInt32)kNowAcquireYieldTicks, NULL);
        }
        g_stats.wait_ticks += (NowPeekU32)TickCount() - started;
    }
    /* The verdict, taken once, after whatever waiting there was. A
       candidate that answered is simply no longer a candidate; one that
       did not is remembered, so the next sweep wakes it without paying
       for it again. */
    for (i = 0; i < count; ++i) {
        if (has_anchor(&candidates[i])) {
            g_stats.landed++;
        } else if (now_acquire_seen_add(&g_seen,
                                        (NowPeekU32)candidates[i].highLongOfPSN,
                                        (NowPeekU32)candidates[i].lowLongOfPSN)) {
            g_stats.unanswered++;
        }
    }
}
