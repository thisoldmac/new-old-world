/* Host-side test for the dev-only settings file parser.
 *
 *   cc -std=c99 -Wall -Wextra -Werror -pedantic \
 *      n68_devsettings.c connfields.c test_devsettings.c \
 *      -o test_devsettings && ./test_devsettings
 *
 * The parser is the whole testable half: n68_devsettings_file.c is File
 * Manager and Process Manager calls, which nothing here can exercise. Its
 * status is BUILDS, not tested, and no assertion below implies otherwise.
 *
 * What this pins, beyond "the keys work": the file is authored on a Mac in
 * TeachText and edited on macOS, so CR, LF and CRLF all reach the parser -
 * usually mixed, after one round trip through an editor that converts. A
 * parser that only split on '\n' would read a whole CR-terminated file as
 * one line and quietly apply nothing, which looks exactly like "the lab
 * dropped the file in the wrong folder". And the design rule - a settings
 * file must never make the application worse than having none - only means
 * something if a bad line beside a good one is proven not to sink it.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "n68_devsettings.h"

static int g_checks;

/* strlen at the call site rather than a length argument: every case below
 * is a C literal, and a hand-counted length is a bug waiting to happen. The
 * parser itself takes a length because a file is not NUL-terminated. */
static N68DevSettings parse(const char *text)
{
    N68DevSettings s;

    n68_devsettings_init(&s);
    n68_devsettings_parse(&s, text, (long)strlen(text));
    return s;
}

static void expect_host(const char *text, const char *host_text,
                        unsigned long addr)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_host || s.host_addr != addr
        || strcmp(s.host_text, host_text) != 0) {
        fprintf(stderr, "FAIL host from <<%s>>: have=%d addr=%lu text=\"%s\"\n",
                text, s.have_host, s.host_addr, s.host_text);
        assert(0);
    }
}

static void expect_no_host(const char *text)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (s.have_host) {
        fprintf(stderr, "FAIL expected no host from <<%s>>: got \"%s\"\n",
                text, s.host_text);
        assert(0);
    }
}

static void expect_port(const char *text, unsigned short port)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_port || s.port != port) {
        fprintf(stderr, "FAIL port from <<%s>>: have=%d port=%u (want %u)\n",
                text, s.have_port, s.port, port);
        assert(0);
    }
}

static void expect_no_port(const char *text)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (s.have_port) {
        fprintf(stderr, "FAIL expected no port from <<%s>>: got %u\n",
                text, s.port);
        assert(0);
    }
}

static void expect_retry(const char *text, int on)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_retry || s.retry_on != on) {
        fprintf(stderr, "FAIL retry from <<%s>>: have=%d on=%d (want %d)\n",
                text, s.have_retry, s.retry_on, on);
        assert(0);
    }
}

static void expect_retry_secs(const char *text, unsigned short secs)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_retry_secs || s.retry_secs != secs) {
        fprintf(stderr, "FAIL retry-interval from <<%s>>: have=%d secs=%u (want %u)\n",
                text, s.have_retry_secs, s.retry_secs, secs);
        assert(0);
    }
}

static void expect_no_retry_secs(const char *text)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (s.have_retry_secs) {
        fprintf(stderr, "FAIL expected no retry-interval from <<%s>>: got %u\n",
                text, s.retry_secs);
        assert(0);
    }
}

static void expect_launch_secs(const char *text, unsigned short secs)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_launch_search_secs || s.launch_search_secs != secs) {
        fprintf(stderr,
                "FAIL launch-search-seconds from <<%s>>: have=%d secs=%u"
                " (want %u)\n",
                text, s.have_launch_search_secs, s.launch_search_secs, secs);
        assert(0);
    }
}

/* The one that matters most for this key: not "the value is wrong" but "the
 * caller must be unable to tell the file said anything at all", because the
 * caller's response to have_* being clear is to leave the compiled-in 20 s
 * budget alone. A rejected value that still set have_* would hand proc68.c
 * a zero-second budget and break `launch` outright. */
static void expect_no_launch_secs(const char *text)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (s.have_launch_search_secs || s.launch_search_secs != 0) {
        fprintf(stderr,
                "FAIL expected no launch-search-seconds from <<%s>>:"
                " have=%d secs=%u\n",
                text, s.have_launch_search_secs, s.launch_search_secs);
        assert(0);
    }
}

static void expect_autoconnect(const char *text, int on)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (!s.have_autoconnect || s.autoconnect != on) {
        fprintf(stderr, "FAIL autoconnect from <<%s>>: have=%d on=%d (want %d)\n",
                text, s.have_autoconnect, s.autoconnect, on);
        assert(0);
    }
}

