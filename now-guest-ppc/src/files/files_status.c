#include "files_status.h"

#include <stdio.h>
#include <string.h>

static const char k_idle[] = "Ready.";

void now_files_status_reset(FilesStatus *s)
{
    if (s == NULL) {
        return;
    }
    memset(s, 0, sizeof *s);
}

void now_files_status_set(FilesStatus *s, FilesStatusChannel channel,
                          const char *line)
{
    int i;

    if (s == NULL || channel < 0 || channel >= kFilesStatusChannelCount) {
        return;
    }
    i = (int)channel;
    if (line == NULL || line[0] == '\0') {
        s->line[i][0] = '\0';
        s->stamp[i] = 0;
        return;
    }
    /* Rewriting the same words is not news: a channel repeating itself
       every idle pass must not keep stepping over a sibling that has
       something newer to say. */
    if (strncmp(s->line[i], line, kFilesStatusMax - 1) == 0) {
        return;
    }
    snprintf(s->line[i], sizeof s->line[i], "%s", line);
    s->stamp[i] = ++s->clock;
}

FilesStatusChannel now_files_status_source(const FilesStatus *s)
{
    FilesStatusChannel best = kFilesStatusChannelCount;
    long best_stamp = 0;
    int i;

    if (s == NULL) {
        return kFilesStatusChannelCount;
    }
    if (s->line[kFilesStatusTransfer][0] != '\0') {
        return kFilesStatusTransfer;
    }
    for (i = (int)kFilesStatusShare; i <= (int)kFilesStatusBrowse; ++i) {
        if (s->line[i][0] != '\0' && s->stamp[i] > best_stamp) {
            best_stamp = s->stamp[i];
            best = (FilesStatusChannel)i;
        }
    }
    if (best != kFilesStatusChannelCount) {
        return best;
    }
    if (s->line[kFilesStatusLink][0] != '\0') {
        return kFilesStatusLink;
    }
    return kFilesStatusChannelCount;
}

void now_files_status_text(const FilesStatus *s, char *out, long cap)
{
    FilesStatusChannel from;

    if (out == NULL || cap <= 0) {
        return;
    }
    from = now_files_status_source(s);
    if (from == kFilesStatusChannelCount) {
        snprintf(out, (size_t)cap, "%s", k_idle);
        return;
    }
    snprintf(out, (size_t)cap, "%s", s->line[(int)from]);
}
