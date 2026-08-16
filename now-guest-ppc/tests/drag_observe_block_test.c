/* Native test for the V14 drag observer block. Runs on the host:

       cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST \
          -I ../../contract drag_observe_block_test.c \
          -o drag_observe_block_test && ./drag_observe_block_test

   WHY THIS FILE EXISTS SEPARATELY FROM peek_table_test.c. That test
   proves the table's own layout rule. This one covers the three things
   a V14 reader depends on that a size assert cannot see:

     - the block is reachable only through the LENGTH gate. A resident
       that predates V14 leaves a table this long ending before the
       block, and an application built against V14 must find nothing
       rather than read past a system-heap allocation sized by a
       different binary.
     - the sample ring's index arithmetic. The resident derives the
       write slot from a total count and the drain derives its read
       window from the same number; both must agree across a wrap, and
       neither may land on the slot the other is inside.
     - the four counters stay four. Collapsing any pair makes "patched
       and nothing called through" read the same as "never patched",
       which is the exact confusion this whole slice was written to
       measure its way out of.

   MUTATION LOG.
     - swap `dispatches` and `trackdrag_entries` in the struct -> the
       header's own offset assert refuses the build in the host cc, the
       Retro68 68K compiler (the extension includes it) and the
       retrocarbon PPC one. A build failure proves the ASSERT works, so
       the runtime half below was watched separately:
     - relax the offset assert and narrow file_name to 32 bytes -> 3
       checks here fail, including the ring-offset one, because the
       compiler pads the field back and the sample ring moves under it.
     - change the resident's ring index from `count % capacity` to
       `(count - 1) % capacity` -> the wrap check below fails naming the
       slot the reader and writer disagree about. Watched 2026-08-16. */

#include <stdio.h>
#include <string.h>

#include "peek_table.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

/* The resident's rule, restated: the slot a writer is in. */
static unsigned writer_slot(unsigned total)
{
    return total % (unsigned)kNowPeekDragObsSampleCapacity;
}

