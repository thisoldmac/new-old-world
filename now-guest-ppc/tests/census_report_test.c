/* Native test for the census.report serializer - runs on the host:
   cc -Wall -Wextra -Werror -I ../src census_report_test.c \
      ../src/census_report.c ../src/json.c -o census_report_test \
      && ./census_report_test
   Pure C on both sides, the json_native_test.c pattern. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "census.h"
#include "json.h"

static CensusPage page_with(int count, CensusOutcome outcome, int more)
{
    CensusPage page;
    int i;

    memset(&page, 0, sizeof page);
    page.count = count;
    page.outcome = outcome;
    page.more = more;
    page.next_cursor = 40;
    page.total = -1;
    for (i = 0; i < count && i < kCensusPageMax; i++) {
        snprintf(page.rows[i].name, sizeof page.rows[i].name, "row%d", i);
        snprintf(page.rows[i].raw, sizeof page.rows[i].raw, "0x%02X", i);
        snprintf(page.rows[i].meaning, sizeof page.rows[i].meaning,
                 "meaning %d", i);
    }
    return page;
}

static void test_basic_shape(void)
{
    CensusPage page = page_with(2, kCensusPresent, 0);
    char out[1024];
    char text[64];
    long n = census_report_json("gestalt", 7, &page, out, sizeof out);

    assert(n > 0);
    assert(n == (long)strlen(out));
    assert(now_json_type_is(out, "census.report"));
    assert(now_json_find_int(out, "id", -1) == 7);
    assert(now_json_find_string(out, "probe", text, sizeof text));
    assert(strcmp(text, "gestalt") == 0);
    assert(now_json_find_string(out, "outcome", text, sizeof text));
    assert(strcmp(text, "present") == 0);
    assert(!now_json_find_bool(out, "more", 1));
    assert(strstr(out, "\"rows\":[[\"row0\",\"0x00\",\"meaning 0\"],"
                       "[\"row1\",\"0x01\",\"meaning 1\"]]") != NULL);
    /* more=false: no cursor; total -1 and empty note: omitted */
    assert(strstr(out, "cursor") == NULL);
    assert(strstr(out, "total") == NULL);
    assert(strstr(out, "note") == NULL);
}

static void test_pagination_fields(void)
{
    CensusPage page = page_with(1, kCensusPartial, 1);
    char out[1024];
    char text[96];
    long n;

    page.total = 209;
    snprintf(page.note, sizeof page.note, "20 of 256 bytes");
    n = census_report_json("pram", 3, &page, out, sizeof out);
    assert(n > 0);
    assert(now_json_find_bool(out, "more", 0));
    assert(now_json_find_int(out, "cursor", -1) == 40);
    assert(now_json_find_int(out, "total", -1) == 209);
    assert(now_json_find_string(out, "outcome", text, sizeof text));
    assert(strcmp(text, "partial") == 0);
    assert(now_json_find_string(out, "note", text, sizeof text));
    assert(strcmp(text, "20 of 256 bytes") == 0);
}

static void test_escaping(void)
{
    CensusPage page = page_with(1, kCensusPresent, 0);
    char out[1024];
    long n;

    snprintf(page.rows[0].meaning, sizeof page.rows[0].meaning,
             "say \"hi\" \\ done");
    n = census_report_json("video", 1, &page, out, sizeof out);
    assert(n > 0);
    assert(strstr(out, "say \\\"hi\\\" \\\\ done") != NULL);
}

static void test_empty_rows(void)
{
    CensusPage page = page_with(0, kCensusRefused, 0);
    char out[512];
    char text[64];
    long n;

    snprintf(page.note, sizeof page.note, "not served yet");
    n = census_report_json("scsi", 9, &page, out, sizeof out);
    assert(n > 0);
    assert(strstr(out, "\"rows\":[]") != NULL);
    assert(now_json_find_string(out, "outcome", text, sizeof text));
    assert(strcmp(text, "refused") == 0);
}

static void test_overflow_is_refused_not_truncated(void)
{
    CensusPage page = page_with(kCensusPageMax, kCensusPresent, 1);
    char out[128];
    long n = census_report_json("gestalt", 1, &page, out, sizeof out);

    assert(n == -1);   /* a frame that cannot fit never goes out cut short */
}

static void test_oversized_page_is_a_bug(void)
{
    CensusPage page = page_with(kCensusPageMax, kCensusPresent, 0);
    char out[4096];

    page.count = kCensusPageMax + 1;
    assert(census_report_json("gestalt", 1, &page, out, sizeof out) == -1);
}

static void test_outcome_names(void)
{
    assert(strcmp(census_outcome_name(kCensusPresent), "present") == 0);
    assert(strcmp(census_outcome_name(kCensusAbsent), "absent") == 0);
    assert(strcmp(census_outcome_name(kCensusPartial), "partial") == 0);
    assert(strcmp(census_outcome_name(kCensusRefused), "refused") == 0);
    assert(strcmp(census_outcome_name(kCensusFailed), "failed") == 0);
    assert(strcmp(census_outcome_name(kCensusNotAttempted),
                  "not-attempted") == 0);
}

int main(void)
{
    test_basic_shape();
    test_pagination_fields();
    test_escaping();
    test_empty_rows();
    test_overflow_is_refused_not_truncated();
    test_oversized_page_is_a_bug();
    test_outcome_names();
    printf("census_report_test: ok\n");
    return 0;
}
