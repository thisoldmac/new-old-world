#ifndef NOW_DEVELOPMENT_HISTORY_H
#define NOW_DEVELOPMENT_HISTORY_H

#include "development_contract.h"

/* What a person standing at the machine asks after a build: what did the
   last few do?  Deliberately SESSION-scoped and in memory - a build log on
   disk is a second durable record beside the ToolServer transcript the
   build already writes into the project's Build folder, and two records of
   the same run go out of step.  Eight is what the page can show without
   scrolling; older jobs fall off the ring rather than being summarised. */
enum {
    kDevJobHistoryMax = 8,
    kDevJobSummaryProjectCap = 40,
    kDevJobSummaryNameCap = 65
};

typedef struct DevJobSummary {
    char id[kDevIdentityCap];
    char project_id[kDevJobSummaryProjectCap];
    char project_name[kDevJobSummaryNameCap];
    DevJobState state;
    int exit_code;
    int actions_completed;
    int actions_total;
    /* Supplied by the caller (TickCount on the guest) so this half stays
       Toolbox-free and testable by the host compiler. */
    unsigned long finished_ticks;
} DevJobSummary;

typedef struct DevJobHistory {
    DevJobSummary entries[kDevJobHistoryMax];
    int count;                    /* entries held, capped at the ring size */
    int next;                     /* write cursor into entries */
    long recorded;                /* jobs ever pushed, including evicted */
} DevJobHistory;

void dev_job_history_reset(DevJobHistory *history);

/* Refuses anything that is not a settled job, and refuses a second push of
   the id already at the head: the runtime notices termination from an idle
   pass that runs many times a second, so "push on terminal state" would
   otherwise fill the ring with one job. */
int dev_job_history_push(DevJobHistory *history, const DevJobSummary *summary);

int dev_job_history_count(const DevJobHistory *history);

/* Index 0 is the most recent job. NULL when the index is past the end. */
const DevJobSummary *dev_job_history_at(const DevJobHistory *history,
                                        int index);

const char *dev_job_state_name(DevJobState state);

#endif
