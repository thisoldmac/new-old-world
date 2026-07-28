/*
 * Host test for console_history - the Up/Down arrow history BOTH guests'
 * consoles use. No Toolbox, no test framework: plain asserts with a running
 * tally so one run reports everything rather than stopping at the first
 * failure.
 *
 *     cc -Wall -Wextra -Werror -I ../src -I ../../now-guest-ppc/src/console \
 *        console_history_test.c ../src/console_history.c -o t && ./t
 *
 * Grew out of now-guest-68k/tests/test_history.c, which tested the same
 * behaviour against a file only NOW-68K compiled. What is worth testing
 * here is precisely what is NOT obvious: that NULL means "leave the field
 * alone" and never "clear it", that the half-typed line survives a walk,
 * and that the walk does not capture a recalled entry as the half-typed
 * line on its second step. Each of those was watched to fail by mutation
 * before being committed - and each of them is a property the PowerPC
 * guest's own history did NOT have before this file became the one
 * implementation.
 *
 * It includes the PowerPC guest's console_model.h for one assertion only:
 * that the shared line cap is at least as wide as that guest's input
 * field. A width rule stated in a comment on one side of a shared file is
 * how the same file ends up too narrow for the other side.
 */

#include <stdio.h>
#include <string.h>

#include "console_history.h"
#include "console_model.h"   /* kConsoleMaxCols - the PowerPC input width */

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

static int streq(const char *a, const char *b)
{
    return a != NULL && b != NULL && strcmp(a, b) == 0;
}

/* --- an empty history has nothing to recall, in either direction --- */
static void test_empty(void)
{
    ConsoleHistory h;

    console_history_init(&h);
    CHECK(console_history_count(&h) == 0);
    /* NULL, not "" - the field must be left exactly as the human left it. */
    CHECK(console_history_prev(&h, "half typed") == NULL);
    CHECK(console_history_next(&h) == NULL);
}

/* --- Up walks oldest-ward and stops, without clearing the field --- */
static void test_walk_back_stops(void)
{
    ConsoleHistory h;

    console_history_init(&h);
    console_history_push(&h, "launch SimpleText");
    console_history_push(&h, "quit NetPresenz");
    CHECK(console_history_count(&h) == 2);

    CHECK(streq(console_history_prev(&h, ""), "quit NetPresenz"));
    CHECK(streq(console_history_prev(&h, ""), "launch SimpleText"));
    /* Past the oldest: NULL, so the caller leaves "launch SimpleText" in
     * the field. Returning "" here would silently erase it - which is what
     * the PowerPC guest's own history did until this file replaced it. */
    CHECK(console_history_prev(&h, "") == NULL);
}

/* --- the half-typed line survives a walk and comes back on the way down --- */
static void test_pending_line_restored(void)
{
    ConsoleHistory h;
    const char *r;

    console_history_init(&h);
    console_history_push(&h, "launch SimpleText");
    console_history_push(&h, "quit NetPresenz");

    r = console_history_prev(&h, "lau");     /* saves "lau" as pending */
    CHECK(streq(r, "quit NetPresenz"));
    r = console_history_prev(&h, "quit NetPresenz");
    CHECK(streq(r, "launch SimpleText"));

    /* Down once: back to the newest entry, NOT to the pending line. */
    r = console_history_next(&h);
    CHECK(streq(r, "quit NetPresenz"));

    /* Down again: the fresh-line position, restoring what was typed. This
     * is the assertion that fails if console_history_prev re-saves
     * `current` on every step instead of only the first - the second step
     * would then have overwritten "lau" with "quit NetPresenz". */
    r = console_history_next(&h);
    CHECK(streq(r, "lau"));

    /* And no further: already at the fresh line. */
    CHECK(console_history_next(&h) == NULL);
}

/* --- an empty pending line is a restore, not a no-op --- */
static void test_pending_empty_is_a_restore(void)
{
    ConsoleHistory h;

    console_history_init(&h);
    console_history_push(&h, "help");

    CHECK(streq(console_history_prev(&h, ""), "help"));
    /* Walking back down must return "" so the field is cleared - the human
     * started from an empty field and is entitled to get it back. NULL
     * would leave "help" sitting there. */
    CHECK(streq(console_history_next(&h), ""));
}

