/*
 * Host test for n68_linesplit / n68_console_ring. No Toolbox, no test
 * framework dependency - plain asserts with a running pass/fail tally so
 * a single run reports everything rather than stopping at the first
 * failure.
 */

#include <stdio.h>
#include <string.h>

#include "n68_console_ring.h"
#include "n68_linesplit.h"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond) check((cond), #cond, __LINE__)

static void check(int cond, const char *what, int line)
{
    g_checks++;
    if (!cond) {
        g_failures++;
        printf("FAIL line %d: %s\n", line, what);
    }
}

static void feed_str(N68ConsoleRing *ring, const char *s)
{
    n68_console_feed(ring, s, strlen(s));
}

static int line_eq(const N68ConsoleLine *line, const char *expect)
{
    size_t expect_len = strlen(expect);
    return line->length == expect_len &&
           memcmp(line->text, expect, expect_len) == 0;
}

/* --- CRLF vs CR vs LF, including a CRLF pair not being two lines --- */
static void test_line_endings(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[8];
    size_t n;

    n68_console_init(&ring);
    feed_str(&ring, "alpha\r\nbeta\rgamma\nomega\r\n");

    n = n68_console_visible_slice(&ring, 0, slice, 8);
    CHECK(n == 4);
    CHECK(line_eq(&slice[0], "alpha"));
    CHECK(line_eq(&slice[1], "beta"));
    CHECK(line_eq(&slice[2], "gamma"));
    CHECK(line_eq(&slice[3], "omega"));
    CHECK(n68_console_dropped_line_count(&ring) == 0);
}

/* --- blank lines are content off the wire and must be retained --- */
static void test_blank_lines_retained(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[8];
    size_t n;

    n68_console_init(&ring);
    feed_str(&ring, "a\n\n\nb\n");

    n = n68_console_visible_slice(&ring, 0, slice, 8);
    CHECK(n == 4);
    CHECK(line_eq(&slice[0], "a"));
    CHECK(line_eq(&slice[1], ""));
    CHECK(line_eq(&slice[2], ""));
    CHECK(line_eq(&slice[3], "b"));
}

/* --- adjacent to test_blank_lines_retained on purpose: a CRLF pair that
 * happens to mark an empty line is still ONE blank line, not two. This is
 * the case that is easy to break while fixing the one above - collapsing
 * CR+LF and retaining empty lines are two separate mechanisms
 * (skip_lf vs. the emit_line zero-length check) and must both be right
 * at once. --- */
static void test_crlf_empty_line_not_double_counted(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[8];
    size_t n;

    n68_console_init(&ring);
    feed_str(&ring, "x\r\n\r\ny\n");

    n = n68_console_visible_slice(&ring, 0, slice, 8);
    CHECK(n == 3); /* "x", "", "y" - not 4 */
    CHECK(line_eq(&slice[0], "x"));
    CHECK(line_eq(&slice[1], ""));
    CHECK(line_eq(&slice[2], "y"));
}

/* --- a line split across two separate feed() calls --- */
static void test_split_across_appends(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[4];
    size_t n;

    n68_console_init(&ring);
    feed_str(&ring, "hel");
    CHECK(n68_console_retained_count(&ring) == 0); /* no line yet */
    feed_str(&ring, "lo\n");
    CHECK(n68_console_retained_count(&ring) == 1);

    n = n68_console_visible_slice(&ring, 0, slice, 4);
    CHECK(n == 1);
    CHECK(line_eq(&slice[0], "hello"));
}

/* --- a CRLF pair split exactly at the feed() boundary must still count
 * as one line break, not two: skip_lf has to survive across calls --- */
static void test_crlf_split_across_appends(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[4];
    size_t n;

    n68_console_init(&ring);
    feed_str(&ring, "first\r");   /* CR lands as the last byte fed */
    feed_str(&ring, "\nsecond\n"); /* LF arrives in the next call */

    n = n68_console_visible_slice(&ring, 0, slice, 4);
    CHECK(n == 2); /* not 3: the lone LF must not become an empty line */
    CHECK(line_eq(&slice[0], "first"));
    CHECK(line_eq(&slice[1], "second"));
}

