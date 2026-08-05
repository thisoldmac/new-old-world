/*
 * now_event_logic.h - P5's Toolbox-free decisions.
 *
 * Deliberately independent of event_tail.h's struct layout: the kinds
 * are shared, the block is not. That lets the native test compile this
 * with the host compiler without dragging the shared-memory block, its
 * static asserts and its alignment into a test that has nothing to say
 * about any of them.
 */
#ifndef NOW_EVENT_LOGIC_H
#define NOW_EVENT_LOGIC_H

#ifdef NOW_EVENT_LOGIC_STANDALONE
typedef unsigned long NowEventU32;
enum {
    kNowEventKindWindowList = 1,
    kNowEventKindFrontProcess = 2,
    kNowEventKindMenuList = 3,
    kNowEventKindHeartbeat = 4
};
#else
#include "../../contract/event_tail.h"
#endif

/* The application's request, as the filter reads it. */
typedef struct {
    NowEventU32 target_a5;
    NowEventU32 expiry;
    NowEventU32 commit;
} NowEventArm;

/* The low-memory words this plane watches. Every one of them is a word
   `now_ext_gne_apply` already reads for the anchor plane, which is why
   this plane costs a comparison rather than a walk. */
typedef struct {
    NowEventU32 a5;
    NowEventU32 window_list;
    NowEventU32 menu_list;
} NowEventWatched;

int now_event_should_record(const NowEventArm *arm, NowEventU32 ticks,
                            NowEventU32 a5);
int now_event_kind_for(const NowEventWatched *now,
                       const NowEventWatched *last,
                       NowEventU32 ticks, NowEventU32 last_ticks,
                       NowEventU32 cadence_ticks);
void now_event_values_for(int kind, const NowEventWatched *now,
                          const NowEventWatched *last,
                          NowEventU32 *value, NowEventU32 *previous);
int now_event_slot_for(NowEventU32 write_cursor, NowEventU32 reader_cursor,
                       NowEventU32 records, NowEventU32 *drops);

#endif /* NOW_EVENT_LOGIC_H */
