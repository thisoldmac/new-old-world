/* The log ring's selection — `tail`'s shared half — off the Toolbox.
 *
 * logquery.c decides which lines a page holds: the grammar both faces
 * parse, the area match, and the cursor that walks a LIVE ring without
 * skipping or repeating a line. Every one of those is a rule a wrong
 * implementation would get plausibly wrong rather than crash on, and
 * the machine it would be wrong about is a PowerBook in another room —
 * so the rules are asserted here, with this harness standing in for
 * nowlog.c's ring the way json_native_test.c stands in for the wire.
 *
 * The paging walk matters most: a cursor that used > where >= belongs
 * repeats the boundary line on every page, and one that renumbered on
 * roll-off would silently skip whatever arrived mid-retrieval. Both are
 * walked here across a rolled ring.
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "logquery.h"

/* ---- The harness's ring: what nowlog.c provides in the guest. ---- */

#define FAKE_MAX 64

static char g_fake[FAKE_MAX][120];
static int g_fake_count;
static unsigned long g_fake_seq;      /* seq of the NEWEST held line */

int now_log_count(void) { return g_fake_count; }
unsigned long now_log_seq(void) { return g_fake_seq; }
const char *now_log_line(int index)
{
    assert(index >= 0 && index < g_fake_count);
    return g_fake[index];
}

static void ring_reset(void)
{
    g_fake_count = 0;
    g_fake_seq = 0;
}

/* Append one line the way nowlog.c formats one: "HH:MM:SS area  msg",
   the area padded to 6. `rolled` lines are simulated as already gone by
   bumping the newest sequence past the held count. */
static void ring_add(const char *area, const char *msg)
{
    assert(g_fake_count < FAKE_MAX);
    snprintf(g_fake[g_fake_count], sizeof g_fake[0], "12:00:%02d %-6.6s %s",
             g_fake_count % 60, area, msg);
    ++g_fake_count;
    ++g_fake_seq;
}

static void ring_roll(unsigned long rolled_off)
{
    g_fake_seq += rolled_off;         /* held lines keep their positions;
                                         the fake just ages the numbering
                                         the way a full ring does */
}

/* ---- The grammar ---- */

static void test_parse(void)
{
    LogQuery q;

    now_logquery_defaults(&q);
    assert(q.lines == 20 && q.area[0] == '\0' && q.before == 0);

    now_logquery_parse_line("", &q);
    assert(q.lines == 20 && q.area[0] == '\0' && q.before == 0);

    now_logquery_defaults(&q);
    now_logquery_parse_line("40", &q);
    assert(q.lines == 40 && q.area[0] == '\0' && q.before == 0);

    now_logquery_defaults(&q);
    now_logquery_parse_line("40 files", &q);
    assert(q.lines == 40 && strcmp(q.area, "files") == 0);

    now_logquery_defaults(&q);
    now_logquery_parse_line("files", &q);
    assert(q.lines == 20 && strcmp(q.area, "files") == 0);

    now_logquery_defaults(&q);
    now_logquery_parse_line("40 files before 123", &q);
    assert(q.lines == 40 && strcmp(q.area, "files") == 0
           && q.before == 123);

    now_logquery_defaults(&q);
    now_logquery_parse_line("before 900", &q);
    assert(q.lines == 20 && q.area[0] == '\0' && q.before == 900);

    /* "before" with no number does not eat a later count, and a second
       integer is not a cursor: the first bare integer is the count,
       full stop. */
    now_logquery_defaults(&q);
    now_logquery_parse_line("before files 7", &q);
    assert(q.before == 0 && strcmp(q.area, "files") == 0 && q.lines == 7);

    /* A tag longer than the field truncates to what could ever match. */
    now_logquery_defaults(&q);
    now_logquery_parse_line("continuity", &q);
    assert(strcmp(q.area, "contin") == 0);

    /* Lenience kept from the old grammar: extra words are ignored. */
    now_logquery_defaults(&q);
    now_logquery_parse_line("10 files junk 99", &q);
    assert(q.lines == 10 && strcmp(q.area, "files") == 0 && q.before == 0);
}

/* ---- The area match ---- */

static void test_area_match(void)
{
    assert(now_logquery_area_matches("12:00:00 files  put began", ""));
    assert(now_logquery_area_matches("12:00:00 files  put began", "files"));
    assert(!now_logquery_area_matches("12:00:00 files  put began", "file"));
    assert(!now_logquery_area_matches("12:00:00 filesx put began", "files"));
    assert(!now_logquery_area_matches("12:00:00 wire   sent", "files"));
    /* A 6-character tag fills its field: no padding to check. */
    assert(now_logquery_area_matches("12:00:00 contin armed", "contin"));
    /* No space at all: only the match-everything tag can claim it. */
    assert(!now_logquery_area_matches("nospace", "files"));
    assert(now_logquery_area_matches("nospace", ""));
}

