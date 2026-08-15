#include "development_history.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static DevJobSummary settled_job(const char *id, DevJobState state)
{
    DevJobSummary summary;
    memset(&summary, 0, sizeof summary);
    snprintf(summary.id, sizeof summary.id, "%s", id);
    snprintf(summary.project_id, sizeof summary.project_id, "%s",
             "0123456789abcdef0123456789abcdef");
    snprintf(summary.project_name, sizeof summary.project_name, "%s",
             "Memory Meter");
    summary.state = state;
    summary.actions_total = 4;
    summary.actions_completed = state == kDevJobSucceeded ? 4 : 2;
    return summary;
}

int main(void)
{
    DevJobHistory history;
    DevJobSummary summary;
    const DevJobSummary *row;
    char id[kDevIdentityCap];
    int i;

    dev_job_history_reset(&history);
    assert(dev_job_history_count(&history) == 0);
    assert(dev_job_history_at(&history, 0) == NULL);

    /* Only settled jobs are history; a running one is the CURRENT job and
       has its own live row on the page. */
    summary = settled_job("build-0001", kDevJobRunning);
    assert(!dev_job_history_push(&history, &summary));
    summary.state = kDevJobQueued;
    assert(!dev_job_history_push(&history, &summary));
    summary.id[0] = '\0';
    summary.state = kDevJobSucceeded;
    assert(!dev_job_history_push(&history, &summary));
    assert(dev_job_history_count(&history) == 0);

    summary = settled_job("build-0001", kDevJobSucceeded);
    assert(dev_job_history_push(&history, &summary));
    /* The runtime notices termination from an idle pass that runs many
       times a second: a second push of the same job must not fill the ring
       with one build. */
    assert(!dev_job_history_push(&history, &summary));
    assert(dev_job_history_count(&history) == 1);
    assert(history.recorded == 1);

    summary = settled_job("build-0002", kDevJobFailed);
    summary.exit_code = 2;
    assert(dev_job_history_push(&history, &summary));
    row = dev_job_history_at(&history, 0);
    assert(row != NULL && strcmp(row->id, "build-0002") == 0);
    assert(row->state == kDevJobFailed && row->exit_code == 2);
    row = dev_job_history_at(&history, 1);
    assert(row != NULL && strcmp(row->id, "build-0001") == 0);
    assert(dev_job_history_at(&history, 2) == NULL);

    /* Wrap the ring twice over and confirm the newest kDevJobHistoryMax are
       what remains, newest first. */
    for (i = 3; i <= 20; ++i) {
        snprintf(id, sizeof id, "build-%04d", i);
        summary = settled_job(id, kDevJobCancelled);
        assert(dev_job_history_push(&history, &summary));
    }
    assert(dev_job_history_count(&history) == kDevJobHistoryMax);
    assert(history.recorded == 20);
    for (i = 0; i < kDevJobHistoryMax; ++i) {
        snprintf(id, sizeof id, "build-%04d", 20 - i);
        row = dev_job_history_at(&history, i);
        assert(row != NULL && strcmp(row->id, id) == 0);
        assert(strcmp(row->project_name, "Memory Meter") == 0);
    }
    assert(dev_job_history_at(&history, kDevJobHistoryMax) == NULL);

    assert(strcmp(dev_job_state_name(kDevJobSucceeded), "succeeded") == 0);
    assert(strcmp(dev_job_state_name(kDevJobCancelled), "cancelled") == 0);
    assert(strcmp(dev_job_state_name(kDevJobIdle), "idle") == 0);

    dev_job_history_reset(&history);
    assert(dev_job_history_count(&history) == 0 && history.recorded == 0);
    return 0;
}