/* --- Return rewinds the cursor, so the next Up starts from the newest --- */
static void test_push_rewinds_cursor(void)
{
    ConsoleHistory h;

    console_history_init(&h);
    console_history_push(&h, "one");
    console_history_push(&h, "two");

    CHECK(streq(console_history_prev(&h, ""), "two"));
    CHECK(streq(console_history_prev(&h, ""), "one"));

    console_history_push(&h, "three");
    /* Not "one" again: the walk is over. */
    CHECK(streq(console_history_prev(&h, ""), "three"));
}

/* --- empties and immediate repeats are not stored, but still rewind --- */
static void test_push_filters(void)
{
    ConsoleHistory h;

    console_history_init(&h);
    console_history_push(&h, "launch Foo");
    console_history_push(&h, "launch Foo");
    console_history_push(&h, "");
    console_history_push(&h, NULL);
    CHECK(console_history_count(&h) == 1);

    /* A repeat that is not immediate IS stored - "a, b, a" is three
     * distinct things to walk back through. */
    console_history_push(&h, "quit Bar");
    console_history_push(&h, "launch Foo");
    CHECK(console_history_count(&h) == 3);
    CHECK(streq(console_history_prev(&h, ""), "launch Foo"));
    CHECK(streq(console_history_prev(&h, ""), "quit Bar"));
    CHECK(streq(console_history_prev(&h, ""), "launch Foo"));
    CHECK(console_history_prev(&h, "") == NULL);

    /* An ignored push still ends the walk. */
    console_history_push(&h, "");
    CHECK(streq(console_history_prev(&h, ""), "launch Foo"));
}

/* --- the ring evicts the oldest and the walk stops at what is left --- */
static void test_eviction(void)
{
    ConsoleHistory h;
    char buf[16];
    int i;

    console_history_init(&h);
    for (i = 0; i < kConsoleHistoryCapacity + 3; i++) {
        sprintf(buf, "cmd%d", i);
        console_history_push(&h, buf);
    }
    CHECK(console_history_count(&h) == kConsoleHistoryCapacity);

    /* Newest first. */
    sprintf(buf, "cmd%d", kConsoleHistoryCapacity + 2);
    CHECK(streq(console_history_prev(&h, ""), buf));

    /* Walk to the oldest RETAINED entry, which is cmd3 (0..2 evicted). */
    for (i = 1; i < kConsoleHistoryCapacity; i++) {
        CHECK(console_history_prev(&h, "") != NULL);
    }
    CHECK(console_history_prev(&h, "") == NULL);
}

/* --- a full-length line survives storage and recall unshortened ---
 *
 * This is the assertion that fails the moment kConsoleHistoryLineCap drops
 * below either console's input capacity. A silently shortened HFS path
 * handed back by an Up arrow would launch, or fail to find, something the
 * human never asked for - the same defect commands68.c's trim_and_unquote
 * refuses to commit at the other end of the string. */
static void test_long_line_is_not_shortened(void)
{
    ConsoleHistory h;
    char longline[kConsoleHistoryLineCap];
    const char *r;
    int i;

    console_history_init(&h);
    for (i = 0; i < kConsoleHistoryLineCap - 1; i++) {
        longline[i] = (char)('a' + (i % 26));
    }
    longline[kConsoleHistoryLineCap - 1] = '\0';

    console_history_push(&h, longline);
    r = console_history_prev(&h, "");
    CHECK(r != NULL && strlen(r) == (size_t)(kConsoleHistoryLineCap - 1));
    CHECK(streq(r, longline));

    /* And the cap is at least as wide as the longest `launch` target
     * NOW-68K's commands68.c will accept (kNameMax 200, minus its NUL),
     * plus the "launch " that precedes it. Stated as a test rather than a
     * comment because a comment cannot fail. */
    CHECK(kConsoleHistoryLineCap >= 199 + 7 + 1);

    /* Same rule for the other guest, read from its own header rather than
     * copied as a number: the PowerPC console page's input field is
     * kConsoleMaxCols wide, and a history narrower than that would hand
     * back a truncated line as if it were what was typed. */
    CHECK(kConsoleHistoryLineCap >= kConsoleMaxCols);
}

int main(void)
{
    test_empty();
    test_walk_back_stops();
    test_pending_line_restored();
    test_pending_empty_is_a_restore();
    test_push_rewinds_cursor();
    test_push_filters();
    test_eviction();
    test_long_line_is_not_shortened();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
