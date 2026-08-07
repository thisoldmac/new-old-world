#include "front_order.h"

#include <string.h>

static int slot_of(const NowFrontOrder *o,
                   unsigned long hi, unsigned long lo)
{
    int i;

    for (i = 0; i < o->count; ++i) {
        if (o->slots[i].psn_hi == hi && o->slots[i].psn_lo == lo) {
            return i;
        }
    }
    return -1;
}

void now_front_order_reset(NowFrontOrder *o)
{
    if (o != NULL) {
        memset(o, 0, sizeof *o);
        o->next_seq = 1;
    }
}

int now_front_order_note(NowFrontOrder *o,
                         unsigned long hi, unsigned long lo)
{
    int at;

    if (o == NULL) {
        return 0;
    }
    if (o->next_seq == 0) {
        o->next_seq = 1;              /* a caller that skipped reset */
    }
    /* A PSN of 0/0 is the Process Manager's "no process", not a
       process that happens to be numbered zero. Recording it would put
       a phantom at the top of the layer order for as long as the
       machine kept answering. */
    if (hi == 0 && lo == 0) {
        return 0;
    }
    /* The common case by a very long way: nothing changed since the
       last pass. Not merely an optimisation - burning a sequence number
       here would make "still front" indistinguishable from "fronted
       again", and every idle pass would age the rest of the table. */
    if (o->last_known && o->last_hi == hi && o->last_lo == lo) {
        return 0;
    }
    o->last_hi = hi;
    o->last_lo = lo;
    o->last_known = 1;

    at = slot_of(o, hi, lo);
    if (at < 0) {
        if (o->count < kNowFrontOrderSlots) {
            at = o->count++;
        } else {
            /* Full: forget the process that has been in the back
               longest, which is the one whose position mattered least.
               Counted, because an evicted rank and a never-observed one
               are both absent and mean different things. */
            int i;

            at = 0;
            for (i = 1; i < o->count; ++i) {
                if (o->slots[i].seq < o->slots[at].seq) {
                    at = i;
                }
            }
            ++o->evictions;
        }
        o->slots[at].psn_hi = hi;
        o->slots[at].psn_lo = lo;
    }
    o->slots[at].seq = o->next_seq++;
    return 1;
}

unsigned long now_front_order_seq(const NowFrontOrder *o,
                                  unsigned long hi, unsigned long lo)
{
    int at;

    if (o == NULL) {
        return 0;
    }
    at = slot_of(o, hi, lo);
    return at < 0 ? 0UL : o->slots[at].seq;
}

int now_front_order_known_count(const NowFrontOrder *o)
{
    return o == NULL ? 0 : o->count;
}
