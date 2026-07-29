/* Host-side test for NOW-68K's census page, its census.report serializer
 * and its `census` row renderer (src/census/n68_census.c).
 *
 * WHAT THIS DOES NOT TEST, said first because a green line here would
 * otherwise read as "the 68K census works". Every PROBE lives in
 * census68.c and is Gestalt, the drive queue, the unit table, ADB,
 * Parameter RAM and the Power Manager - none of which exists on this
 * machine, and none of which is reachable from any gate in this
 * repository. Nothing below proves that a PowerBook 180c reports its own
 * battery, or that the drive queue walk finds a disk. What is proved is
 * that whatever a probe finds survives the trip: the paging arithmetic,
 * the frame bound, and the two renderers.
 *
 * The properties, and why each one is worth a test rather than a reading:
 *
 *   - paging visits every row exactly once. The page owns the cursor
 *     (n68_census.h), so an off-by-one here is a hardware fact silently
 *     dropped from a report that looks complete, or a host paging forever.
 *     The walk follows `more`/`cursor` the way a host does rather than
 *     asserting on one page's numbers.
 *   - a row goes in whole or not at all. A frame that stops mid-JSON
 *     decodes to nothing on the host and costs the WHOLE report, so the
 *     interesting cases are the ones where a row ALMOST fits.
 *   - `more` is never true with an empty page at an ample capacity, which
 *     is an infinite paging loop rather than a small report.
 *   - the tail is reserved. A report that spent its last bytes on a row
 *     and could not then say `more` ends a probe halfway through and
 *     claims it finished.
 *   - the worst-case bounds NOW68K_CENSUS_*_MAX, which wire68.c's static
 *     assert reasons against. A bound nobody re-measures stops being one,
 *     so this file BUILDS the worst case and measures it.
 *   - sanitizing at the seam. It is what makes those bounds arithmetic
 *     rather than a 6x guess, so a high MacRoman byte in a volume name
 *     must not reach the JSON.
 *   - absent and refused staying distinct through both renderers. That
 *     distinction is the reason this subsystem is shaped the way it is.
 *
 * The parser is deliberately dumb - substring searches over the emitted
 * text, not a JSON reader. A test that parsed with the guest's own scanner
 * would be testing one half twice (AGENTS.md).
 */

#include "n68_census.h"

#include <stdio.h>
#include <string.h>

enum { kAmpleCap = 4096 };

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
        g_checks++; \
        if (!(cond)) { \
            g_failures++; \
            printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        } \
    } while (0)

static int contains(const char *hay, const char *needle)
{
    return strstr(hay, needle) != NULL;
}

/* A stand-in probe: `n` rows named row0..rowN, gathered from `cursor` the
 * way every gatherer in census68.c is written - offer every row, let the
 * page decide. */
static void fake_probe(N68CensusPage *page, long cursor, int n)
{
    int i;

    n68_census_page_init(page, cursor);
    for (i = 0; i < n; ++i) {
        char name[16];
        char raw[16];

        sprintf(name, "row%d", i);
        sprintf(raw, "%d", i);
        n68_census_page_add(page, name, raw, "a fact");
    }
}

/* ---- the page ---------------------------------------------------------- */

static void test_the_page_counts_what_it_skips(void)
{
    N68CensusPage page;

    fake_probe(&page, 3, 8);
    CHECK(page.seen == 8, "seen must count every row the probe offered");
    CHECK(page.count == 5, "five rows survive a cursor of three");
    CHECK(strcmp(page.rows[0].name, "row3") == 0,
          "the page must start at the cursor");
    CHECK(page.overflow == 0, "five rows do not overflow a ten-row page");
}

static void test_a_page_overflows_rather_than_lying(void)
{
    N68CensusPage page;

    fake_probe(&page, 0, kN68CensusRowsMax + 4);
    CHECK(page.count == kN68CensusRowsMax, "the page fills to its cap");
    CHECK(page.overflow == 1, "and says it could not hold the rest");
    CHECK(page.seen == kN68CensusRowsMax + 4,
          "total counts the rows that did not fit");
}

