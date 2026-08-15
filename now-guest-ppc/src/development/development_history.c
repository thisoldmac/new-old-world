#include "development_history.h"

#include <string.h>

static int settled(DevJobState state)
{
    return state == kDevJobSucceeded || state == kDevJobFailed
        || state == kDevJobCancelled;
}

void dev_job_history_reset(DevJobHistory *history)
{
    if (history == NULL) return;
    memset(history, 0, sizeof *history);
}

const char *dev_job_state_name(DevJobState state)
{
    switch (state) {
    case kDevJobQueued: return "queued";
    case kDevJobRunning: return "running";
    case kDevJobSucceeded: return "succeeded";
    case kDevJobFailed: return "failed";
    case kDevJobCancelled: return "cancelled";
    default: return "idle";
    }
}

int dev_job_history_push(DevJobHistory *history, const DevJobSummary *summary)
{
    const DevJobSummary *head;
    if (history == NULL || summary == NULL || summary->id[0] == '\0'
        || !settled(summary->state)) return 0;
    head = dev_job_history_at(history, 0);
    if (head != NULL && strcmp(head->id, summary->id) == 0) return 0;
    history->entries[history->next] = *summary;
    history->next = (history->next + 1) % kDevJobHistoryMax;
    if (history->count < kDevJobHistoryMax) history->count++;
    history->recorded++;
    return 1;
}

int dev_job_history_count(const DevJobHistory *history)
{
    return history == NULL ? 0 : history->count;
}

const DevJobSummary *dev_job_history_at(const DevJobHistory *history,
                                        int index)
{
    int slot;
    if (history == NULL || index < 0 || index >= history->count) return NULL;
    /* next points one past the newest, so walking back from it gives most
       recent first however far the ring has wrapped. */
    slot = history->next - 1 - index;
    while (slot < 0) slot += kDevJobHistoryMax;
    return &history->entries[slot];
}
