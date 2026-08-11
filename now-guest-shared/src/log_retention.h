#ifndef NOW_LOG_RETENTION_H
#define NOW_LOG_RETENTION_H

enum {
    kNowLogRetentionDefault = 10,
    kNowLogRetentionMin = 1,
    kNowLogRetentionMax = 100,
    kNowLogDialectPPC = 1,
    kNowLogDialect68K = 2
};

typedef struct NowLogCandidate {
    unsigned long created;
    unsigned char name[32];           /* Pascal, HFS maximum */
    int current;
} NowLogCandidate;

unsigned short now_log_retention_sanitize(long requested);
int now_log_name_matches(const unsigned char *pascal_name, int dialect);
int now_log_candidate_older(const NowLogCandidate *a,
                            const NowLogCandidate *b);
int now_log_choose_prune(const NowLogCandidate *entries, int count,
                         unsigned short keep);

#endif
