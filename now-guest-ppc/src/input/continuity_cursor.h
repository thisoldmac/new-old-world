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
    /* Button-edge exposure barrier. `waits` counts edges that found the
       mouse global still behind the requested point; `expired` counts the
       subset that were applied anyway on the deadline. waits==0 across a
       session means the barrier never had anything to hold. */
    unsigned long exposure_waits;
    unsigned long exposure_expired;
    unsigned long exposure_wait_ticks;
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

/* One button edge's answer to "was the position exposed before I acted?" */
typedef struct {
    long request_h;
    long request_v;
    long observed_h;
    long observed_v;
    unsigned long waited_ticks;
    int verdict;                  /* kNowContinuityBarrier* */
    int request_valid;
    int observed_valid;
    /* Which of the two stages the reported point came from. The record is
       upstream of the global, so a lag there is reported in preference:
       naming the nearer stage would hide the further one. */
    int observed_is_record;
} NowContinuityCursorExposure;

int now_continuity_cursor_ready(void);
/* Block until the mouse global the guest's tracking loops sample reports the
   point this side last requested, or the barrier's deadline expires. Returns
   the verdict and fills `out`. Never waits when there is nothing to wait for,
   and never waits unboundedly: see now_continuity_button_barrier. */
int now_continuity_cursor_await_exposure(NowContinuityCursorExposure *out);
void now_continuity_cursor_begin_epoch(unsigned long epoch);
long now_continuity_cursor_move(unsigned long epoch, unsigned long sequence,
                                long h, long v);
long now_continuity_cursor_button(unsigned long epoch,
                                  unsigned long generation, int down);
long now_continuity_cursor_ensure_released(const char *reason);
void now_continuity_cursor_diagnostics(NowContinuityCursorDiagnostics *out);
void now_continuity_cursor_shutdown(void);

#endif
