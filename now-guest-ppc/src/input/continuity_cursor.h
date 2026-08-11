#ifndef NOW_CONTINUITY_CURSOR_H
#define NOW_CONTINUITY_CURSOR_H

int now_continuity_cursor_ready(void);
void now_continuity_cursor_begin_epoch(unsigned long epoch);
long now_continuity_cursor_move(unsigned long epoch, unsigned long sequence,
                                long h, long v);
void now_continuity_cursor_shutdown(void);

#endif
