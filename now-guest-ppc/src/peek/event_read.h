/*
 * event_read.h - P5's ring reader.
 *
 * Reading is separated from ADVANCING on purpose: a caller that reads
 * records and then fails to deliver them must not have lost them, so
 * moving `reader_cursor` in shared memory is its own act.
 */
#ifndef NOW_EVENT_READ_H
#define NOW_EVENT_READ_H

#include "../../../contract/event_tail.h"

int now_event_block_usable(const NowEventBlock *block);
unsigned long now_event_pending(const NowEventBlock *block,
                                NowEventU32 reader_cursor,
                                unsigned long *lost);
unsigned long now_event_read(const NowEventBlock *block,
                             NowEventU32 reader_cursor,
                             NowEventRecord *out, unsigned long max,
                             NowEventU32 *next_cursor,
                             unsigned long *lost);
void now_event_arm(NowEventBlock *block, NowEventU32 a5,
                   NowEventU32 expiry);
void now_event_disarm(NowEventBlock *block);

#endif /* NOW_EVENT_READ_H */
