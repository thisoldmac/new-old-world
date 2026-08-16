/* How far one drain of the Continuity UDP endpoint may go, and - the part
   that cost a real misfire - where it may NOT stop.

   On 2026-08-16 a held button inside a foreign application's menu-tracking
   loop starved NOW of task time. The notifier's drain hit its cap of 8,
   handed the residue to a task-time poll that could not run, and because
   T_DATA is edge-triggered no second notification came. `arrival_ticks` froze
   under a live host, the resident's lease expired, and the release landed in
   a menu the person had merely opened.

   So the cases below that matter most are the ones that must answer CONTINUE:
   a notifier at the old cap with nobody to finish for it. The refusals still
   have to hold - an unbounded notifier is the interrupt hazard the cap was
   written for - which is why the ceiling and the error budget are watched
   just as closely. */
#include <stdio.h>

#include "continuity_drain_logic.h"

#define CHECK(value) do { if (!(value)) {                                    \
    fprintf(stderr, "continuity drain logic failed at line %d\n", __LINE__);  \
    return 1;                                                                \
} } while (0)

/* The starvation shape: notifier time, no task-time drain in the loop. */
static NowContinuityDrainState starved(unsigned long iterations)
{
    NowContinuityDrainState state;

    state.notifier_context = 1;
    state.task_drain_running = 0;
    state.iterations = iterations;
    state.consecutive_errors = 0;
    return state;
}

static NowContinuityDrainState task_time(unsigned long iterations)
{
    NowContinuityDrainState state;

    state.notifier_context = 0;
    state.task_drain_running = 1;
    state.iterations = iterations;
    state.consecutive_errors = 0;
    return state;
}

/* A notifier that preempted a running task-time drain: that loop finishes. */
static NowContinuityDrainState notifier_over_task(unsigned long iterations)
{
    NowContinuityDrainState state;

    state.notifier_context = 1;
    state.task_drain_running = 1;
    state.iterations = iterations;
    state.consecutive_errors = 0;
    return state;
}

int main(void)
{
    NowContinuityDrainState state;

    CHECK(now_continuity_drain_may_continue(NULL) == 0);
    CHECK(now_continuity_drain_stop_has_finisher(NULL) == 0);

    /* THE REGRESSION. A starved notifier at the old cap keeps reading. If
       this ever answers 0 again, the endpoint goes deaf for the rest of a
       held button and the lease expires under a live host. */
    state = starved(kNowContinuityDrainSoftMax);
    CHECK(now_continuity_drain_may_continue(&state) == 1);
    state = starved(kNowContinuityDrainSoftMax + 1);
    CHECK(now_continuity_drain_may_continue(&state) == 1);
    state = starved(kNowContinuityDrainCeiling - 1);
    CHECK(now_continuity_drain_may_continue(&state) == 1);

    /* ...but it is still bounded. An unbounded notifier is the interrupt
       hazard the cap existed for, and the ceiling is what replaces it. */
    state = starved(kNowContinuityDrainCeiling);
    CHECK(now_continuity_drain_may_continue(&state) == 0);
    CHECK(now_continuity_drain_stop_has_finisher(&state) == 0);
    state = starved(kNowContinuityDrainCeiling + 1);
    CHECK(now_continuity_drain_may_continue(&state) == 0);

    /* Task time stops at the soft cap, because the next event-loop pass is
       guaranteed and finishing there costs nothing. */
    state = task_time(kNowContinuityDrainSoftMax - 1);
    CHECK(now_continuity_drain_may_continue(&state) == 1);
    state = task_time(kNowContinuityDrainSoftMax);
    CHECK(now_continuity_drain_may_continue(&state) == 0);
    CHECK(now_continuity_drain_stop_has_finisher(&state) == 1);

    /* A notifier that preempted a task-time drain may hand back at the soft
       cap: that loop is still running and reads what this pass left. */
    state = notifier_over_task(kNowContinuityDrainSoftMax);
    CHECK(now_continuity_drain_may_continue(&state) == 0);
    CHECK(now_continuity_drain_stop_has_finisher(&state) == 1);
    state = notifier_over_task(kNowContinuityDrainSoftMax - 1);
    CHECK(now_continuity_drain_may_continue(&state) == 1);

    /* The error budget outranks everything: an endpoint answering an
       unexpected error every time is not drained by spinning on it, and the
       starved notifier is exactly where spinning would be worst. */
    state = starved(0);
    state.consecutive_errors = kNowContinuityDrainErrorRetries - 1;
    CHECK(now_continuity_drain_may_continue(&state) == 1);
    state.consecutive_errors = kNowContinuityDrainErrorRetries;
    CHECK(now_continuity_drain_may_continue(&state) == 0);
    state = task_time(0);
    state.consecutive_errors = kNowContinuityDrainErrorRetries;
    CHECK(now_continuity_drain_may_continue(&state) == 0);

    /* A starved notifier is never told somebody else will finish, whatever
       else is true of it. That answer is what the intake counts as the
       starvation exit rather than an ordinary handoff. */
    state = starved(0);
    CHECK(now_continuity_drain_stop_has_finisher(&state) == 0);
    state = starved(kNowContinuityDrainCeiling);
    CHECK(now_continuity_drain_stop_has_finisher(&state) == 0);

    printf("continuity drain logic ok\n");
    return 0;
}
