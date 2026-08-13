#ifndef NOW_CONTINUITY_CURSOR_H
#define NOW_CONTINUITY_CURSOR_H

enum { kNowContinuityMoveIntervalCapacity = 32 };
/* Inter-move gap buckets in ticks: <=2, 3-5, 6-11, 12-29, >=30. Counted
   only between moves whose points differ, because a stationary pointer
   and a starved pump both read as large gaps in the raw ring. */
enum { kNowContinuityMotionGapBuckets = 5 };

typedef struct {
    unsigned long sequence;
    unsigned long begin_ticks;
    unsigned long gap_ticks;
    long h;
    long v;
} NowContinuityMoveInterval;

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
    unsigned long interval_samples;
    unsigned long interval_used;
    unsigned long interval_next;
    unsigned long interval_max_ticks;
    unsigned long interval_max_sequence;
    unsigned long interval_max_begin_ticks;
    NowContinuityMoveInterval
        intervals[kNowContinuityMoveIntervalCapacity];
    unsigned long motion_gap_samples;
    unsigned long motion_gap_hist[kNowContinuityMotionGapBuckets];
    unsigned long motion_gap_max_ticks;
    unsigned long motion_gap_max_begin_ticks;
} NowContinuityCursorDiagnostics;

int now_continuity_cursor_ready(void);
void now_continuity_cursor_begin_epoch(unsigned long epoch);
long now_continuity_cursor_move(unsigned long epoch, unsigned long sequence,
                                long h, long v);
long now_continuity_cursor_button(unsigned long epoch,
                                  unsigned long generation, int down);
long now_continuity_cursor_ensure_released(const char *reason);
void now_continuity_cursor_diagnostics(NowContinuityCursorDiagnostics *out);
void now_continuity_cursor_shutdown(void);

#endif