static void test_a_cursor_past_the_end_is_an_empty_page(void)
{
    N68CensusPage page;
    char out[kAmpleCap];

    fake_probe(&page, 99, 4);
    CHECK(page.count == 0, "nothing is left past the end");
    CHECK(n68_census_report_json("volumes", 7, &page, out, sizeof out) > 0,
          "an empty final page is still a report");
    CHECK(contains(out, "\"more\":false"),
          "an empty page must never claim more follows - that is the "
          "infinite paging loop");
}

static void test_fields_are_truncated_and_sanitized(void)
{
    N68CensusPage page;
    char out[kAmpleCap];
    char wide[200];
    int i;

    for (i = 0; i < (int)sizeof wide - 1; ++i) {
        wide[i] = 'x';
    }
    wide[sizeof wide - 1] = '\0';

    n68_census_page_init(&page, 0);
    n68_census_page_add(&page, wide, wide, wide);
    CHECK((int)strlen(page.rows[0].name) == kN68CensusNameCap - 1,
          "a name is truncated at its member's capacity");
    CHECK((int)strlen(page.rows[0].raw) == kN68CensusRawCap - 1,
          "so is a raw value");
    CHECK((int)strlen(page.rows[0].meaning) == kN68CensusMeaningCap - 1,
          "so is a meaning");

    n68_census_page_init(&page, 0);
    /* A MacRoman high byte (an accented volume name), a quote and a
     * backslash - the three classes that could otherwise break the JSON
     * this file appends without an escaper. */
    n68_census_page_add(&page, "Mich\xe9le\"s\\HD", "\x01\x02", "ok");
    CHECK(strcmp(page.rows[0].name, "Mich.le.s.HD") == 0,
          "high bytes, quotes and backslashes are sanitized at the seam");
    CHECK(strcmp(page.rows[0].raw, "..") == 0,
          "control bytes are sanitized too");
    CHECK(n68_census_report_json("volumes", 1, &page, out, sizeof out) > 0,
          "and the report still builds");
    CHECK(!contains(out, "\\"),
          "nothing that could escape our own string literal reaches the "
          "wire");
}

/* ---- the wire renderer -------------------------------------------------- */

static void test_a_report_carries_its_required_fields(void)
{
    N68CensusPage page;
    char out[kAmpleCap];
    long n;

    fake_probe(&page, 0, 2);
    n68_census_page_say(&page, kN68CensusPresent, NULL);
    n = n68_census_report_json("identity", 42, &page, out, sizeof out);
    CHECK(n > 0 && n == (long)strlen(out), "the length is what was written");
    CHECK(contains(out, "\"type\":\"census.report\""), "type");
    CHECK(contains(out, "\"id\":42"), "the id is echoed");
    CHECK(contains(out, "\"probe\":\"identity\""), "the probe is echoed");
    CHECK(contains(out, "\"outcome\":\"present\""), "outcome");
    CHECK(contains(out, "\"rows\":[[\"row0\",\"0\",\"a fact\"],"
                        "[\"row1\",\"1\",\"a fact\"]]"),
          "rows are [name, raw, meaning] triples in order");
    CHECK(contains(out, "\"more\":false"), "more");
    CHECK(contains(out, "\"total\":2"), "total is the rows the probe has");
    CHECK(!contains(out, "\"cursor\""),
          "cursor is meaningless when nothing follows and must be absent");
}

static void test_absent_is_not_refused(void)
{
    N68CensusPage page;
    char out[kAmpleCap];

    n68_census_page_init(&page, 0);
    n68_census_page_say(&page, kN68CensusAbsent, "no ATA bus on this Mac");
    CHECK(n68_census_report_json("ata", 1, &page, out, sizeof out) > 0, "built");
    CHECK(contains(out, "\"outcome\":\"absent\""),
          "the machine said no, and the report must say absent");
    CHECK(contains(out, "\"note\":\"no ATA bus on this Mac\""),
          "an outcome that is not present carries its reason");

    n68_census_page_init(&page, 0);
    n68_census_page_say(&page, kN68CensusRefused, "never attended here");
    CHECK(n68_census_report_json("scsi", 1, &page, out, sizeof out) > 0, "built");
    CHECK(contains(out, "\"outcome\":\"refused\""),
          "this build declined to look, and that is a different word");
}

