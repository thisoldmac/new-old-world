/*
 * Host test for n68_cmdresult - the two renderers of one command outcome.
 *
 * THE POINT OF THIS FILE is the pair of properties that make one command
 * table safe to serve two readers:
 *
 *   1. the JSON renderer still emits exactly the bytes commands68.c's
 *      finish_error / finish_ok_row1 / finish_ok_row2 emitted before they
 *      were moved here - the wire did not change when the console arrived;
 *   2. the text renderer never disagrees with the JSON renderer about what
 *      happened. A console that printed success for a reply the host reads
 *      as a failure would be worse than no console.
 *
 * The expected JSON strings below are written out in full rather than
 * assembled from the same pieces the renderer uses: a test that builds the
 * message it then parses tests one half twice (AGENTS.md).
 *
 * No Toolbox, no test framework - plain asserts with a running tally.
 */

#include <stdio.h>
#include <string.h>

#include "n68_cmdresult.h"

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

static void check_str(const char *got, const char *want, int line)
{
    g_checks++;
    if (strcmp(got, want) != 0) {
        g_failures++;
        printf("FAIL line %d:\n  got  [%s]\n  want [%s]\n", line, got, want);
    }
}

#define CHECK_STR(got, want) check_str((got), (want), __LINE__)

/* --- the wire bytes, verbatim, for each of the three shapes --- */

static void test_json_error(void)
{
    N68CmdResult r;
    char out[512];
    long n;

    n68_cmdresult_set_error(&r, "launch-refused",
                             "nothing named Foo is on this disk");
    n = n68_cmdresult_render_json(&r, 7, out, (long)sizeof out);

    CHECK_STR(out,
        "{\"type\":\"command.result\",\"id\":7,\"ok\":false,\"error\":"
        "{\"code\":\"launch-refused\","
        "\"message\":\"nothing named Foo is on this disk\"}}");
    /* The return value is the byte count, not strlen - wire68.c enqueues
     * (payload, n), so a wrong n truncates or overruns the frame. */
    CHECK(n == (long)strlen(out));
}

static void test_json_ok_one_row(void)
{
    N68CmdResult r;
    char out[512];
    long n;

    n68_cmdresult_set_ok1(&r, "launch", "Launch", "SimpleText launched");
    n = n68_cmdresult_render_json(&r, 12, out, (long)sizeof out);

    CHECK_STR(out,
        "{\"type\":\"command.result\",\"id\":12,\"ok\":true,\"output\":"
        "{\"launch\":[[\"Launch\",\"SimpleText launched\"]]}}");
    CHECK(n == (long)strlen(out));
}

static void test_json_ok_two_rows(void)
{
    N68CmdResult r;
    char out[512];
    long n;

    n68_cmdresult_set_ok2(&r, "quit", "Quit", "asked NetPresenz to quit",
                           "Outcome", "gone");
    n = n68_cmdresult_render_json(&r, 3, out, (long)sizeof out);

    CHECK_STR(out,
        "{\"type\":\"command.result\",\"id\":3,\"ok\":true,\"output\":"
        "{\"quit\":[[\"Quit\",\"asked NetPresenz to quit\"],"
        "[\"Outcome\",\"gone\"]]}}");
    CHECK(n == (long)strlen(out));
}

/* --- escaping is the renderer's, not the caller's --- */

static void test_json_escaping(void)
{
    N68CmdResult r;
    char out[512];

    /* A quote, a backslash, a control byte and a MacRoman high byte - the
     * four classes append_json_escaped treats differently. 0x8E is e-acute
     * in MacRoman, which is ordinary text in a Finder name, not corruption.
     */
    n68_cmdresult_set_error(&r, "quit-declined",
                             "no \"x\\y\" \tcaf\x8e");
    (void)n68_cmdresult_render_json(&r, 1, out, (long)sizeof out);

    CHECK_STR(out,
        "{\"type\":\"command.result\",\"id\":1,\"ok\":false,\"error\":"
        "{\"code\":\"quit-declined\","
        "\"message\":\"no \\\"x\\\\y\\\" \\u0009caf\\u00E9\"}}");
}

/* --- a reply that does not fit still says what happened --- */

static void test_json_overflow_keeps_the_truth(void)
{
    N68CmdResult r;
    /* 120: the compact fallback for this code is 110 bytes plus its NUL,
     * so it fits and the full message cannot. This is the exact case the
     * 180c hit on 2026-07-25 from the other direction - a 166-byte reply
     * dropped by a 160-byte slot - which is why the fallback exists at
     * all (commands68.h, NOW68K_COMMAND_RESULT_CAP). */
    char out[120];
    long n;

    n68_cmdresult_set_error(&r, "launch-refused",
                             "a message far too long to fit the buffer this "
                             "call is about to be given, by a wide margin");
    n = n68_cmdresult_render_json(&r, 42, out, (long)sizeof out);

    CHECK(n > 0);
    CHECK_STR(out,
        "{\"type\":\"command.result\",\"id\":42,\"ok\":false,\"error\":"
        "{\"code\":\"launch-refused\","
        "\"message\":\"(reply did not fit)\"}}");
    /* Shortening must never change the ok bit or the code: those are what
     * the host branches on. */
    CHECK(strstr(out, "\"ok\":false") != NULL);
    CHECK(strstr(out, "launch-refused") != NULL);
}

static void test_json_hopeless_cap_writes_nothing(void)
{
    N68CmdResult r;
    char out[8];
    long n;

    n68_cmdresult_set_error(&r, "launch-refused", "nope");
    n = n68_cmdresult_render_json(&r, 1, out, (long)sizeof out);

    /* Nothing-to-send, and NUL-terminated so a caller that ignores the
     * return value at least reads an empty string rather than garbage. */
    CHECK(n == 0);
    CHECK(out[0] == '\0');
}

