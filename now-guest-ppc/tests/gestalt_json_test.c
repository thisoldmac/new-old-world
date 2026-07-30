/* Native test for the `gestalt` command's serializer. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src/commands gestalt_json_test.c \
          ../src/commands/gestalt_json.c -o gestalt_json_test \
          && ./gestalt_json_test

   The case this exists for cannot happen on the machine anyone tests on. A
   whole-machine gestalt today is about 26 rows and sits comfortably inside
   the 3072-byte result buffer wire.c hands it, so the version that wrote
   every `[`, `]`, `,` and quote with an unchecked `out[pos++]` looked fine
   forever. kGestaltMaxRows is 48 and a GestaltRow is 96 bytes, though, so a
   machine answering more selectors — or one more group — walks past the end
   of the caller's buffer rather than truncating.

   So the shape of every check here is: a maximal gather, a cap too small for
   it, and a poisoned guard region immediately after the cap that must come
   back untouched. */

#include <stdio.h>
#include <string.h>

#include "gestalt_json.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* --- the fixture: a gather as large as the type allows ------------------ */

static const char *const kGroups[] = {
    "snapshot", "cpu", "memory", "os", "network", "hw", NULL
};

/* Every field filled to its last byte, and the label carrying the two
   characters that make an escaped byte wider than its source — a row that
   is one byte short of fitting must not leave half an escape behind. */
static int build_max_rows(GestaltRow *rows)
{
    int i;

    for (i = 0; i < kGestaltMaxRows; ++i) {
        const char *group = kGroups[i % 6];

        memset(&rows[i], 0, sizeof rows[i]);
        strcpy(rows[i].group, group);
        memset(rows[i].label, 'L', sizeof rows[i].label - 1);
        rows[i].label[0] = '"';
        rows[i].label[1] = '\\';
        memset(rows[i].value, 'V', sizeof rows[i].value - 1);
        rows[i].value[0] = '\\';
    }
    return kGestaltMaxRows;
}

/* --- the harness: a bounded buffer with poison on both sides ------------ */

#define kSlab 8192
#define kPoison 0xA5

typedef struct {
    char slab[kSlab];
    long cap;
} Bounded;

static void bounded_init(Bounded *b, long cap)
{
    memset(b->slab, kPoison, sizeof b->slab);
    b->cap = cap;
}

/* The check the whole file is for. */
static int guard_intact(const Bounded *b)
{
    long i;

    for (i = b->cap; i < (long)sizeof b->slab; ++i) {
        if ((unsigned char)b->slab[i] != kPoison) {
            return 0;
        }
    }
    return 1;
}

static int terminated_within_cap(const Bounded *b)
{
    long i;

    for (i = 0; i < b->cap; ++i) {
        if (b->slab[i] == '\0') {
            return 1;
        }
    }
    return 0;
}

/* --- a structural reader, so "truncated" still means "parseable" -------- */

/* Not a JSON parser: it walks the reply counting depth and rejecting the
   two shapes a rewind gets wrong — an unbalanced bracket and a comma with
   nothing after it. An empty string is well-formed here (the below-floor
   case writes one deliberately); the callers that care assert content
   separately. */
static int structurally_sound(const char *s)
{
    int depth = 0;
    int in_string = 0;
    int last_was_comma = 0;
    int last_was_open = 0;
    int saw_any = 0;

    if (*s == '\0') {
        return 1;
    }
    for (; *s != '\0'; ++s) {
        if (in_string) {
            if (*s == '\\') {
                if (s[1] == '\0') {
                    return 0;       /* a dangling escape */
                }
                ++s;
            } else if (*s == '"') {
                in_string = 0;
            }
            continue;
        }
        switch (*s) {
        case '"':
            in_string = 1;
            last_was_comma = 0;
            last_was_open = 0;
            break;
        case '{':
        case '[':
            ++depth;
            saw_any = 1;
            last_was_comma = 0;
            last_was_open = 1;
            break;
        case '}':
        case ']':
            if (last_was_comma || --depth < 0) {
                return 0;
            }
            last_was_open = 0;
            break;
        case ',':
            if (last_was_comma || last_was_open) {
                return 0;
            }
            last_was_comma = 1;
            break;
        default:
            last_was_comma = 0;
            last_was_open = 0;
            break;
        }
    }
    return saw_any && depth == 0 && !in_string;
}

/* --- checks ------------------------------------------------------------- */

/* The generous case: everything fits, nothing is dropped, and no notice is
   invented. Without this the truncation checks below would pass just as well
   against a serializer that dropped every row. */
static void test_whole_gather_fits(void)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = build_max_rows(rows);
    Bounded b;
    int omitted;

    bounded_init(&b, 8000);
    omitted = now_gestalt_result_json(7, rows, count, kGroups,
                                      b.slab, b.cap);
    check(omitted == 0, "a maximal gather fits in 8000 bytes");
    check(guard_intact(&b), "whole gather: nothing written past the cap");
    check(structurally_sound(b.slab), "whole gather: well-formed");
    check(strstr(b.slab, "\"notice\"") == NULL,
          "no notice when nothing was dropped");
    check(strstr(b.slab, "\"type\":\"command.result\"") != NULL,
          "the envelope is a command.result");
    check(strstr(b.slab, "\"id\":7") != NULL, "the id is echoed");
    check(strstr(b.slab, "\\\"") != NULL, "the quote in a label is escaped");
}

