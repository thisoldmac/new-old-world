#include "log_retention.h"

unsigned short now_log_retention_sanitize(long requested)
{
    if (requested < kNowLogRetentionMin
        || requested > kNowLogRetentionMax) {
        return kNowLogRetentionDefault;
    }
    return (unsigned short)requested;
}

static int digits(const unsigned char *s, int first, int count)
{
    int i;
    for (i = first; i < first + count; ++i) {
        if (s[i] < '0' || s[i] > '9') return 0;
    }
    return 1;
}

int now_log_name_matches(const unsigned char *name, int dialect)
{
    const unsigned char *s;
    int i;

    if (name == 0) return 0;
    s = name + 1;
    if (dialect == kNowLogDialectPPC) {
        if (name[0] != 21) return 0;
        if (!digits(s, 0, 4) || s[4] != '-' || !digits(s, 5, 2)
            || s[7] != '-' || !digits(s, 8, 2) || s[10] != ' '
            || !digits(s, 11, 6) || s[17] != '.' || s[18] != 'l'
            || s[19] != 'o' || s[20] != 'g') {
            return 0;
        }
        return 1;
    }
    if (dialect == kNowLogDialect68K) {
        static const char prefix[] = "NOW-68K log ";
        if (name[0] != 18) return 0;
        for (i = 0; i < 12; ++i) {
            if (s[i] != (unsigned char)prefix[i]) return 0;
        }
        return digits(s, 12, 6);
    }
    return 0;
}

static int pascal_compare(const unsigned char *a, const unsigned char *b)
{
    int i;
    int common = a[0] < b[0] ? a[0] : b[0];
    for (i = 1; i <= common; ++i) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return (int)a[0] - (int)b[0];
}

int now_log_candidate_older(const NowLogCandidate *a,
                            const NowLogCandidate *b)
{
    if (b == 0) return 1;
    if (a->created < b->created) return 1;
    if (a->created > b->created) return 0;
    return pascal_compare(a->name, b->name) < 0;
}

int now_log_choose_prune(const NowLogCandidate *entries, int count,
                         unsigned short keep)
{
    int i;
    int oldest = -1;
    keep = now_log_retention_sanitize(keep);
    if (entries == 0 || count <= (int)keep) return -1;
    for (i = 0; i < count; ++i) {
        if (!entries[i].current
            && (oldest < 0
                || now_log_candidate_older(&entries[i], &entries[oldest]))) {
            oldest = i;
        }
    }
    return oldest;
}
