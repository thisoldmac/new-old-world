/*
 * cursor_rig_logic.c - the rig's decisions, with no Toolbox in them.
 *
 * Everything here runs at interrupt time on the guest, so it must not
 * allocate, must not call anything that could move memory, and must be
 * finite. Everything here also compiles with the host `cc`, which is the
 * point: coalescing and ring accounting are exactly the parts that
 * report a clean tail when they are wrong, and a test that cannot watch
 * them fail is not a test (tests/rig_logic_native_test.c).
 *
 * There is deliberately NO "don't fight a human" yield rule. The prior
 * lane's version compared against a zeroed last-placed point, so the
 * first placement always looked like somebody else's hand, and the
 * declining branch then recorded the point it had refused to move to -
 * one yield poisoned the rest of the boot. A rig has no business
 * declining anyway: it is the only thing driving, and a measurement that
 * silently skips is worse than one that reports a bad number.
 */

#include "cursor_rig.h"

void rig_ring_reset(RigTable *t)
{
    RigU32 i;

    for (i = 0; i < t->ring_cap; ++i) {
        t->ring[i].seq = 0;
        t->ring[i].arrival_ticks = 0;
        t->ring[i].apply_ticks = 0;
        t->ring[i].redraw_ticks = 0;
        t->ring[i].h = 0;
        t->ring[i].v = 0;
        t->ring[i].flags = 0;
        t->ring[i].coalesced = 0;
    }
    t->ring_head = 0;
    t->ring_count = 0;
    t->ring_dropped = 0;
    t->received = 0;
    t->applied = 0;
    t->coalesced = 0;
    t->out_of_order = 0;
    t->timer_ticks = 0;
    t->intake_calls = 0;
    t->app_passes = 0;
    t->redraws = 0;
    t->redraw_calls = 0;
    t->last_seq = 0;
    t->last_apply_ticks = 0;
    t->place_route = kRigRouteNone;
    t->mailbox.pending = 0;
    t->mailbox.seq = 0;
    t->mailbox.ring_index = 0;
}

RigU32 rig_intake_stamp(RigTable *t, const RigCommand *cmd, RigU32 now_ticks)
{
    RigU32 idx = t->ring_head;
    RigSample *s = &t->ring[idx];
    RigU16 carried = 0;

    /* Coalesce. The command still sitting in the mailbox never reached
       the machine, so it is marked and counted here rather than left
       looking applied-but-slow in the tail. Its own carried count rolls
       forward, so a burst of ten that collapses to one says ten. */
    if (t->mailbox.pending) {
        RigSample *prev = &t->ring[t->mailbox.ring_index];

        if (prev->seq == t->mailbox.seq) {
            prev->flags |= kRigSampleCoalesced;
            carried = (RigU16)(prev->coalesced + 1);
        } else {
            carried = 1;        /* the ring already wrapped past it */
        }
        t->coalesced++;
    }

    /* A ring that overflows silently reports a CLEAN tail precisely
       because it discarded the interesting part. Count first, then
       overwrite. */
    if (t->ring_count >= t->ring_cap) {
        t->ring_dropped++;
    }

    s->seq = cmd->seq;
    s->arrival_ticks = now_ticks;
    s->apply_ticks = 0;
    s->redraw_ticks = 0;
    s->h = cmd->h;
    s->v = cmd->v;
    s->flags = (RigU16)((cmd->op == kRigOpClick) ? kRigSampleClick : 0);
    s->coalesced = carried;

    t->ring_head = (RigU32)((idx + 1) % t->ring_cap);
    t->ring_count++;
    t->received++;

    t->mailbox.seq = cmd->seq;
    t->mailbox.arrival_ticks = now_ticks;
    t->mailbox.h = cmd->h;
    t->mailbox.v = cmd->v;
    t->mailbox.op = cmd->op;
    t->mailbox.arg = cmd->arg;
    t->mailbox.ring_index = idx;
    t->mailbox.pending = 1;     /* written LAST: the writer reads this first */

    return idx;
}

int rig_mailbox_take(RigTable *t, RigMailbox *out)
{
    if (!t->mailbox.pending) {
        return 0;
    }
    *out = t->mailbox;
    t->mailbox.pending = 0;
    return 1;
}

void rig_apply_record(RigTable *t, const RigMailbox *box, RigU32 now_ticks)
{
    RigSample *s = &t->ring[box->ring_index];
    RigU16 flags = kRigSampleApplied;

    /* Out of order is checked against the high-water mark and not
       against the previous sample: the question a person watching the
       pointer cares about is whether it ever went BACKWARDS, and a
       coalesced-away command in between is not that. */
    if (box->seq < t->last_seq) {
        t->out_of_order++;
        flags |= kRigSampleOutOfOrder;
    } else {
        t->last_seq = box->seq;
    }

    if (s->seq == box->seq) {   /* still ours; the ring may have wrapped */
        s->apply_ticks = now_ticks;
        s->flags |= flags;
    }
    t->applied++;
    t->last_apply_ticks = now_ticks;
}

void rig_redraw_record(RigTable *t, RigU32 now_ticks)
{
    RigU32 i;

    /* The picture was drawn; that is not in question by the time this is
       called, and it is counted separately from whether we managed to
       ATTRIBUTE it to a sample. The first version of this function
       conflated the two and reported `redraws 0` under three of five
       load profiles - which read as "the pointer's picture never
       updated under load", a devastating result, and was false. What
       actually happened: it looked only at the NEWEST ring entry, and
       under load the intake stamps a fresh, not-yet-applied sample
       between the writer applying one and the event loop settling the
       debt. So the newest entry was unapplied, nothing was recorded,
       and the redraw that really happened went uncounted.

       This is the lab's own recurring failure - an instrument whose
       normal mode of operation is the one condition under which it
       cannot see the thing it measures. */
    t->redraw_calls++;

    /* Walk back for the newest APPLIED sample that has not been
       attributed yet. Bounded: this runs in somebody else's event loop
       and must be finite and cheap. Only an applied sample can owe a
       picture - settling against an unapplied one would claim the arrow
       was drawn somewhere the machine does not think the pointer is. */
    for (i = 1; i <= kRigRedrawLookback && i <= t->ring_cap; ++i) {
        RigU32 idx = (RigU32)((t->ring_head + t->ring_cap - i) % t->ring_cap);
        RigSample *s = &t->ring[idx];

        if (s->redraw_ticks != 0) {
            return;             /* already settled: nothing older is owed */
        }
        if (s->flags & kRigSampleApplied) {
            s->redraw_ticks = now_ticks;
            s->flags |= kRigSampleRedrawn;
            t->redraws++;
            return;
        }
    }
}
