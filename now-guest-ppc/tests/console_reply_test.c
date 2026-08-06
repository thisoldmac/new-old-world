/* Native test for the console's reply renderer. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src/console -I ../src/core \
          console_reply_test.c ../src/console/console_reply.c \
          ../src/core/json.c -o console_reply_test && ./console_reply_test

   THE DEFECT THIS EXISTS FOR. `console_model.c` used to read a top-level
   "message" out of a command.result and print "command failed" when it was
   absent. No PowerPC verb has ever carried one on success — every one of
   them answers `output: {<verb>: [[label, value], ...]}` — so the fallback
   printed a failure for every command that WORKED, and the command's own
   words only when it did not. `putstat` was reported that way on
   2026-08-05; the other seventeen verbs that reach the fallback were the
   same and nobody had typed them.

   The parity gate could not see it. It compares dispatch tables, and a
   table says whether a verb is PRESENT, never whether its answer renders.
   So the renderer became a file with no Toolbox in it, and this runs it
   over one reply of every shape the guest emits — which is the only check
   for this class that does not need a Macintosh in the room.

   Each case below is a shape, not an example: a row table, a refusal, an
   opaque object, an empty table, a truncated buffer, and text a person
   actually typed on a classic Mac (an accented file name, a quote). */

#include <stdio.h>
#include <string.h>

#include "console_reply.h"

static int g_failures;

/* --- a sink that remembers what it was told ----------------------------- */

enum { kMaxCaught = 32, kCaughtCap = 160 };

typedef struct {
    char line[kMaxCaught][kCaughtCap];
    int count;
} Caught;

static void catch_line(void *ctx, const char *text)
{
    Caught *c = (Caught *)ctx;

    if (c->count < kMaxCaught) {
        strncpy(c->line[c->count], text, kCaughtCap - 1);
        c->line[c->count][kCaughtCap - 1] = '\0';
        ++c->count;
    }
}

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* Every line this renderer produces is padded, so a caller asking "did it
   say X" wants a substring rather than an equality. */
static int said(const Caught *c, const char *needle)
{
    int i;

    for (i = 0; i < c->count; ++i) {
        if (strstr(c->line[i], needle) != NULL) {
            return 1;
        }
    }
    return 0;
}

static int render(const char *json, Caught *c)
{
    c->count = 0;
    return console_reply_render(json, catch_line, c);
}

/* --- the reported defect ------------------------------------------------ */

/* putstat's own reply, trimmed to the rows that matter. The whole point is
   that this is ok:true and carries no "message": the old fallback found
   nothing to print and said the command had failed. */
static const char kPutstat[] =
    "{\"type\":\"command.result\",\"id\":7,\"ok\":true,"
    "\"output\":{\"putstat\":["
    "[\"Bytes\",\"0\"],"
    "[\"Chunks\",\"0\"],"
    "[\"In FSWrite\",\"0 ms\"],"
    "[\"CRC-32\",\"00000000\"]"
    "]}}";

static void test_putstat_renders_its_rows(void)
{
    Caught c;
    int outcome = render(kPutstat, &c);

    check(outcome == kConsoleReplyRows, "putstat renders as rows");
    check(c.count == 4, "putstat emits one line per row");
    check(said(&c, "Bytes"), "putstat names its first row");
    check(said(&c, "CRC-32"), "putstat names its last row");
    check(!said(&c, "command failed"),
          "a command that SUCCEEDED never reads as a failure");
}

/* The zeroes are the answer, not an absence: a Mac that has received
   nothing this launch has run putstat successfully. */
static void test_zero_rows_are_still_an_answer(void)
{
    Caught c;

    check(render(kPutstat, &c) == kConsoleReplyRows,
          "all-zero counters are a completed answer");
}

/* --- the shapes around it ----------------------------------------------- */

static void test_a_refusal_is_the_guests_own_sentence(void)
{
    Caught c;
    int outcome = render(
        "{\"type\":\"command.result\",\"id\":1,\"ok\":false,"
        "\"error\":{\"code\":\"unknown-command\","
        "\"message\":\"frobnicate is not a command this Mac knows\"}}", &c);

    check(outcome == kConsoleReplyRefused, "ok:false is a refusal");
    check(c.count == 1, "a refusal is one line");
    check(said(&c, "not a command this Mac knows"),
          "the refusal carries the guest's words, not ours");
}

/* observe and its relatives answer with an object of references. There is
   nothing a console line can carry — but saying so is not the same as
   claiming the command failed, which is what used to happen. */
static void test_an_object_output_says_so_rather_than_lying(void)
{
    Caught c;
    int outcome = render(
        "{\"type\":\"command.result\",\"id\":2,\"ok\":true,"
        "\"output\":{\"observe\":{\"scope\":\"front\",\"processes\":[]}}}", &c);

    check(outcome == kConsoleReplyOpaque, "an object output is opaque");
    check(c.count == 1, "opaque is one line");
    check(!said(&c, "command failed"),
          "an opaque answer is not a failure");
}

static void test_an_empty_table_names_itself(void)
{
    Caught c;
    int outcome = render(
        "{\"type\":\"command.result\",\"id\":3,\"ok\":true,"
        "\"output\":{\"sw\":[]}}", &c);

    check(outcome == kConsoleReplyRows, "an empty table still ran");
    check(c.count == 1, "an empty table says one thing");
    check(said(&c, "sw"), "and names the verb whose table was empty");
}

/* The second half of the same defect. wire.c gave a reply 3072 bytes and
   console_model.c gave it 512, so any verb answering more than 512 bytes
   reached a person at the keyboard as a truncated buffer — unparseable,
   and reported as "command failed" while the host saw the whole table.
   The cap is one number now; this is what the renderer must do if a reply
   is ever cut off again. */
static void test_a_truncated_reply_is_refused_not_guessed(void)
{
    Caught c;
    int outcome = render(
        "{\"type\":\"command.result\",\"id\":4,\"ok\":true,"
        "\"output\":{\"ls\":[[\"Name\",\"System Fol", &c);

    check(outcome == kConsoleReplyRows,
          "a truncated table still renders what arrived whole");
    check(!said(&c, "System Fol"),
          "and does NOT emit the row the buffer cut in half");
}

static void test_a_reply_that_is_not_one_is_refused(void)
{
    Caught c;

    check(render("", &c) == kConsoleReplyMalformed, "empty is malformed");
    check(render("{\"type\":\"error\",\"code\":\"x\"}", &c)
          == kConsoleReplyMalformed, "another message type is malformed");
    check(c.count == 1, "malformed still says something");
}

/* MacRoman, because this is a classic Mac and the names on it have option
   keys in them. The guest escapes those to \uXXXX on the way out; a
   renderer that did not decode them would show a person the escape. */
static void test_macroman_comes_back_as_macroman(void)
{
    Caught c;

    render("{\"type\":\"command.result\",\"id\":5,\"ok\":true,"
           "\"output\":{\"ls\":[[\"Name\",\"Caf\\u00E9 \\\"notes\\\"\"]]}}", &c);
    check(said(&c, "\x8E"), "\\u00E9 renders as MacRoman e-acute (0x8E)");
    check(said(&c, "\"notes\""), "an escaped quote renders as a quote");
}

int main(void)
{
    test_putstat_renders_its_rows();
    test_zero_rows_are_still_an_answer();
    test_a_refusal_is_the_guests_own_sentence();
    test_an_object_output_says_so_rather_than_lying();
    test_an_empty_table_names_itself();
    test_a_truncated_reply_is_refused_not_guessed();
    test_a_reply_that_is_not_one_is_refused();
    test_macroman_comes_back_as_macroman();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
