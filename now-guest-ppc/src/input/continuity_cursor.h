#ifndef NOW_CONTINUITY_CURSOR_H
#define NOW_CONTINUITY_CURSOR_H

typedef struct {
    unsigned long samples;
    unsigned long before_request_mismatches;
    unsigned long press_reversions;
    unsigned long after_request_mismatches;
    unsigned long after_lag_caught_up;
    unsigned long after_lag_persisted;
    unsigned long after_lag_pending;
    long press_h;
    long press_v;
    long requested_h;
    long requested_v;
    long before_h;
    long before_v;
    long after_h;
    long after_v;
    int press_valid;
    int requested_valid;
    int device_point_valid;
} NowContinuityCursorDiagnostics;

int now_continuity_cursor_ready(void);
void now_continuity_cursor_begin_epoch(unsigned long epoch);
long now_continuity_cursor_move(unsigned long epoch, unsigned long sequence,
                                long h, long v);
long now_continuity_cursor_button(unsigned long epoch,
                                  unsigned long generation, int down);
void now_continuity_cursor_diagnostics(NowContinuityCursorDiagnostics *out);
void now_continuity_cursor_shutdown(void);

#endif