static void expect_counts(const char *text, unsigned short keys,
                          unsigned short bad, unsigned short first_bad)
{
    N68DevSettings s = parse(text);

    g_checks++;
    if (s.keys_set != keys || s.bad_lines != bad
        || s.first_bad_line != first_bad) {
        fprintf(stderr,
                "FAIL counts from <<%s>>: keys=%u bad=%u first=%u"
                " (want %u/%u/%u)\n",
                text, s.keys_set, s.bad_lines, s.first_bad_line,
                keys, bad, first_bad);
        assert(0);
    }
}

/* Nothing set at all - the state a caller must be left in by an absent,
 * empty or wholly unusable file, since that state is what "behaves exactly
 * as it did before this existed" means in code. */
static void expect_nothing_set(const char *label, const N68DevSettings *s)
{
    g_checks++;
    if (s->have_host || s->have_port || s->have_retry || s->have_retry_secs
        || s->have_autoconnect || s->have_launch_search_secs
        || s->keys_set != 0) {
        fprintf(stderr, "FAIL %s: something was set (host=%d port=%d retry=%d"
                " secs=%d auto=%d launch=%d keys=%u)\n",
                label, s->have_host, s->have_port, s->have_retry,
                s->have_retry_secs, s->have_autoconnect,
                s->have_launch_search_secs, s->keys_set);
        assert(0);
    }
}