int main(void)
{
    NowPeekTable table;
    NowPeekDragObserve *obs = &table.continuity.drag_observe;
    unsigned long block_end;
    unsigned total;

    memset(&table, 0, sizeof(table));

    /* ---- the length gate ------------------------------------------- */
    block_end = (unsigned long)(offsetof(NowPeekTable, continuity)
                                + sizeof(NowPeekContinuityCell));
    check(block_end == (unsigned long)sizeof(NowPeekTable),
          "the continuity cell is no longer the table's tail");
    check((unsigned long)(offsetof(NowPeekTable, continuity)
                          + offsetof(NowPeekContinuityCell, drag_observe))
              < block_end,
          "the drag observer block starts past the table's own end");
    /* A pre-V14 table is exactly the block shorter. An application must
       decide from `length` alone, so the arithmetic it uses is pinned
       here rather than trusted. */
    check(block_end - sizeof(NowPeekDragObserve)
              == (unsigned long)(offsetof(NowPeekTable, continuity)
                                 + offsetof(NowPeekContinuityCell,
                                            drag_observe)),
          "a pre-V14 length no longer stops exactly at the block");

    /* ---- the format is the gate, and it is exact -------------------- */
    check(NOW_CONTINUITY_FORMAT_CURRENT
              == (unsigned)kNowPeekContinuityFormatV15,
          "the current continuity format is not V15");
    check((unsigned)kNowPeekContinuityFormatV15
              > (unsigned)kNowPeekContinuityFormatV14
          && (unsigned)kNowPeekContinuityFormatV14
              > (unsigned)kNowPeekContinuityFormatV13,
          "the format numbers stopped increasing");

    /* ---- the four counters stay four ------------------------------- */
    check(offsetof(NowPeekDragObserve, install_state) == 0,
          "install_state is not the block's first word");
    check(offsetof(NowPeekDragObserve, dispatches)
              != offsetof(NowPeekDragObserve, trackdrag_entries),
          "the dispatch and drag counters collapsed into one");
    obs->install_state = (NowPeekU32)kNowPeekDragObsInstallDone;
    obs->dispatches = 0;
    obs->trackdrag_entries = 0;
    obs->begin_seq = 0;
    /* The state this block exists to be able to report: the shim is in
       the trap table and nothing in the machine calls through it. Every
       one of those four numbers is needed to say so. */
    check(obs->install_state == (NowPeekU32)kNowPeekDragObsInstallDone
              && obs->dispatches == 0 && obs->trackdrag_entries == 0
              && obs->begin_seq == 0,
          "'patched and never called' is no longer expressible");
    check((unsigned)kNowPeekDragObsInstallNoTrap
              != (unsigned)kNowPeekDragObsInstallUntried,
          "a machine with no Drag Manager reads as one nobody asked");

    /* ---- item honesty ---------------------------------------------- */
    /* The count and the first item's kind are independent, so an
       over-count cannot be folded into an identity. */
    obs->item_count = 7;
    obs->item_status = (NowPeekU32)kNowPeekDragObsItemHFS;
    check(obs->item_count == 7,
          "the item count is derived from the item status");
    check((unsigned)kNowPeekDragObsItemPromise
              != (unsigned)kNowPeekDragObsItemHFS
          && (unsigned)kNowPeekDragObsItemNoHFS
              != (unsigned)kNowPeekDragObsItemHFS,
          "a promise or a flavourless item would report as a real file");
    check(sizeof(obs->file_name) == 64,
          "the name field is no longer fixed width");

    /* ---- the sample ring ------------------------------------------- */
    check(offsetof(NowPeekDragObserve, samples) % 4 == 0,
          "the sample ring is not word aligned");
    /* V16: the registry is a flat 40 per row with no padding either
       compiler could disagree about, and it sits at the block's TAIL so
       every offset above it is unmoved. The three-compiler rule made
       checkable rather than asserted in a comment. */
    check(sizeof(NowPeekDragObsReg) == 44,
          "a registration row must be a flat 44 bytes");
    check(sizeof(((NowPeekDragObsReg *)0)->name) == 32,
          "the registering app's name is 32 bytes, Pascal");
    check(offsetof(NowPeekDragObsReg, ticks)
              == offsetof(NowPeekDragObsReg, a5) + 4,
          "no padding between a5 and ticks");
    check(offsetof(NowPeekDragObsReg, err)
              == offsetof(NowPeekDragObsReg, ticks) + 4,
          "no padding between ticks and the outcome");
    check(offsetof(NowPeekDragObsReg, name)
              == offsetof(NowPeekDragObsReg, err) + 4,
          "no padding before the name");
    check(offsetof(NowPeekDragObserve, regs) % 4 == 0,
          "the registry must be four-byte aligned");
    check(offsetof(NowPeekDragObserve, regs)
              > offsetof(NowPeekDragObserve, tracks),
          "the registry is appended at the TAIL: every preceding offset "
          "must be unmoved by it");
    check(sizeof(obs->regs)
              == (unsigned long)kNowPeekDragObsRegCapacity
                 * sizeof(NowPeekDragObsReg),
          "the registry holds exactly its declared capacity");
    check(sizeof(obs->samples)
              == sizeof(NowPeekDragObsSample)
                  * (unsigned)kNowPeekDragObsSampleCapacity,
          "the sample ring's element count drifted from its capacity");
    /* Walk two full wraps. The writer's slot for `total` and the reader's
       window derived from the same `total` must never overlap: the
       reader's newest entry is total-1, the writer's next is total. */
    for (total = 0; total < (unsigned)kNowPeekDragObsSampleCapacity * 2u;
         ++total) {
        unsigned newest_read;

        if (total == 0)
            continue;
        newest_read = (total - 1u)
            % (unsigned)kNowPeekDragObsSampleCapacity;
        if (newest_read == writer_slot(total)) {
            check(0, "the reader's newest slot is the writer's next slot");
            break;
        }
    }
    /* A window wider than the ring can only be served up to the ring. */
    check((unsigned)kNowPeekDragObsSampleCapacity > 0
              && (unsigned)kNowPeekDragObsSampleGapTicks > 0,
          "the sample ring or its cadence bound became unbounded");

    /* ---- V15: the two routes must stay two ------------------------- */
    /* Collapsing the trap route's counters into the registration
       route's would destroy the only comparison this pair exists for:
       the same question, asked two ways, on the same machine. */
    check(offsetof(NowPeekDragObserve, dispatches)
              != offsetof(NowPeekDragObserve, handler_calls),
          "the trap route and the registration route share a counter");
    check(offsetof(NowPeekDragObserve, item_status)
              != offsetof(NowPeekDragObserve, hitem_status),
          "the two routes read identity into the same field");
    /* `accepted the registration` and `ever called it` are different
       facts, and V14 was built because the first was allowed to imply
       the second once already. */
    obs->handler_state = (NowPeekU32)kNowPeekDragObsHandlerInstalled;
    obs->handler_installs = 1;
    obs->handler_calls = 0;
    check(obs->handler_state == (NowPeekU32)kNowPeekDragObsHandlerInstalled
              && obs->handler_installs == 1 && obs->handler_calls == 0,
          "'registered and never called' is no longer expressible");
    /* Install/remove pairing is a NUMBER a reader can check. */
    obs->handler_installs = 3;
    obs->handler_removes = 3;
    check(obs->handler_installs == obs->handler_removes,
          "the registration pairing is no longer checkable from the cell");
    check((unsigned)kNowPeekDragObsContextCapacity > 0,
          "the context table became unbounded");
    check(offsetof(NowPeekDragObserve, tracks) % 4 == 0
              && sizeof(obs->tracks)
                  == sizeof(NowPeekDragObsTrack)
                      * (unsigned)kNowPeekDragObsTrackCapacity,
          "the tracking ring drifted from its capacity or its alignment");
    check(sizeof(obs->hfile_name) == 64,
          "the handler's name field is no longer fixed width");

    if (g_failures != 0) {
        fprintf(stderr, "drag_observe_block_test: %d failure(s)\n",
                g_failures);
        return 1;
    }
    printf("drag_observe_block_test: ok\n");
    return 0;
}