/* --- the console text --- */

static void test_text_shapes(void)
{
    N68CmdResult r;
    char out[512];
    long n;

    n68_cmdresult_set_ok1(&r, "launch", "Launch", "SimpleText launched");
    n = n68_cmdresult_render_text(&r, out, (long)sizeof out);
    CHECK_STR(out, "Launch: SimpleText launched");
    CHECK(n == (long)strlen(out));

    n68_cmdresult_set_ok2(&r, "quit", "Quit", "asked NetPresenz to quit",
                           "Outcome", "gone");
    (void)n68_cmdresult_render_text(&r, out, (long)sizeof out);
    /* CR, not LF: the ring's splitter takes either, but this guest writes
     * CR everywhere else. */
    CHECK_STR(out, "Quit: asked NetPresenz to quit\rOutcome: gone");

    n68_cmdresult_set_error(&r, "launch-refused",
                             "nothing named Foo is on this disk");
    (void)n68_cmdresult_render_text(&r, out, (long)sizeof out);
    /* The marker leads: on a 1-bit panel there is no color, so failure has
     * to be legible from the first character. */
    CHECK_STR(out, "! launch-refused: nothing named Foo is on this disk");
}

/* --- a control byte in the detail must not forge a console line --- */

static void test_text_drops_control_bytes(void)
{
    N68CmdResult r;
    char out[512];

    n68_cmdresult_set_ok1(&r, "launch", "Launch", "one\rtwo\nthree\tfour");
    (void)n68_cmdresult_render_text(&r, out, (long)sizeof out);

    /* If these went through raw, the ring would split them and a one-line
     * result would become four, three of them unattributed. */
    CHECK_STR(out, "Launch: onetwothreefour");
}

/* --- MacRoman high bytes are text here, not a hazard --- */

static void test_text_keeps_high_bytes(void)
{
    N68CmdResult r;
    char out[512];

    n68_cmdresult_set_ok1(&r, "launch", "Launch", "caf\x8e");
    (void)n68_cmdresult_render_text(&r, out, (long)sizeof out);
    /* DrawText wants the raw MacRoman byte - escaping it the way the JSON
     * renderer does would print six literal characters on the screen. */
    CHECK_STR(out, "Launch: caf\x8e");
}

/* --- a text buffer too small truncates into a SHORT TRUE line --- */

static void test_text_truncates_without_lying(void)
{
    N68CmdResult r;
    char out[20];

    n68_cmdresult_set_error(&r, "launch-refused",
                             "nothing named Foo is on this disk");
    (void)n68_cmdresult_render_text(&r, out, (long)sizeof out);

    /* Marker and code first means even 19 usable bytes still name the
     * failure. If the message came first this would read as a mystery. */
    CHECK_STR(out, "! launch-refused: n");
}

/* --- THE INVARIANT: the two renderers never disagree about the outcome ---
 *
 * Not a formatting check. This walks the same result through both
 * renderers and asserts they agree on the ok bit and, when it is false, on
 * the code. That is the whole promise of serving one command table to two
 * readers, and it is the property that quietly breaks the day someone edits
 * one renderer alone. */
static void test_renderers_agree(void)
{
    static const struct {
        int ok;
        const char *code;
        const char *key;
        const char *label;
        const char *text;
        const char *label2;
        const char *state;
    } cases[] = {
        { 1, "", "launch", "Launch", "SimpleText launched", "", "" },
        { 1, "", "quit", "Quit", "asked it to quit", "Outcome", "gone" },
        { 1, "", "quit", "Quit", "not running", "Outcome", "not-running" },
        { 0, "launch-bad-args", "", "", "launch: what?", "", "" },
        { 0, "quit-declined", "", "", "still running after 6s", "", "" },
        { 0, "quit-undeliverable", "", "", "no reply", "", "" }
    };
    size_t i;

    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        N68CmdResult r;
        char json[512];
        char text[512];

        if (cases[i].ok) {
            if (cases[i].state[0] != '\0') {
                n68_cmdresult_set_ok2(&r, cases[i].key, cases[i].label,
                                       cases[i].text, cases[i].label2,
                                       cases[i].state);
            } else {
                n68_cmdresult_set_ok1(&r, cases[i].key, cases[i].label,
                                       cases[i].text);
            }
        } else {
            n68_cmdresult_set_error(&r, cases[i].code, cases[i].text);
        }

        (void)n68_cmdresult_render_json(&r, 1, json, (long)sizeof json);
        (void)n68_cmdresult_render_text(&r, text, (long)sizeof text);

        if (cases[i].ok) {
            CHECK(strstr(json, "\"ok\":true") != NULL);
            CHECK(strstr(json, "\"ok\":false") == NULL);
            /* Success never leads with the failure marker. */
            CHECK(text[0] != '!');
        } else {
            CHECK(strstr(json, "\"ok\":false") != NULL);
            CHECK(strstr(json, "\"ok\":true") == NULL);
            CHECK(text[0] == '!');
            /* And the same code appears in both renderings, so a human
             * reading the console and a host reading the wire can be talked
             * through the same failure. */
            CHECK(strstr(json, cases[i].code) != NULL);
            CHECK(strstr(text, cases[i].code) != NULL);
        }
        /* The detail sentence itself survives into both. */
        CHECK(strstr(text, cases[i].text) != NULL);
    }
}

int main(void)
{
    test_json_error();
    test_json_ok_one_row();
    test_json_ok_two_rows();
    test_json_escaping();
    test_json_overflow_keeps_the_truth();
    test_json_hopeless_cap_writes_nothing();
    test_text_shapes();
    test_text_drops_control_bytes();
    test_text_keeps_high_bytes();
    test_text_truncates_without_lying();
    test_renderers_agree();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
