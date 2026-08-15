#ifndef NOW_CONTINUITY_REPORT_LOGIC_H
#define NOW_CONTINUITY_REPORT_LOGIC_H

#include "peek_table.h"

enum {
    kNowContinuityReportNone = 0,
    kNowContinuityReportControl = 1,
    kNowContinuityReportUnsolicited = 2
};

int now_continuity_report_kind(
    long pending_id, NowPeekU32 observed_control_seq,
    NowPeekU32 pending_control_seq, NowPeekU32 status_seq,
    NowPeekU32 last_reported_status_seq, NowPeekU32 state,
    int terminal_already_reported);

#endif