/* The case that used to overrun: 48 rows of 96 bytes into the 3072 the wire
   actually passes. */
static void test_maximal_gather_into_the_wire_buffer(void)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = build_max_rows(rows);
    Bounded b;
    int omitted;

    bounded_init(&b, 3072);
    omitted = now_gestalt_result_json(1, rows, count, kGroups,
                                      b.slab, b.cap);
    check(guard_intact(&b), "3072: nothing written past the cap");
    check(terminated_within_cap(&b), "3072: terminated inside the cap");
    check((long)strlen(b.slab) < b.cap, "3072: the reply fits");
    check(structurally_sound(b.slab), "3072: well-formed after truncation");
    check(omitted > 0, "3072: a maximal gather does not fit and says so");
    check(strstr(b.slab, "\"notice\":[[\"truncated\"") != NULL,
          "3072: the truncation is on the wire, not just in the return");
}

/* Every cap from the floor to well past the whole reply. This is the check
   that catches an off-by-one at a boundary no hand-picked size lands on. */
static void test_every_cap_from_the_floor_up(void)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = build_max_rows(rows);
    long cap;
    int bad_guard = 0, bad_term = 0, bad_shape = 0, bad_notice = 0;
    int seen_partial = 0, seen_complete = 0;

    for (cap = kGestaltJsonMinCap; cap <= 6000; ++cap) {
        Bounded b;
        int omitted;

        bounded_init(&b, cap);
        omitted = now_gestalt_result_json(123456, rows, count, kGroups,
                                          b.slab, b.cap);
        if (!guard_intact(&b)) {
            if (!bad_guard) {
                fprintf(stderr, "  first overrun at cap %ld\n", cap);
            }
            ++bad_guard;
        }
        if (!terminated_within_cap(&b)) {
            ++bad_term;
        }
        if (!structurally_sound(b.slab)) {
            if (!bad_shape) {
                fprintf(stderr, "  first malformed at cap %ld: %s\n",
                        cap, b.slab);
            }
            ++bad_shape;
        }
        /* The notice and the return value must agree: a reply that dropped
           rows without saying so is exactly the silence this fixes. */
        if ((omitted > 0) != (strstr(b.slab, "\"notice\"") != NULL)) {
            if (!bad_notice) {
                fprintf(stderr, "  notice disagrees with the count at cap "
                                "%ld (omitted %d)\n", cap, omitted);
            }
            ++bad_notice;
        }
        if (omitted > 0) {
            ++seen_partial;
        } else {
            ++seen_complete;
        }
    }
    check(bad_guard == 0, "no cap in the sweep is written past");
    check(bad_term == 0, "every cap in the sweep is terminated in bounds");
    check(bad_shape == 0, "every cap in the sweep yields well-formed JSON");
    check(bad_notice == 0, "the notice tracks the dropped-row count");
    /* Both sides of the boundary were actually exercised — a sweep that
       only ever truncated would prove half of this. */
    check(seen_partial > 0 && seen_complete > 0,
          "the sweep crosses the point where the reply starts fitting");
}

/* A cap below the floor gets an empty string, not a half-written envelope a
   reader would try to parse. */
static void test_below_the_floor_writes_nothing(void)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = build_max_rows(rows);
    long cap;

    for (cap = 1; cap < kGestaltJsonMinCap; ++cap) {
        Bounded b;
        int omitted;

        bounded_init(&b, cap);
        omitted = now_gestalt_result_json(1, rows, count, kGroups,
                                          b.slab, b.cap);
        if (!guard_intact(&b) || b.slab[0] != '\0' || omitted != count) {
            fprintf(stderr, "FAIL: cap %ld below the floor was not refused "
                            "cleanly\n", cap);
            ++g_failures;
            return;
        }
    }
}

/* Rows whose group nobody asked for are not in the reply, and a slice of one
   group still closes its own array. */
static void test_group_selection(void)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = build_max_rows(rows);
    static const char *const one[] = { "cpu", NULL };
    Bounded b;
    int omitted;

    bounded_init(&b, 8000);
    omitted = now_gestalt_result_json(2, rows, count, one, b.slab, b.cap);
    check(omitted == 0, "one group fits");
    check(guard_intact(&b), "one group: nothing written past the cap");
    check(structurally_sound(b.slab), "one group: well-formed");
    check(strstr(b.slab, "\"cpu\":[") != NULL, "the asked-for group is there");
    check(strstr(b.slab, "\"hw\":[") == NULL, "no group nobody asked for");
}

/* An empty gather is a real answer: a machine that reported nothing, not a
   truncation. */
static void test_no_rows(void)
{
    Bounded b;
    GestaltRow none[1];
    int omitted;

    memset(none, 0, sizeof none);
    bounded_init(&b, 512);
    omitted = now_gestalt_result_json(3, none, 0, kGroups, b.slab, b.cap);
    check(omitted == 0, "an empty gather drops nothing");
    check(guard_intact(&b), "empty gather: nothing written past the cap");
    check(structurally_sound(b.slab), "empty gather: well-formed");
    check(strstr(b.slab, "\"output\":{}}") != NULL,
          "an empty gather is an empty output object");
}

int main(void)
{
    test_whole_gather_fits();
    test_maximal_gather_into_the_wire_buffer();
    test_every_cap_from_the_floor_up();
    test_below_the_floor_writes_nothing();
    test_group_selection();
    test_no_rows();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("gestalt_json_test ok\n");
    return 0;
}