/* --- an over-long line is dropped and counted, not truncated --- */
static void test_overlong_line_dropped(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[4];
    char huge[N68_LINE_CAPACITY + 64];
    size_t n;
    unsigned long gen_before;

    memset(huge, 'x', sizeof(huge) - 1);
    huge[sizeof(huge) - 1] = '\n';

    n68_console_init(&ring);
    gen_before = n68_console_generation(&ring);
    n68_console_feed(&ring, huge, sizeof(huge));

    CHECK(n68_console_dropped_line_count(&ring) == 1);
    CHECK(n68_console_retained_count(&ring) == 0); /* nothing stored */
    CHECK(n68_console_generation(&ring) != gen_before); /* drop is visible */

    /* a normal line after the drop is captured intact, not corrupted by
     * whatever state the drop left behind */
    feed_str(&ring, "recovered\n");
    n = n68_console_visible_slice(&ring, 0, slice, 4);
    CHECK(n == 1);
    CHECK(line_eq(&slice[0], "recovered"));
    CHECK(n68_console_dropped_line_count(&ring) == 1); /* unchanged */
}

/* --- ring wraparound evicts the oldest line --- */
static void test_wraparound_eviction(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[N68_CONSOLE_RING_CAPACITY];
    char buf[16];
    size_t i, n;
    unsigned long extra = 5;

    n68_console_init(&ring);
    for (i = 0; i < N68_CONSOLE_RING_CAPACITY + extra; i++) {
        sprintf(buf, "line%lu\n", (unsigned long)i);
        feed_str(&ring, buf);
    }

    CHECK(n68_console_retained_count(&ring) == N68_CONSOLE_RING_CAPACITY);

    n = n68_console_visible_slice(&ring, 0, slice, N68_CONSOLE_RING_CAPACITY);
    CHECK(n == N68_CONSOLE_RING_CAPACITY);

    /* oldest retained line is "line5" (0..4 evicted by wraparound) */
    sprintf(buf, "line%lu", extra);
    CHECK(line_eq(&slice[0], buf));

    /* newest retained line is "line36" (5 + 32 - 1) */
    sprintf(buf, "line%lu", extra + N68_CONSOLE_RING_CAPACITY - 1);
    CHECK(line_eq(&slice[N68_CONSOLE_RING_CAPACITY - 1], buf));
}

/* --- visible-slice iterator at both ends --- */
static void test_visible_slice_edges(void)
{
    N68ConsoleRing ring;
    N68ConsoleLine slice[4];
    size_t n;
    size_t retained;

    n68_console_init(&ring);
    feed_str(&ring, "a\nb\nc\n");
    retained = n68_console_retained_count(&ring);
    CHECK(retained == 3);

    /* start of the window, capacity larger than content */
    n = n68_console_visible_slice(&ring, 0, slice, 4);
    CHECK(n == 3);
    CHECK(line_eq(&slice[0], "a"));

    /* offset at the last retained line: exactly one row back */
    n = n68_console_visible_slice(&ring, retained - 1, slice, 4);
    CHECK(n == 1);
    CHECK(line_eq(&slice[0], "c"));

    /* offset one past the newest line: nothing to draw */
    n = n68_console_visible_slice(&ring, retained, slice, 4);
    CHECK(n == 0);

    /* row_capacity smaller than the retained window clamps the count */
    n = n68_console_visible_slice(&ring, 0, slice, 2);
    CHECK(n == 2);
    CHECK(line_eq(&slice[0], "a"));
    CHECK(line_eq(&slice[1], "b"));
}

/* --- generation counter only moves on a visible-state change --- */
static void test_generation_tracks_dirty_state(void)
{
    N68ConsoleRing ring;
    unsigned long g0, g1, g2;

    n68_console_init(&ring);
    g0 = n68_console_generation(&ring);

    feed_str(&ring, "no line terminator yet");
    g1 = n68_console_generation(&ring);
    CHECK(g1 == g0); /* idle work must be free: no completed line, no bump */

    feed_str(&ring, "\n");
    g2 = n68_console_generation(&ring);
    CHECK(g2 != g1); /* line completed: exactly one visible change */
}

int main(void)
{
    test_line_endings();
    test_blank_lines_retained();
    test_crlf_empty_line_not_double_counted();
    test_split_across_appends();
    test_crlf_split_across_appends();
    test_overlong_line_dropped();
    test_wraparound_eviction();
    test_visible_slice_edges();
    test_generation_tracks_dirty_state();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