/* ---- Selection and paging ---- */

static void test_select_newest_and_order(void)
{
    LogQuery q;
    LogPage p;

    ring_reset();
    ring_add("app", "one");
    ring_add("files", "two");
    ring_add("wire", "three");
    ring_add("files", "four");
    ring_add("files", "five");

    now_logquery_defaults(&q);
    q.lines = 2;
    now_logquery_select(&q, &p);
    assert(p.returned == 2);
    assert(p.matching == 5);
    assert(p.older == 3);
    /* Oldest-first inside the page, and the NEWEST lines of the ring. */
    assert(strstr(now_log_line(p.idx[0]), "four") != NULL);
    assert(strstr(now_log_line(p.idx[1]), "five") != NULL);
    assert(p.seq[0] == 4 && p.seq[1] == 5);
}

static void test_select_area(void)
{
    LogQuery q;
    LogPage p;

    ring_reset();
    ring_add("app", "one");
    ring_add("files", "two");
    ring_add("wire", "three");
    ring_add("files", "four");

    now_logquery_defaults(&q);
    strcpy(q.area, "files");
    now_logquery_select(&q, &p);
    assert(p.returned == 2);
    assert(p.matching == 2);
    assert(p.older == 0);
    assert(strstr(now_log_line(p.idx[0]), "two") != NULL);
    assert(strstr(now_log_line(p.idx[1]), "four") != NULL);
    assert(p.seq[0] == 2 && p.seq[1] == 4);
}

/* Page with `before` = the previous page's oldest sequence: every line
   is served exactly once, however many pages it takes. */
static void test_paging_covers_everything_once(void)
{
    LogQuery q;
    LogPage p;
    int seen[13];
    unsigned long cursor = 0;
    int total = 0;
    int i;

    ring_reset();
    for (i = 0; i < 12; ++i) {
        ring_add(i % 2 == 0 ? "wire" : "files", "line");
    }
    memset(seen, 0, sizeof seen);

    for (;;) {
        now_logquery_defaults(&q);
        q.lines = 5;
        q.before = cursor;
        now_logquery_select(&q, &p);
        assert(p.matching == 12);
        if (p.returned == 0) {
            break;
        }
        for (i = 0; i < p.returned; ++i) {
            assert(p.seq[i] >= 1 && p.seq[i] <= 12);
            ++seen[p.seq[i]];
        }
        total += p.returned;
        /* The last page reports nothing older; the others hand over the
           cursor that reaches the remainder. */
        if (p.older == 0) {
            break;
        }
        cursor = p.seq[0];
    }
    assert(total == 12);
    for (i = 1; i <= 12; ++i) {
        assert(seen[i] == 1);
    }
}

/* The ring is live: sequence numbers survive roll-off, so a cursor taken
   before lines rolled away still names the same lines afterwards. */
static void test_cursor_survives_roll(void)
{
    LogQuery q;
    LogPage p;

    ring_reset();
    ring_add("wire", "kept-a");      /* seq 1 before the roll */
    ring_add("wire", "kept-b");
    ring_add("wire", "kept-c");
    ring_roll(100);                  /* 100 older lines already gone:
                                        held lines now seq 101..103 */

    now_logquery_defaults(&q);
    q.lines = 1;
    now_logquery_select(&q, &p);
    assert(p.returned == 1 && p.seq[0] == 103);
    assert(p.older == 2);

    q.before = p.seq[0];
    now_logquery_select(&q, &p);
    assert(p.returned == 1 && p.seq[0] == 102);
    assert(strstr(now_log_line(p.idx[0]), "kept-b") != NULL);

    /* A cursor below everything held answers empty rather than wrapping:
       those lines are gone, and pretending otherwise would serve the
       newest lines as the oldest. */
    q.before = 50;
    now_logquery_select(&q, &p);
    assert(p.returned == 0 && p.older == 0 && p.matching == 3);
}

static void test_clamps(void)
{
    LogQuery q;
    LogPage p;
    int i;

    ring_reset();
    for (i = 0; i < 50; ++i) {
        ring_add("wire", "line");
    }

    now_logquery_defaults(&q);
    q.lines = 999;                    /* more than a page: clamped, and
                                         the rest reported as older */
    now_logquery_select(&q, &p);
    assert(p.returned == kLogQueryPageMax);
    assert(p.older == 50 - kLogQueryPageMax);

    q.lines = -3;
    now_logquery_select(&q, &p);
    assert(p.returned == 1);
}

int main(void)
{
    test_parse();
    test_area_match();
    test_select_newest_and_order();
    test_select_area();
    test_paging_covers_everything_once();
    test_cursor_survives_roll();
    test_clamps();
    printf("logquery_native_test: ok\n");
    return 0;
}
