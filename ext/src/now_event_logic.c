/*
 * now_event_logic.c - P5's decisions, with no Toolbox in them.
 *
 * The same split now_ext_core_logic.c and now_content_logic.c use, for
 * the same reason: a jGNE filter cannot be run on a developer's Mac, so
 * everything that can be decided without the Toolbox is decided here and
 * tested by `scripts/test-native` with the host compiler. What is left
 * in the filter is reads of low memory and stores into the ring.
 */
#include "now_event_logic.h"

/* Whether this pass may write at all.
 *
 * Fail-closed in every direction: no block, no commit, an expired
 * deadline, or a target that is not the world now pumping all mean no.
 * `arm_a5 == 0` is NOT "instrument everything" - naming no target names
 * nothing, which is the reading docs/resident-components.md requires and
 * the opposite of the obvious one. */
int now_event_should_record(const NowEventArm *arm, NowEventU32 ticks,
                            NowEventU32 a5)
{
    if (arm == 0 || a5 == 0) {
        return 0;
    }
    if (arm->commit == 0 || arm->target_a5 == 0) {
        return 0;
    }
    if (arm->target_a5 != a5) {
        return 0;
    }
    /* Unsigned tick comparison, so a wrap does not read as expired
       forever. TickCount wraps roughly every 828 days at 60 Hz, which
       is longer than any session and shorter than never. */
    if (arm->expiry == 0 || (NowEventU32)(arm->expiry - ticks) > 0x7FFFFFFFu) {
        return 0;
    }
    return 1;
}

/* What kind of record this pass owes, or none.
 *
 * Changes first, cadence last: a transition is the thing the poll cannot
 * see, and a heartbeat exists only so a reader can tell a quiet machine
 * from a stopped one. Reporting one change per pass rather than all
 * three is deliberate - the next pass is 1/60 s away and will report the
 * next one, where a loop over three kinds inside a jGNE filter would put
 * a variable-length walk on every application's event loop. */
int now_event_kind_for(const NowEventWatched *now,
                       const NowEventWatched *last,
                       NowEventU32 ticks, NowEventU32 last_ticks,
                       NowEventU32 cadence_ticks)
{
    if (now == 0 || last == 0) {
        return 0;
    }
    if (now->a5 != last->a5) {
        return kNowEventKindFrontProcess;
    }
    if (now->window_list != last->window_list) {
        return kNowEventKindWindowList;
    }
    if (now->menu_list != last->menu_list) {
        return kNowEventKindMenuList;
    }
    if (cadence_ticks != 0
        && (NowEventU32)(ticks - last_ticks) >= cadence_ticks) {
        return kNowEventKindHeartbeat;
    }
    return 0;
}

/* The value and previous value a record of this kind carries, so the
   reader needs no memory of its own to interpret one. */
void now_event_values_for(int kind, const NowEventWatched *now,
                          const NowEventWatched *last,
                          NowEventU32 *value, NowEventU32 *previous)
{
    NowEventU32 v = 0;
    NowEventU32 p = 0;

    if (now != 0 && last != 0) {
        switch (kind) {
        case kNowEventKindFrontProcess:
            v = now->a5; p = last->a5; break;
        case kNowEventKindWindowList:
            v = now->window_list; p = last->window_list; break;
        case kNowEventKindMenuList:
            v = now->menu_list; p = last->menu_list; break;
        default:
            v = now->window_list; p = now->window_list; break;
        }
    }
    if (value != 0) { *value = v; }
    if (previous != 0) { *previous = p; }
}

/* Where a record goes, and whether writing it costs a reader its view.
 *
 * The ring is written by one writer and read by one reader, and the
 * reader is a whole wire round trip behind. Overflow is therefore
 * normal rather than exceptional, and the only unacceptable outcome is
 * an unadmitted one: `dropped` moves so a reader knows its view has a
 * hole. Returning the slot and the drop separately lets the caller store
 * both without branching in the filter. */
int now_event_slot_for(NowEventU32 write_cursor, NowEventU32 reader_cursor,
                       NowEventU32 records, NowEventU32 *drops)
{
    NowEventU32 outstanding;

    if (records == 0) {
        if (drops != 0) { *drops = 1; }
        return -1;
    }
    outstanding = write_cursor - reader_cursor;
    if (drops != 0) {
        *drops = (outstanding >= records) ? 1u : 0u;
    }
    return (int)(write_cursor % records);
}
