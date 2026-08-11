#include "continuity_report_logic.h"

int now_continuity_report_kind(
    long pending_id, NowPeekU32 observed_control_seq,
    NowPeekU32 pending_control_seq, NowPeekU32 status_seq,
    NowPeekU32 last_reported_status_seq, NowPeekU32 state,
    int terminal_already_reported)
{
    /* Once a control request has changed epoch, the resident cell can still
       carry the preceding epoch's terminal state until it observes that
       control sequence. Publishing that snapshot without the request id
       makes a valid re-arm look like an immediate exit. The correlated
       resident answer is the only state allowed to settle pending control. */
    if (pending_id != 0)
        return observed_control_seq == pending_control_seq
            ? kNowContinuityReportControl : kNowContinuityReportNone;
    if (status_seq == last_reported_status_seq)
        return kNowContinuityReportNone;
    if (state != (NowPeekU32)kNowPeekContinuityStateExited
            && state != (NowPeekU32)kNowPeekContinuityStateRefused)
        return kNowContinuityReportNone;
    /* The resident republishes task-time counters under status_seq even after
       it has exited. That is not a new terminal event. Without this separate
       identity gate, every cooperative pump writes and sends the same exit
       report until TCP backpressure becomes the next failure. */
    if (terminal_already_reported)
        return kNowContinuityReportNone;
    return kNowContinuityReportUnsolicited;
}