int main(void)
{
    /* ---- every key, in the file the lab actually writes ---------------- */
    {
        static const char kFile[] =
            "# NOW-68K dev settings - lab only\n"
            "host = 10.91.5.47\n"
            "port = 5250\n"
            "retry = on\n"
            "retry-interval = 5\n"
            "autoconnect = off\n"
            "launch-search-seconds = 1\n";
        N68DevSettings s = parse(kFile);

        g_checks++;
        if (!s.have_host || s.host_addr != 0x0A5B052FUL
            || strcmp(s.host_text, "10.91.5.47") != 0
            || !s.have_port || s.port != 5250
            || !s.have_retry || !s.retry_on
            || !s.have_retry_secs || s.retry_secs != 5
            || !s.have_autoconnect || s.autoconnect
            || !s.have_launch_search_secs || s.launch_search_secs != 1
            || s.keys_set != 6 || s.bad_lines != 0) {
            fprintf(stderr, "FAIL whole-file parse\n");
            assert(0);
        }
    }

    /* ---- missing keys: absent means untouched, not defaulted ----------- */
    {
        N68DevSettings s = parse("host = 192.168.1.9\n");

        g_checks++;
        if (!s.have_host || s.have_port || s.have_retry || s.have_retry_secs
            || s.have_autoconnect || s.have_launch_search_secs
            || s.keys_set != 1) {
            fprintf(stderr, "FAIL host-only file set something else\n");
            assert(0);
        }
    }

    /* ---- line endings. This is the one that WILL bite: authored on a Mac
     * (CR), edited on macOS (LF), round-tripped through an editor (CRLF),
     * and a file that has been through both is mixed. All four must parse
     * identically, and CRLF must count as ONE line so first_bad_line still
     * matches the number the human sees in their editor. ---------------- */
    expect_host("host = 10.0.2.2\n", "10.0.2.2", 0x0A000202UL);
    expect_host("host = 10.0.2.2\r", "10.0.2.2", 0x0A000202UL);
    expect_host("host = 10.0.2.2\r\n", "10.0.2.2", 0x0A000202UL);
    expect_host("host = 10.0.2.2", "10.0.2.2", 0x0A000202UL);  /* no terminator */

    expect_counts("host = 10.0.2.2\rport = 5250\rretry = on\r", 3, 0, 0);
    expect_counts("host = 10.0.2.2\r\nport = 5250\r\nretry = on\r\n", 3, 0, 0);
    expect_counts("host = 10.0.2.2\nport = 5250\rretry = on\r\n", 3, 0, 0);

    /* CRLF counted as one terminator: the bad line here is line 2 to a
     * human, and must be line 2 in the report. A parser that counted CR and
     * LF separately would say 3 and send someone to the wrong line. */
    expect_counts("host = 10.0.2.2\r\nnonsense\r\nport = 5250\r\n", 2, 1, 2);

    /* ---- whitespace, separators, case, and the '-'/'_' equivalence ----- */
    expect_host("   host=10.0.2.2   \n", "10.0.2.2", 0x0A000202UL);
    expect_host("HOST : 10.0.2.2\n", "10.0.2.2", 0x0A000202UL);
    expect_host("Host 10.0.2.2\n", "10.0.2.2", 0x0A000202UL);
    expect_host("\thost\t=\t10.0.2.2\t\n", "10.0.2.2", 0x0A000202UL);
    expect_retry_secs("retry_interval = 30\n", 30);
    expect_retry_secs("RETRY-INTERVAL=30\n", 30);

    /* Blank lines and both comment markers are not lines at all - they are
     * never counted as bad, or every commented file would look broken. */
    expect_counts("\n\n   \n# a comment\n; another\n\t\n", 0, 0, 0);
    expect_counts("# host = 1.2.3.4\nhost = 10.0.2.2\n", 1, 0, 0);

    /* ---- booleans, all four accepted spellings ------------------------- */
    expect_retry("retry = on\n", 1);
    expect_retry("retry = yes\n", 1);
    expect_retry("retry = true\n", 1);
    expect_retry("retry = 1\n", 1);
    expect_retry("retry = OFF\n", 0);
    expect_retry("retry = no\n", 0);
    expect_retry("retry = false\n", 0);
    expect_retry("retry = 0\n", 0);
    expect_autoconnect("autoconnect = on\n", 1);
    expect_autoconnect("autoconnect = off\n", 0);

    /* ---- a repeated key: last one wins --------------------------------- */
    expect_host("host = 1.2.3.4\nhost = 10.0.2.2\n", "10.0.2.2", 0x0A000202UL);
    expect_retry("retry = on\nretry = off\n", 0);

    /* ---- malformed lines do not sink the good ones --------------------- */
    {
        static const char kFile[] =
            "host = 10.0.2.2\n"
            "prot = 5250\n"          /* typo'd key */
            "port = 5250\n"
            "retry = maybe\n"        /* not a boolean */
            "autoconnect = on\n";
        N68DevSettings s = parse(kFile);

        g_checks++;
        if (!s.have_host || !s.have_port || !s.have_autoconnect
            || s.have_retry || s.keys_set != 3 || s.bad_lines != 2
            || s.first_bad_line != 2) {
            fprintf(stderr, "FAIL mixed file: keys=%u bad=%u first=%u\n",
                    s.keys_set, s.bad_lines, s.first_bad_line);
            assert(0);
        }
    }

    /* Values that fail the SHARED validators - a settings file must not be
     * able to install a host or port the human could not have typed. */
    expect_no_host("host = 10.0.2\n");
    expect_no_host("host = 10.0.2.256\n");
    expect_no_host("host = studio-mac.local\n");        /* no DNS on MacTCP here */
    expect_no_host("host = 255.255.255.2555\n");        /* past kN68DevHostTextMax */
    expect_no_host("host =\n");                         /* key with no value */
    expect_no_host("host\n");                           /* key alone */

    /* ---- ports out of range -------------------------------------------- */
    expect_port("port = 1\n", 1);
    expect_port("port = 80\n", 80);                     /* not floored at 1024 */
    expect_port("port = 65535\n", 65535);
    expect_no_port("port = 0\n");
    expect_no_port("port = 65536\n");
    expect_no_port("port = 99999999\n");
    expect_no_port("port = -1\n");
    expect_no_port("port = 5250x\n");
    expect_no_port("port = 52 50\n");                   /* interior space */
    expect_no_port("port = 5250 # default\n");          /* no trailing comments */

    /* ---- retry interval bounds; the wire's own >= 1 s floor is not
     * duplicated here, so 0 is refused as a typo rather than clamped ----- */
    expect_retry_secs("retry-interval = 1\n", kN68DevRetryMinSecs);
    expect_retry_secs("retry-interval = 3600\n", kN68DevRetryMaxSecs);
    expect_no_retry_secs("retry-interval = 0\n");
    expect_no_retry_secs("retry-interval = 3601\n");
    expect_no_retry_secs("retry-interval = five\n");

    /* ---- the launch search budget --------------------------------------
     *
     * The key exists so the lab can force proc68.c's truncation report to
     * fire on a volume whose catalog would otherwise finish well inside the
     * shipped 20 s. Everything below therefore matters in one direction more
     * than the other: a value that is accepted when it should not be hands
     * proc68.c a budget that makes `launch` useless, and the file's own
     * design rule says it must never leave the application worse than having
     * no file at all. */
    expect_launch_secs("launch-search-seconds = 1\n", kN68DevLaunchSearchMinSecs);
    expect_launch_secs("launch-search-seconds = 2\n", 2);
    expect_launch_secs("launch-search-seconds = 20\n",
                       kN68DevLaunchSearchDefaultSecs);
    expect_launch_secs("launch-search-seconds = 600\n",
                       kN68DevLaunchSearchMaxSecs);

    /* Same key conventions as every other key, spelled the three ways a
     * human actually types one. */
    expect_launch_secs("launch_search_seconds = 3\n", 3);
    expect_launch_secs("LAUNCH-SEARCH-SECONDS: 3\n", 3);
    expect_launch_secs("  Launch_Search-Seconds   4  \n", 4);
    expect_launch_secs("launch-search-seconds = 5\n"
                       "launch-search-seconds = 6\n", 6);   /* last wins */

    /* Out of range. 0 is the one that would hurt: a zero-tick budget is a
     * `launch` that can never find anything, with no hint as to why, so it
     * is refused as a typo rather than clamped - exactly as retry-interval
     * refuses its own 0. */
    expect_no_launch_secs("launch-search-seconds = 0\n");
    expect_no_launch_secs("launch-search-seconds = 601\n");
    expect_no_launch_secs("launch-search-seconds = 999999999\n");
    expect_no_launch_secs("launch-search-seconds = -1\n");

    /* Malformed. "1200" IS in range and legal - it is 20 minutes, which the
     * bounds permit - so the ticks-vs-seconds confusion this key's name
     * exists to prevent cannot be caught by the parser; that is the name's
     * job, not the validator's, and nothing below pretends otherwise. */
    expect_no_launch_secs("launch-search-seconds = 20s\n");
    expect_no_launch_secs("launch-search-seconds = twenty\n");
    expect_no_launch_secs("launch-search-seconds =\n");
    expect_no_launch_secs("launch-search-seconds\n");
    expect_no_launch_secs("launch-search-seconds = 1 2\n");   /* interior space */
    expect_no_launch_secs("launch-search-seconds = 1 # short\n");
    expect_no_launch_secs("launch-search = 1200\n");          /* unknown key */
    expect_no_launch_secs("launch-search-ticks = 1200\n");    /* unknown key */

    /* Absent means the compiled-in 20 s, untouched - the property the whole
     * shipped fleet depends on, since no shipped machine has this file. A
     * settings file that sets other keys must still leave this one alone. */
    expect_no_launch_secs("host = 10.0.2.2\nport = 5250\nretry = on\n");

    /* A rejected value must not sink the good lines around it, and must
     * itself be counted so the human is told which line to look at. */
    {
        static const char kFile[] =
            "host = 10.0.2.2\n"
            "launch-search-seconds = 0\n"
            "port = 5250\n";
        N68DevSettings s = parse(kFile);

        g_checks++;
        if (!s.have_host || !s.have_port || s.have_launch_search_secs
            || s.keys_set != 2 || s.bad_lines != 1 || s.first_bad_line != 2) {
            fprintf(stderr, "FAIL launch-search bad line: keys=%u bad=%u"
                    " first=%u have=%d\n",
                    s.keys_set, s.bad_lines, s.first_bad_line,
                    s.have_launch_search_secs);
            assert(0);
        }
    }

    /* No separator whitespace at all, the way a key gets typed when the line
     * is being edited in a hurry. Worth its own case here because this key
     * is 21 characters against kKeyMax's 24 - a longer name would be
     * rejected as an over-long KEY rather than parsed, and the assertions
     * above are what fails if anyone renames it without moving that cap
     * (watched: renaming the key in the parser fails "whole-file parse"). */
    expect_launch_secs("launch-search-seconds=1\n", 1);

    /* ---- the empty file, and the byte-count contract ------------------- */
    {
        N68DevSettings s;

        n68_devsettings_init(&s);
        n68_devsettings_parse(&s, "", 0);
        expect_nothing_set("empty file", &s);

        n68_devsettings_init(&s);
        n68_devsettings_parse(&s, NULL, 0);
        expect_nothing_set("NULL buffer", &s);

        /* Length, not NUL, bounds the parse: a file read into a fixed
         * buffer is not terminated, and the bytes past `length` are
         * whatever the last read left there. */
        n68_devsettings_init(&s);
        n68_devsettings_parse(&s, "port = 5250\nhost = 9.9.9.9\n", 12);
        g_checks++;
        if (!s.have_port || s.have_host) {
            fprintf(stderr, "FAIL length bound ignored: port=%d host=%d\n",
                    s.have_port, s.have_host);
            assert(0);
        }
    }

    /* ---- a garbage file: sets nothing, blames nothing, starts anyway --- */
    {
        static const char kJunk[] =
            "\x01\x02\x03 binary junk \xFF\xFE\n"
            "=====\n"
            "::::\n"
            "\n"
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = 1\n"   /* over-long key */
            "host = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"; /* over-long value */
        N68DevSettings s = parse(kJunk);

        expect_nothing_set("garbage file", &s);
        g_checks++;
        if (s.bad_lines != 5 || s.first_bad_line != 1) {
            fprintf(stderr, "FAIL garbage counts: bad=%u first=%u\n",
                    s.bad_lines, s.first_bad_line);
            assert(0);
        }
    }

    printf("devsettings: %d checks passed\n", g_checks);
    return 0;
}