static void test_paging_visits_every_row_exactly_once(void)
{
    const int kTotal = kN68CensusRowsMax * 3 + 5;
    int seen[128];
    long cursor = 0;
    int pages = 0;
    int i;

    memset(seen, 0, sizeof seen);
    for (;;) {
        N68CensusPage page;
        char out[kAmpleCap];
        int row;

        fake_probe(&page, cursor, kTotal);
        CHECK(n68_census_report_json("drives", 1, &page, out, sizeof out) > 0,
              "every page renders");
        for (row = 0; row < page.count; ++row) {
            int index;

            if (sscanf(page.rows[row].raw, "%d", &index) == 1
                && index >= 0 && index < kTotal) {
                seen[index]++;
            }
        }
        if (++pages > 20) {
            CHECK(0, "paging did not terminate");
            return;
        }
        if (!contains(out, "\"more\":true")) {
            break;
        }
        cursor += page.count;
    }
    for (i = 0; i < kTotal; ++i) {
        CHECK(seen[i] == 1, "every row appears exactly once across the pages");
    }
}

/* The property the tail reservation exists for: at a capacity where the
 * rows would fill the buffer, the report must still be able to say `more`
 * and where to resume - and the cursor must count what was WRITTEN, not
 * what was gathered. */
static void test_a_tight_frame_pages_rather_than_truncating(void)
{
    N68CensusPage page;
    char out[NOW68K_CENSUS_MIN_CAP];
    const char *at;
    long n;
    int cursor = -1;
    int rows_in_frame = 0;
    int i;

    /* Rows wide enough that ten of them cannot fit the minimum frame, so
     * the paging path is the one under test rather than the buffer being
     * generous. */
    n68_census_page_init(&page, 0);
    for (i = 0; i < kN68CensusRowsMax; ++i) {
        char name[kN68CensusNameCap];

        sprintf(name, "unit %d................", i);
        n68_census_page_add(&page, name, "refNum -12345678901234567890",
                            "a driver with a long enough name to matter");
    }
    n = n68_census_report_json("drivers", 5, &page, out, sizeof out);
    CHECK(n > 0, "a minimum-capacity report is still a report");
    CHECK(contains(out, "\"more\":true"), "and says more follows");
    at = strstr(out, "\"cursor\":");
    CHECK(at != NULL && sscanf(at + 9, "%d", &cursor) == 1,
          "a report that says more must say where to resume");
    for (i = 0; i < kN68CensusRowsMax; ++i) {
        char want[kN68CensusNameCap + 4];

        sprintf(want, "\"unit %d..", i);
        if (contains(out, want)) {
            ++rows_in_frame;
        }
    }
    CHECK(cursor == rows_in_frame,
          "the cursor counts the rows WRITTEN, not the rows gathered - "
          "otherwise the ones the frame could not carry are lost");
    CHECK(cursor > 0 && cursor < kN68CensusRowsMax,
          "a tight frame carries some rows and defers the rest");
    CHECK(out[n - 1] == '}', "the JSON is complete, not cut off");
    CHECK(contains(out, "\"total\":10"), "total survives a tight frame");
}

