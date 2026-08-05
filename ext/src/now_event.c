/*
 * now_event.c - P5, the transition tail's resident half.
 *
 * Two entry points, the same shape the content plane uses: `boot` runs
 * once at INIT time where allocation is legal, and `pass` runs inside the
 * jGNE filter where it is not.
 *
 * WHAT RUNS IN THE FILTER, and why it is this small. The filter executes
 * in whatever process is pumping - a foreign A5 world, on a machine that
 * may be a 33 MHz 68030 - and it runs on EVERY GetNextEvent and
 * WaitNextEvent whether or not anyone is mirroring. So `pass` allocates
 * nothing, calls nothing that can move memory, loads no resource, and
 * touches no application global. Its whole body is three comparisons and,
 * when one of them differs, six stores into a block that has existed
 * since boot.
 *
 * The values it compares are ones `now_ext_gne_apply` has already read
 * for the anchor plane, and they are passed in rather than re-read: two
 * reads of LMGetWindowList in one pass could disagree, and a plane whose
 * record and whose anchor describe different instants would be worse
 * than no plane.
 */
#include "now_event_logic.h"

#include <MacTypes.h>
#include <MacMemory.h>

#include "../../contract/event_tail.h"

/* Retained for the life of the machine, in the system heap, and reached
   only through this file. Not BSS-after-FreeGlobals and not the
   application's: a jGNE filter that dereferenced either would be reading
   whichever process happened to be pumping. */
static NowEventBlock *gEventBlock;
static NowEventWatched gLastWatched;
static NowEventU32 gSeq;

/* Sixty ticks - one second. Slow enough that a quiet machine costs one
   record a second, fast enough that a reader can tell quiet from stopped
   well inside a host poll period. */
#define kNowEventCadenceTicks 60

void now_event_boot(NowPeekTable *table)
{
    NowEventBlock *block;

    if (table == NULL || gEventBlock != NULL) {
        return;
    }
    /* Allocated unconditionally, published conditionally - the content
       plane's rule, for its reason: a plane dark because nothing armed
       it and a plane dark because the code was never linked look
       identical from outside and are not the same thing. */
    block = (NowEventBlock *)NewPtrSysClear((Size)sizeof(NowEventBlock));
    if (block == NULL) {
        return;                        /* degrade to absent, honestly */
    }
    block->format = kNowEventFormatV1;
    block->reserved = 0;
    block->length = (NowEventU32)sizeof(NowEventBlock);
    /* Magic last: a reader that somehow sees the address early finds it
       only once the block is fully formed. */
    block->magic = (NowEventU32)kNowEventBlockMagic;
    gEventBlock = block;

    table->event_block = (NowEventU32)block;
    table->caps |= (NowPeekU32)kNowPeekTableCapEvents;
}

/* One event pass. `a5`, `window_list` and `menu_list` are the values the
   caller has already read this pass - see the file head for why they are
   not re-read here. */
void now_event_pass(NowPeekTable *table, NowEventU32 ticks,
                    NowEventU32 a5, NowEventU32 window_list,
                    NowEventU32 menu_list)
{
    NowEventBlock *block = gEventBlock;
    NowEventArm arm;
    NowEventWatched now;
    NowEventRecord *slot;
    NowEventU32 drops = 0;
    int index;
    int kind;

    if (block == NULL || table == NULL) {
        return;
    }
    arm.target_a5 = block->arm_a5;
    arm.expiry = block->arm_expiry;
    arm.commit = block->arm_commit;
    if (!now_event_should_record(&arm, ticks, a5)) {
        /* Forget what we watched, so the first pass after a re-arm
           reports the world as it is rather than as a transition from
           whatever it was when the last request lapsed. A record saying
           the window list "changed" across a gap nobody was watching is
           a fact about our arming, not about the machine. */
        gLastWatched.a5 = 0;
        gLastWatched.window_list = 0;
        gLastWatched.menu_list = 0;
        return;
    }
    block->passes++;                   /* unguarded: separates "never
                                          ran" from "ran and declined" */
    now.a5 = a5;
    now.window_list = window_list;
    now.menu_list = menu_list;
    if (gLastWatched.a5 == 0) {
        /* First pass of an armed run: adopt the world silently. */
        gLastWatched = now;
        block->last_ticks = ticks;
        return;
    }
    kind = now_event_kind_for(&now, &gLastWatched, ticks,
                              block->last_ticks, kNowEventCadenceTicks);
    if (kind == 0) {
        return;
    }
    index = now_event_slot_for(block->write_cursor, block->reader_cursor,
                               (NowEventU32)kNowEventRingRecords, &drops);
    if (index < 0) {
        block->dropped += drops;
        return;
    }
    slot = &block->ring[index];
    slot->ticks = ticks;
    slot->seq = ++gSeq;
    slot->kind = (NowEventU32)kind;
    slot->a5 = a5;
    now_event_values_for(kind, &now, &gLastWatched,
                         &slot->value, &slot->previous);
    /* The cursor commits the record, so it moves last. A reader that
       samples between the stores above and this one sees the previous
       cursor and simply does not know about this record yet, which is
       the correct thing for it to believe. */
    block->write_cursor++;
    block->dropped += drops;
    block->last_ticks = ticks;
    gLastWatched = now;
}
