#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "log_retention.h"

static void pname(unsigned char *out, const char *text)
{
    size_t n = strlen(text);
    out[0] = (unsigned char)n;
    memcpy(out + 1, text, n);
}

int main(void)
{
    NowLogCandidate e[4];
    unsigned char name[32];
    memset(e, 0, sizeof e);

    assert(now_log_retention_sanitize(10) == 10);
    assert(now_log_retention_sanitize(0) == kNowLogRetentionDefault);
    assert(now_log_retention_sanitize(101) == kNowLogRetentionDefault);
    pname(name, "2026-08-10 123456.log");
    assert(now_log_name_matches(name, kNowLogDialectPPC));
    pname(name, "2026-08-10 123456.txt");
    assert(!now_log_name_matches(name, kNowLogDialectPPC));
    pname(name, "NOW-68K log 123456");
    assert(now_log_name_matches(name, kNowLogDialect68K));
    pname(name, "someone else's log");
    assert(!now_log_name_matches(name, kNowLogDialect68K));

    e[0].created = 3; pname(e[0].name, "NOW-68K log 000003");
    e[1].created = 1; pname(e[1].name, "NOW-68K log 000001");
    e[2].created = 2; pname(e[2].name, "NOW-68K log 000002");
    e[3].created = 0; e[3].current = 1;
    pname(e[3].name, "NOW-68K log 000000");
    assert(now_log_choose_prune(e, 4, 3) == 1);
    assert(now_log_choose_prune(e, 4, 4) == -1);
    e[1].created = 2;
    assert(now_log_choose_prune(e, 4, 3) == 1); /* name tie-break */
    puts("log_retention_test ok");
    return 0;
}
