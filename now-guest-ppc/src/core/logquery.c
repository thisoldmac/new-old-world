#include "logquery.h"

#include <string.h>

void now_logquery_defaults(LogQuery *q)
{
    q->lines = 20;
    q->area[0] = '\0';
    q->before = 0;
}

static int all_digits(const char *tok, long len)
{
    long i;

    if (len < 1) {
        return 0;
    }
    for (i = 0; i < len; ++i) {
        if (tok[i] < '0' || tok[i] > '9') {
            return 0;
        }
    }
    return 1;
}

static unsigned long parse_digits(const char *tok, long len)
{
    unsigned long v = 0;
    long i;

    for (i = 0; i < len; ++i) {
        v = v * 10 + (unsigned long)(tok[i] - '0');
    }
    return v;
}

void now_logquery_parse_line(const char *line, LogQuery *q)
{
    const char *p = line;
    int have_count = 0;
    int have_area = 0;
    int expect_cursor = 0;

    while (*p != '\0') {
        const char *start;
        long len;

        while (*p == ' ') {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        start = p;
        while (*p != '\0' && *p != ' ') {
            ++p;
        }
        len = (long)(p - start);

        if (all_digits(start, len)) {
            if (expect_cursor) {
                q->before = parse_digits(start, len);
                expect_cursor = 0;
            } else if (!have_count) {
                q->lines = (long)parse_digits(start, len);
                have_count = 1;
            }
            continue;
        }
        expect_cursor = 0;
        if (len == 6 && strncmp(start, "before", 6) == 0) {
            expect_cursor = 1;
            continue;
        }
        if (!have_area) {
            long n = len < kLogQueryAreaMax ? len : kLogQueryAreaMax;

            memcpy(q->area, start, (size_t)n);
            q->area[n] = '\0';
            have_area = 1;
        }
    }
}

int now_logquery_area_matches(const char *stored, const char *tag)
{
    const char *field;
    int i;

    if (tag[0] == '\0') {
        return 1;
    }
    field = strchr(stored, ' ');
    if (field == NULL) {
        return 0;
    }
    ++field;
    for (i = 0; i < kLogQueryAreaMax && tag[i] != '\0'; ++i) {
        if (field[i] != tag[i]) {
            return 0;
        }
    }
    /* The rest of the 6-wide field must be padding: "app" is not a
       match for "appx", or the shorter tag would quietly read another
       area's lines. The field can also END early, because the ring cap
       may have truncated the line itself. */
    for (; i < kLogQueryAreaMax; ++i) {
        if (field[i] == '\0') {
            break;
        }
        if (field[i] != ' ') {
            return 0;
        }
    }
    return 1;
}

void now_logquery_select(const LogQuery *q, LogPage *page)
{
    /* Newest-first scratch; the page is handed over oldest-first. */
    int tmp_idx[kLogQueryPageMax];
    unsigned long tmp_seq[kLogQueryPageMax];
    int count = now_log_count();
    unsigned long newest = now_log_seq();
    long want = q->lines;
    int taken = 0;
    int i;

    memset(page, 0, sizeof *page);
    if (want < 1) {
        want = 1;
    }
    if (want > kLogQueryPageMax) {
        want = kLogQueryPageMax;
    }

    for (i = count - 1; i >= 0; --i) {
        unsigned long seq = newest - (unsigned long)(count - 1 - i);

        if (!now_logquery_area_matches(now_log_line(i), q->area)) {
            continue;
        }
        ++page->matching;
        if (q->before != 0 && seq >= q->before) {
            continue;                 /* newer than the cursor, not older */
        }
        if (taken < want) {
            tmp_idx[taken] = i;
            tmp_seq[taken] = seq;
            ++taken;
        } else {
            ++page->older;            /* the next page's lines */
        }
    }

    page->returned = taken;
    for (i = 0; i < taken; ++i) {
        page->idx[i] = tmp_idx[taken - 1 - i];
        page->seq[i] = tmp_seq[taken - 1 - i];
    }
}