static void test_a_row_goes_in_whole_or_not_at_all(void)
{
    int cap;

    /* Sweep every capacity around the minimum. At each one the report is
     * either nothing at all or a complete JSON object - never a frame that
     * stops in the middle of a row, which decodes to nothing on the host
     * and costs the whole page rather than one row. */
    for (cap = 40; cap < NOW68K_CENSUS_MIN_CAP + 200; ++cap) {
        N68CensusPage page;
        char out[NOW68K_CENSUS_MIN_CAP + 256];
        long n;

        fake_probe(&page, 0, 6);
        n68_census_page_say(&page, kN68CensusPartial, "a note of some length");
        memset(out, '#', sizeof out);
        n = n68_census_report_json("pram", 3, &page, out, (long)cap);
        if (n == 0) {
            g_checks++;
            if (out[0] != '\0') {
                g_failures++;
                printf("FAIL: a refused report must leave an empty string "
                       "(cap %d)\n", cap);
            }
            continue;
        }
        g_checks++;
        if (n >= cap || out[n] != '\0' || out[n - 1] != '}'
            || !contains(out, "\"type\":\"census.report\"")) {
            g_failures++;
            printf("FAIL: incomplete report at cap %d (%ld bytes)\n", cap, n);
        }
    }
}

/* The bounds wire68.c's static assert reasons against, measured rather
 * than remembered. */
static void test_worst_case_parts_are_within_their_bounds(void)
{
    N68CensusPage page;
    char out[kAmpleCap];
    char wide[256];
    long n;
    int i;

    for (i = 0; i < (int)sizeof wide - 1; ++i) {
        wide[i] = 'W';
    }
    wide[sizeof wide - 1] = '\0';

    /* head: the longest envelope before the first row - the longest
     * outcome word, a full-width probe name and a wide id. */
    n68_census_page_init(&page, 0);
    n68_census_page_say(&page, kN68CensusNotAttempted, NULL);
    n = n68_census_report_json(wide, 2147483647L, &page, out, sizeof out);
    CHECK(n > 0, "the head builds");
    CHECK(n - (long)strlen("],\"more\":false,\"total\":0}")
              <= NOW68K_CENSUS_HEAD_MAX,
          "NOW68K_CENSUS_HEAD_MAX no longer bounds the envelope");

    /* row: one row of full-width fields. */
    n68_census_page_init(&page, 0);
    n68_census_page_add(&page, wide, wide, wide);
    {
        long with_row = n68_census_report_json("x", 0, &page, out, sizeof out);
        long without;

        n68_census_page_init(&page, 0);
        without = n68_census_report_json("x", 0, &page, out, sizeof out);
        CHECK(with_row - without <= NOW68K_CENSUS_ROW_MAX,
              "NOW68K_CENSUS_ROW_MAX no longer bounds a full-width row");
    }

    /* tail: more + cursor + total + the longest note. */
    fake_probe(&page, 0, kN68CensusRowsMax + 1);
    n68_census_page_say(&page, kN68CensusPartial, wide);
    n = n68_census_report_json("x", 0, &page, out, sizeof out);
    {
        const char *rows_end = strstr(out, "],\"more\"");

        CHECK(rows_end != NULL, "the tail is where it is expected");
        if (rows_end != NULL) {
            CHECK(n - (rows_end - out) <= NOW68K_CENSUS_TAIL_MAX,
                  "NOW68K_CENSUS_TAIL_MAX no longer bounds the tail");
        }
    }
}

/* ---- the console renderer ----------------------------------------------- */

static void test_rows_collapse_the_triple(void)
{
    N68CensusPage page;
    N68CmdRows rows;

    n68_census_page_init(&page, 0);
    n68_census_page_add(&page, "Model", "33", "PowerBook 180c");
    /* A row with no decoded form: the raw value must fold into the value
     * column rather than being dropped, or a console shows a blank where
     * the wire carries a number. */
    n68_census_page_add(&page, "raw +0", "A8 00 01 02", "");
    n68_cmdrows_init(&rows);
    n68_census_rows("identity", &page, &rows);

    CHECK(rows.ok == 1, "a gathered page is a successful command");
    CHECK(rows.count == 2, "two rows, and no status row on a clean page");
    CHECK(strcmp(rows.rows[0].label, "Model") == 0, "the label is the name");
    CHECK(strcmp(rows.rows[0].value, "PowerBook 180c") == 0,
          "the meaning is the value");
    CHECK(strcmp(rows.rows[1].value, "A8 00 01 02") == 0,
          "a row with no meaning keeps its raw value");
}

