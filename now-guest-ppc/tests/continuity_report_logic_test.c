#define NOW_PEEK_TABLE_HOST 1
#include <stdio.h>

#include "continuity_report_logic.h"

#define CHECK(value) do { if (!(value)) {                                  \
    fprintf(stderr, "continuity report logic failed at line %d\n", __LINE__); \
    return 1;                                                              \
} } while (0)

int main(void)
{
    /* A new arm has written its epoch but P9 has not observed its control
       sequence yet. The old terminal state must not outrun the correlated
       arm answer and turn the host's option off. */
    CHECK(now_continuity_report_kind(
              41, 9, 10, 12, 10, kNowPeekContinuityStateExited, 0)
          == kNowContinuityReportNone);
    CHECK(now_continuity_report_kind(
              41, 10, 10, 14, 10, kNowPeekContinuityStateArmed, 0)
          == kNowContinuityReportControl);
    CHECK(now_continuity_report_kind(
              0, 10, 10, 16, 14, kNowPeekContinuityStateExited, 0)
          == kNowContinuityReportUnsolicited);
    CHECK(now_continuity_report_kind(
              0, 10, 10, 16, 16, kNowPeekContinuityStateExited, 0)
          == kNowContinuityReportNone);
    /* Counter publication advances status_seq after exit, but a terminal
       state is an event and must be emitted once per armed epoch. */
    CHECK(now_continuity_report_kind(
              0, 10, 10, 18, 16, kNowPeekContinuityStateExited, 1)
          == kNowContinuityReportNone);
    /* The caller marks a correlated terminal control reply as reported; the
       pure policy must suppress the later status-counter publication too. */
    CHECK(now_continuity_report_kind(
              0, 12, 12, 24, 22, kNowPeekContinuityStateRefused, 1)
          == kNowContinuityReportNone);
    return 0;
}