static void test_an_absent_probe_still_says_something(void)
{
    N68CensusPage page;
    N68CmdRows rows;

    n68_census_page_init(&page, 0);
    n68_census_page_say(&page, kN68CensusAbsent,
                        "no PC Card sockets - PCMCIA arrived after this Mac");
    n68_cmdrows_init(&rows);
    n68_census_rows("pccard", &page, &rows);

    CHECK(rows.count == 1, "an empty page still renders one row");
    CHECK(strcmp(rows.rows[0].label, "(pccard)") == 0,
          "the status row names the probe");
    CHECK(strncmp(rows.rows[0].value, "absent - ", 9) == 0,
          "a console that printed nothing could not be told from a command "
          "that failed");
}

static void test_the_status_row_keeps_the_outcome_when_the_note_is_long(void)
{
    N68CensusPage page;
    N68CmdRows rows;

    n68_census_page_init(&page, 0);
    n68_census_page_say(&page, kN68CensusPartial,
                        "20 of 256 bytes - the XPRAM trap is not declared in "
                        "these headers");
    n68_cmdrows_init(&rows);
    n68_census_rows("pram", &page, &rows);
    CHECK(rows.count == 1, "one status row");
    CHECK(strncmp(rows.rows[0].value, "partial", 7) == 0,
          "the outcome word is never given up to fit the note");
}

static void test_more_is_stated_to_a_person(void)
{
    N68CensusPage page;
    N68CmdRows rows;

    fake_probe(&page, 0, kN68CensusRowsMax + 3);
    n68_cmdrows_init(&rows);
    n68_census_rows("drivers", &page, &rows);
    CHECK(contains(rows.rows[rows.count - 1].value, "more"),
          "a person must be told the page was not the whole answer");
}

/* The exact bytes of one report, so a change to the wire shape is visible
 * in a diff rather than only in a property. This is also the fixture the
 * host's GuestWireFixtureTests carries for this guest's census.report. */
static void test_the_exact_bytes(void)
{
    N68CensusPage page;
    char out[kAmpleCap];
    static const char kWant[] =
        "{\"type\":\"census.report\",\"id\":9,\"probe\":\"pram\","
        "\"outcome\":\"partial\",\"rows\":["
        "[\"valid\",\"$A8\",\"$A8 - Parameter RAM is being retained\"],"
        "[\"Addressing\",\"\",\"24-bit now, 32-bit capable\"]],"
        "\"more\":false,\"total\":2,"
        "\"note\":\"20 of 256 bytes - no XPRAM trap in these headers\"}";

    n68_census_page_init(&page, 0);
    n68_census_page_add(&page, "valid", "$A8",
                        "$A8 - Parameter RAM is being retained");
    n68_census_page_add(&page, "Addressing", "", "24-bit now, 32-bit capable");
    n68_census_page_say(&page, kN68CensusPartial,
                        "20 of 256 bytes - no XPRAM trap in these headers");
    n68_census_report_json("pram", 9, &page, out, sizeof out);
    CHECK(strcmp(out, kWant) == 0, "the exact census.report bytes changed");
    if (strcmp(out, kWant) != 0) {
        printf("  want: %s\n  got:  %s\n", kWant, out);
    }
}

int main(void)
{
    test_the_page_counts_what_it_skips();
    test_a_page_overflows_rather_than_lying();
    test_a_cursor_past_the_end_is_an_empty_page();
    test_fields_are_truncated_and_sanitized();
    test_a_report_carries_its_required_fields();
    test_absent_is_not_refused();
    test_paging_visits_every_row_exactly_once();
    test_a_tight_frame_pages_rather_than_truncating();
    test_a_row_goes_in_whole_or_not_at_all();
    test_worst_case_parts_are_within_their_bounds();
    test_rows_collapse_the_triple();
    test_an_absent_probe_still_says_something();
    test_the_status_row_keeps_the_outcome_when_the_note_is_long();
    test_more_is_stated_to_a_person();
    test_the_exact_bytes();

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
