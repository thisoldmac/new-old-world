/* Host-side test for NOW-68K's process.listing serializer
 * (src/n68_proclist.c).
 *
 * This is the half of process.list with no Toolbox in it, split off for
 * exactly that reason (n68_proclist.h). The Process Manager walk in
 * proc68.c cannot be reached from here and is not tested here - which is
 * worth saying plainly, because "the listing is tested" would be a
 * misleading summary of this file. What IS tested is everything that can
 * silently corrupt a page:
 *
 *   - the never-truncate-a-row rule. A page that stops mid-JSON decodes to
 *     nothing on the host: the cost of one row too many is the WHOLE page,
 *     so the interesting cases are the ones where a row ALMOST fits.
 *   - the paging arithmetic. cursor/more must compose so that following
 *     `cursor` until `more` is false visits every process exactly once -
 *     the test walks a whole list that way rather than asserting on one
 *     page's numbers, because off-by-one here is a lost or duplicated
 *     process and neither shows up in a single page.
 *   - the refusal to emit an empty page with more:true. That combination
 *     is an infinite paging loop on the host, and it is what a too-small
 *     buffer would otherwise produce.
 *   - the worst-case row bound. NOW68K_PROCLIST_ROW_MAX is what the static
 *     assert in wire68.c reasons against; a bound nobody re-measures stops
 *     being one, so this file BUILDS the worst case and measures it.
 *   - sanitizing. Process names are MacRoman and the host decodes UTF-8;
 *     one option-character in one application's name must not cost the
 *     page.
 *
 * The parser here is deliberately dumb - substring searches over the
 * emitted text, not a JSON reader. A test that parsed with the guest's own
 * scanner would be testing one half twice.
 */

#include "n68_proclist.h"

#include <stdio.h>
#include <string.h>

/* Any buffer comfortably above the minimum. The SHIPPING cap is
   NOW68K_CONTROL_SEND_CAP in wire68.h and this file deliberately does not
   restate it - that header pulls in net.h and MacTCP, and a second copy of
   a limit is the bug this whole area already paid for once. Nothing here
   depends on the shipping number: every property below holds for any cap
   at or above NOW68K_PROCLIST_MIN_CAP, which is why the paging walk is run
   at the minimum as well. */
enum { kAmpleCap = 2048 };

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
        g_checks++; \
        if (!(cond)) { \
            g_failures++; \
            printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        } \
    } while (0)

/* ---- helpers ----------------------------------------------------------- */

static void set_row(N68ProcRow *r, const char *name, unsigned char kind,
                    const char *code, const char *creator, long size_kb,
                    int front, unsigned long hi, unsigned long lo)
{
    memset(r, 0, sizeof *r);
    strncpy(r->name, name, sizeof r->name - 1);
    strncpy(r->code, code, sizeof r->code - 1);
    strncpy(r->creator, creator, sizeof r->creator - 1);
    r->kind = kind;
    r->front = (unsigned char)(front ? 1 : 0);
    r->size_kb = size_kb;
    r->psn_high = hi;
    r->psn_low = lo;
}

/* How many times `needle` occurs in `hay`. Counting rows by counting
   `{"name":"` is crude on purpose - see the file header. */
static int count_of(const char *hay, const char *needle)
{
    int n = 0;
    const char *p = hay;
    size_t len = strlen(needle);

    while ((p = strstr(p, needle)) != NULL) {
        ++n;
        p += len;
    }
    return n;
}

static int has(const char *hay, const char *needle)
{
    return strstr(hay, needle) != NULL;
}

/* The one structural property no page may ever violate. */
static void check_well_formed(const char *json, long len, const char *what)
{
    char msg[128];

    snprintf(msg, sizeof msg, "%s: length matches the NUL", what);
    CHECK((long)strlen(json) == len, msg);
    snprintf(msg, sizeof msg, "%s: opens as a process.listing", what);
    CHECK(strncmp(json, "{\"type\":\"process.listing\",\"id\":", 30) == 0, msg);
    snprintf(msg, sizeof msg, "%s: closes", what);
    CHECK(len > 0 && json[len - 1] == '}', msg);
    snprintf(msg, sizeof msg, "%s: carries the required more", what);
    CHECK(has(json, "\"more\":true") || has(json, "\"more\":false"), msg);
    snprintf(msg, sizeof msg, "%s: braces balance", what);
    CHECK(count_of(json, "{") == count_of(json, "}"), msg);
    snprintf(msg, sizeof msg, "%s: one row opener per row closer", what);
    CHECK(count_of(json, "{\"name\":\"") + 1 == count_of(json, "{"), msg);
}

/* ---- the shape of one page --------------------------------------------- */

static void test_single_page(void)
{
    N68ProcRow rows[3];
    char out[kAmpleCap];
    long next = -1;
    int more = -1;
    long n;

    set_row(&rows[0], "NOW-68K", kN68ProcKindApplication, "APPL", "NW68",
            384, 1, 0, 0x1234);
    set_row(&rows[1], "Finder", kN68ProcKindFinder, "FNDR", "MACS",
            250, 0, 0, 0x2);
    set_row(&rows[2], "Rumpus", kN68ProcKindBackground, "APPL", "RUMP",
            700, 0, 0, 0x9);

    n = n68_proclist_build(41, 1, rows, 3, out, (long)sizeof out,
                            &next, &more);
    CHECK(n > 0, "a three-row page builds");
    check_well_formed(out, n, "single page");
    CHECK(has(out, "\"id\":41"), "the request id is echoed");
    CHECK(count_of(out, "{\"name\":\"") == 3, "all three rows are present");
    CHECK(has(out, "\"more\":false"), "nothing remains after them");
    CHECK(next == 4, "the next cursor is one past the last row");
    CHECK(more == 0, "the more out-parameter agrees with the JSON");

    /* Field-by-field, on the row where every optional field is set. */
    CHECK(has(out, "{\"name\":\"NOW-68K\",\"kind\":\"application\","
                   "\"code\":\"APPL\",\"creator\":\"NW68\",\"sizeKB\":384,"
                   "\"front\":true,\"psnHigh\":0,\"psnLow\":4660}"),
          "the frontmost application row is exact");
    CHECK(has(out, "\"kind\":\"finder\""), "the Finder is classified");
    CHECK(has(out, "\"kind\":\"background\""), "a faceless process is "
                                               "classified");
    CHECK(count_of(out, "\"front\":true") == 1,
          "exactly one process is frontmost");
}

/* An empty machine is not an error - and neither is a cursor past the end,
   which is what a host racing a shrinking list will send. */
static void test_empty_and_past_the_end(void)
{
    N68ProcRow rows[1];
    char out[kAmpleCap];
    long next = -1;
    int more = -1;
    long n;

    set_row(&rows[0], "Finder", kN68ProcKindFinder, "FNDR", "MACS", 250, 1,
            0, 2);

    n = n68_proclist_build(7, 1, rows, 0, out, (long)sizeof out, &next, &more);
    CHECK(n > 0, "an empty list still builds a page");
    check_well_formed(out, n, "empty list");
    CHECK(has(out, "\"processes\":[]"), "the array is empty, not absent");
    CHECK(has(out, "\"more\":false"), "an empty list has no next page");
    CHECK(next == 1 && more == 0, "an empty list leaves the cursor alone");

    n = n68_proclist_build(7, 99, rows, 1, out, (long)sizeof out, &next,
                            &more);
    CHECK(n > 0, "a cursor past the end is a page, not a failure");
    CHECK(has(out, "\"processes\":[]") && has(out, "\"more\":false"),
          "past the end is an empty final page");
    CHECK(next == 99, "a cursor past the end does not advance");

    /* Cursor 0 and negative cursors mean "the beginning" - the host may
       omit cursor entirely and the caller renders that as 0. */
    n = n68_proclist_build(7, 0, rows, 1, out, (long)sizeof out, &next, &more);
    CHECK(n > 0 && count_of(out, "{\"name\":\"") == 1,
          "cursor 0 starts at the beginning");
    CHECK(next == 2, "cursor 0 is treated as cursor 1");
    n = n68_proclist_build(7, -5, rows, 1, out, (long)sizeof out, &next,
                            &more);
    CHECK(n > 0 && count_of(out, "{\"name\":\"") == 1,
          "a negative cursor starts at the beginning");
}

/* ---- paging ------------------------------------------------------------ */

/* Follow cursor until more is false and check every process was visited
   exactly once, in order. This is the property that matters; a single
   page's cursor value is only evidence for it. */
static void walk_pages(long cap, long row_count, const char *what)
{
    N68ProcRow rows[40];
    char out[kAmpleCap];
    char msg[160];
    long cursor = 1;
    long visited = 0;
    int more = 1;
    int pages = 0;
    long i;

    for (i = 0; i < row_count; ++i) {
        char name[32];

        /* Distinct, and long enough that several pages are needed. */
        snprintf(name, sizeof name, "Application %ld of many", i + 1);
        set_row(&rows[i], name, kN68ProcKindApplication, "APPL", "????",
                1000 + i, i == 0, 0, (unsigned long)(1000 + i));
    }

    while (more) {
        long next = -1;
        long n = n68_proclist_build(3, cursor, rows, row_count, out,
                                     cap, &next, &more);

        snprintf(msg, sizeof msg, "%s: page %d builds", what, pages + 1);
        CHECK(n > 0, msg);
        if (n <= 0) {
            return;
        }
        snprintf(msg, sizeof msg, "%s: page %d", what, pages + 1);
        check_well_formed(out, n, msg);

        snprintf(msg, sizeof msg, "%s: page %d fits the cap", what,
                 pages + 1);
        CHECK(n < cap, msg);

        {
            int on_page = count_of(out, "{\"name\":\"");

            snprintf(msg, sizeof msg,
                     "%s: page %d carries at least one row", what, pages + 1);
            CHECK(on_page > 0, msg);
            snprintf(msg, sizeof msg,
                     "%s: page %d respects the contract's maxItems", what,
                     pages + 1);
            CHECK(on_page <= NOW68K_PROCLIST_MAX_ROWS, msg);
            snprintf(msg, sizeof msg,
                     "%s: page %d's cursor counts its own rows", what,
                     pages + 1);
            CHECK(next == cursor + on_page, msg);

            /* Every row on this page is the one the walk expects next. */
            for (i = 0; i < on_page; ++i) {
                char needle[64];

                snprintf(needle, sizeof needle, "\"name\":\"Application %ld ",
                         visited + i + 1);
                snprintf(msg, sizeof msg, "%s: row %ld is in order", what,
                         visited + i + 1);
                CHECK(has(out, needle), msg);
            }
            visited += on_page;
        }
        cursor = next;
        ++pages;
        snprintf(msg, sizeof msg, "%s: the walk terminates", what);
        CHECK(pages < 100, msg);
        if (pages >= 100) {
            return;
        }
    }

    snprintf(msg, sizeof msg, "%s: every process was visited exactly once",
             what);
    CHECK(visited == row_count, msg);
    snprintf(msg, sizeof msg, "%s: it took more than one page", what);
    CHECK(pages > 1, msg);
}

static void test_paging(void)
{
    /* At the shipping cap, and at the smallest cap the guest is allowed to
       use - both must visit every process exactly once. */
    walk_pages(kAmpleCap, 30, "ample cap");
    walk_pages(NOW68K_PROCLIST_MIN_CAP, 9, "minimum cap");
}

/* The contract caps a page at 24 entries no matter how big the buffer is. */
static void test_max_items(void)
{
    N68ProcRow rows[40];
    char out[8192];
    long next = -1;
    int more = -1;
    long n;
    long i;

    for (i = 0; i < 40; ++i) {
        char name[32];

        snprintf(name, sizeof name, "P%ld", i + 1);
        set_row(&rows[i], name, kN68ProcKindApplication, "APPL", "????",
                8, 0, 0, (unsigned long)i);
    }
    n = n68_proclist_build(1, 1, rows, 40, out, (long)sizeof out, &next,
                            &more);
    CHECK(n > 0, "a large buffer still builds");
    CHECK(count_of(out, "{\"name\":\"") == NOW68K_PROCLIST_MAX_ROWS,
          "a page stops at the contract's maxItems even with room to spare");
    CHECK(more == 1 && has(out, "\"more\":true"),
          "the rest is reported as remaining");
    CHECK(next == 1 + NOW68K_PROCLIST_MAX_ROWS,
          "the cursor accounts for exactly the rows emitted");
}

/* ---- refusals ---------------------------------------------------------- */

/* A buffer too small for a row must REFUSE, not emit an empty page that
   says more:true - that combination makes the host ask again with the same
   cursor and get the same answer, forever. */
static void test_refuses_rather_than_looping(void)
{
    N68ProcRow rows[1];
    char out[NOW68K_PROCLIST_MIN_CAP];
    long next = -1;
    int more = -1;
    long cap;
    long n;

    /* The worst case the bounds are written for: a full-length name and
       maximal numbers everywhere. */
    set_row(&rows[0], "123456789012345678901234567890X",
            kN68ProcKindApplication, "APPL", "MACS", 2147483647L, 0,
            4294967295UL, 4294967295UL);

    for (cap = 0; cap < NOW68K_PROCLIST_MIN_CAP; ++cap) {
        n = n68_proclist_build(2147483647L, 1, rows, 1, out, cap, &next,
                                &more);
        if (n == 0) {
            CHECK(cap == 0 || out[0] == '\0',
                  "a refused build leaves nothing half-written");
            continue;
        }
        /* If it DID build at this cap, it must be a real page - never the
           empty-with-more:true loop. */
        CHECK(!(has(out, "\"processes\":[]") && has(out, "\"more\":true")),
              "a short buffer never emits an empty page that says more");
        CHECK(n < cap, "a page that built fits its buffer");
    }

    /* And at the declared minimum it must succeed, with the row in it -
       that is what the static assert in wire68.c reasons against. */
    n = n68_proclist_build(2147483647L, 1, rows, 1, out,
                            NOW68K_PROCLIST_MIN_CAP, &next, &more);
    CHECK(n > 0, "the worst-case row fits NOW68K_PROCLIST_MIN_CAP");
    CHECK(count_of(out, "{\"name\":\"") == 1,
          "and the page actually carries it");
    CHECK(has(out, "\"more\":false"), "with nothing left over");
}

/* The tail has to be RESERVED before a row is admitted, not discovered to
   be missing afterwards. Walking every cap in a wide band is how that gets
   proved: the failure only appears when a row fits and the "],"more"..."
   that must follow it does not, which is a window a few dozen bytes wide
   that no single hand-picked cap reliably lands in. Written after a
   mutation run - deleting the reservation from n68_proclist.c passed the
   rest of this file untouched. */
static void test_tail_is_reserved_at_every_cap(void)
{
    N68ProcRow rows[6];
    char out[1200];
    char msg[96];
    long cap;
    long i;

    for (i = 0; i < 6; ++i) {
        set_row(&rows[i], "123456789012345678901234567890X",
                kN68ProcKindApplication, "APPL", "MACS", 2147483647L, 0,
                4294967295UL, 4294967295UL);
    }

    for (cap = NOW68K_PROCLIST_MIN_CAP; cap < 1100; ++cap) {
        long next = -1;
        int more = -1;
        long n = n68_proclist_build(2147483647L, 1, rows, 6, out, cap,
                                     &next, &more);

        snprintf(msg, sizeof msg, "cap %ld: a page builds", cap);
        CHECK(n > 0, msg);
        if (n <= 0) {
            continue;
        }
        snprintf(msg, sizeof msg, "cap %ld: the page fits", cap);
        CHECK(n < cap, msg);
        snprintf(msg, sizeof msg, "cap %ld", cap);
        check_well_formed(out, n, msg);
        snprintf(msg, sizeof msg, "cap %ld: carries at least one row", cap);
        CHECK(count_of(out, "{\"name\":\"") > 0, msg);
        snprintf(msg, sizeof msg, "cap %ld: cursor counts its rows", cap);
        CHECK(next == 1 + count_of(out, "{\"name\":\""), msg);
    }
}

/* The bound the static assert reasons against, measured rather than
   assumed. If a field is ever added to a row this fails before the
   PowerBook does. */
static void test_worst_case_row_bound(void)
{
    N68ProcRow rows[2];
    char big[8192];
    char one[8192];
    long n_one;
    long n_two;

    set_row(&rows[0], "123456789012345678901234567890X",
            kN68ProcKindApplication, "APPL", "MACS", 2147483647L, 0,
            4294967295UL, 4294967295UL);
    rows[1] = rows[0];

    n_one = n68_proclist_build(2147483647L, 1, rows, 1, one,
                                (long)sizeof one, NULL, NULL);
    n_two = n68_proclist_build(2147483647L, 1, rows, 2, big,
                                (long)sizeof big, NULL, NULL);
    CHECK(n_one > 0 && n_two > 0, "the worst case builds");

    /* The second row's cost, with its leading comma, IS the row bound. */
    CHECK(n_two - n_one <= NOW68K_PROCLIST_ROW_MAX,
          "the worst-case row is within NOW68K_PROCLIST_ROW_MAX");
    /* And the bound is still tight enough to be meaningful: if it drifts
       far above the real worst case it stops constraining anything. */
    CHECK(n_two - n_one > NOW68K_PROCLIST_ROW_MAX - 32,
          "NOW68K_PROCLIST_ROW_MAX is still a tight bound, not a guess");

    /* The head and tail bounds, the same way. */
    CHECK(n_one - (n_two - n_one)
              <= NOW68K_PROCLIST_HEAD_MAX + NOW68K_PROCLIST_TAIL_MAX,
          "the envelope is within its head+tail bounds");
    printf("  worst-case row = %ld bytes (bound %d), envelope = %ld bytes "
           "(bound %d)\n",
           n_two - n_one, NOW68K_PROCLIST_ROW_MAX,
           n_one - (n_two - n_one),
           NOW68K_PROCLIST_HEAD_MAX + NOW68K_PROCLIST_TAIL_MAX);
}

/* ---- sanitizing -------------------------------------------------------- */

/* One MacRoman option-character in one application's name must not make
   the whole page undecodable on a host that parses UTF-8, and a quote in a
   name must not reopen our string literal. */
static void test_sanitizing(void)
{
    N68ProcRow rows[1];
    char out[kAmpleCap];
    long n;
    long i;

    memset(&rows[0], 0, sizeof rows[0]);
    /* A quote, a backslash, a control byte and a high-bit byte - the four
       classes that break a hand-written JSON string. */
    rows[0].name[0] = 'A';
    rows[0].name[1] = '"';
    rows[0].name[2] = '\\';
    rows[0].name[3] = '\n';
    rows[0].name[4] = (char)0xC9;    /* MacRoman ellipsis */
    rows[0].name[5] = 'Z';
    rows[0].name[6] = '\0';
    memcpy(rows[0].code, "AP\"L", 5);
    rows[0].code[4] = '\0';
    memcpy(rows[0].creator, "\\\\\\\\", 4);
    rows[0].creator[4] = '\0';
    rows[0].kind = kN68ProcKindApplication;

    n = n68_proclist_build(1, 1, rows, 1, out, (long)sizeof out, NULL, NULL);
    CHECK(n > 0, "a hostile name still builds");
    check_well_formed(out, n, "sanitized page");
    CHECK(has(out, "\"name\":\"A???" "?Z\""),
          "every dangerous byte in the name became '?'");
    CHECK(has(out, "\"code\":\"AP?L\""), "a 4CC is sanitized too");
    CHECK(has(out, "\"creator\":\"????\""), "so is the creator");
    for (i = 0; i < n; ++i) {
        CHECK((unsigned char)out[i] >= 0x20 && (unsigned char)out[i] < 0x80,
              "the whole page is printable ASCII");
        if ((unsigned char)out[i] < 0x20 || (unsigned char)out[i] >= 0x80) {
            break;   /* one report, not one per byte */
        }
    }
    /* The count of quotes must be even and every one of them a delimiter -
       an unescaped quote in a value would make it odd. */
    CHECK(count_of(out, "\"") % 2 == 0, "quotes still pair up");
}

/* ---- the same rows as `ps` --------------------------------------------- */

/* The command a person types, on either console. It carries no cursor, so
   the properties that matter are different from the listing's: it must
   never claim a short list is the whole machine, and it must render the
   detail column the way the PowerPC guest does, because the host console
   renders both guests with one renderer. */
static void test_ps_shape(void)
{
    N68ProcRow rows[3];
    char out[kAmpleCap];
    long n;

    set_row(&rows[0], "NOW-68K", kN68ProcKindApplication, "APPL", "NW68",
            384, 1, 0, 0x1234);
    set_row(&rows[1], "Finder", kN68ProcKindFinder, "FNDR", "MACS",
            250, 0, 0, 0x2);
    set_row(&rows[2], "Backgrounder", kN68ProcKindBackground, "APPL", "BKGD",
            64, 0, 0, 0x9);

    n = n68_proclist_render_ps(7, rows, 3, out, (long)sizeof out);
    CHECK(n > 0, "ps builds");
    CHECK((long)strlen(out) == n, "ps: length matches the NUL");
    CHECK(strncmp(out, "{\"type\":\"command.result\",\"id\":7,\"ok\":true,"
                       "\"output\":{\"ps\":[", 57) == 0,
          "ps opens as an ok command.result with an output.ps group");
    CHECK(out[n - 1] == '}', "ps closes");
    CHECK(count_of(out, "{") == count_of(out, "}"), "ps braces balance");
    CHECK(count_of(out, "[") == count_of(out, "]"), "ps brackets balance");
    CHECK(count_of(out, " KB") == 3, "one [name, detail] pair per row");

    /* The detail column, verbatim - the sentence guest/src/commands.c
       builds for the same three facts. A drift here shows up as two
       machines that describe themselves differently in one console. */
    CHECK(has(out, "[\"NOW-68K\",\"application, 384 KB, front\"]"),
          "ps renders kind, size and frontmost like the PowerPC guest");
    CHECK(has(out, "[\"Finder\",\"finder, 250 KB\"]"),
          "ps omits the front marker for everything else");
    CHECK(has(out, "[\"Backgrounder\",\"background, 64 KB\"]"),
          "ps names a faceless process by its kind");
    CHECK(!has(out, "more not shown"),
          "a list that fits says nothing about truncation");
}

static void test_ps_empty(void)
{
    char out[kAmpleCap];
    long n = n68_proclist_render_ps(1, NULL, 0, out, (long)sizeof out);

    CHECK(n > 0, "an empty ps still builds");
    CHECK(has(out, "\"ok\":true"), "no processes is not an error");
    CHECK(has(out, "\"ps\":[]"), "an empty group, not a missing one");
    CHECK(!has(out, "more not shown"), "nothing was dropped");
}

/* THE property this renderer exists to keep. `ps` does not paginate, so a
   machine running more processes than one control frame can carry MUST say
   so - a silently short list reads as the whole machine, and someone would
   go looking for an application that was running the whole time. */
static void test_ps_states_its_truncation(void)
{
    N68ProcRow rows[NOW68K_PROCLIST_MAX_ROWS];
    char out[kAmpleCap];
    long i;
    long n;

    for (i = 0; i < NOW68K_PROCLIST_MAX_ROWS; ++i) {
        set_row(&rows[i], "A Process With A Long Enough Name",
                kN68ProcKindApplication, "APPL", "TEST", 1024, 0, 0,
                (unsigned long)i);
    }

    /* Deliberately at the floor this renderer promises its callers, which
       is the smallest cap the shipping build could ever hand it. */
    n = n68_proclist_render_ps(1, rows, NOW68K_PROCLIST_MAX_ROWS, out,
                               NOW68K_PS_MIN_CAP);
    CHECK(n > 0, "a full list still builds at the minimum cap");
    CHECK(n < NOW68K_PS_MIN_CAP, "and stays inside it");
    CHECK((long)strlen(out) == n, "truncated ps: length matches the NUL");
    CHECK(out[n - 1] == '}', "truncated ps closes");
    CHECK(count_of(out, "[") == count_of(out, "]"),
          "truncated ps brackets balance");
    CHECK(has(out, "more not shown"), "truncation is STATED, never silent");
    CHECK(has(out, "[\"...\",\""), "and stated as a row the host renders");
    CHECK(count_of(out, " KB") >= 1,
          "at least one real process survives beside the note");

    /* The count in the note must be the rows dropped, not the rows kept:
       an off-by-one here is a process nobody goes looking for. Real rows
       are counted by their size column, which the note row does not have -
       counting `","` would also catch the envelope's own punctuation. */
    {
        int rendered = count_of(out, " KB");
        char expect[32];

        snprintf(expect, sizeof expect, "\"%d more not shown\"",
                 (int)NOW68K_PROCLIST_MAX_ROWS - rendered);
        CHECK(has(out, expect), "the note counts what was DROPPED");
    }
}

/* A cap too small for even the envelope is a refusal, not a half-written
   object: the host decodes a truncated frame as nothing at all. */
static void test_ps_refuses_a_hopeless_cap(void)
{
    N68ProcRow rows[1];
    char out[kAmpleCap];
    long n;

    set_row(&rows[0], "NOW-68K", kN68ProcKindApplication, "APPL", "NW68",
            384, 1, 0, 1);
    n = n68_proclist_render_ps(1, rows, 1, out, 20);
    CHECK(n == 0, "a cap below the envelope refuses");
    CHECK(out[0] == '\0', "and leaves nothing to send");
}

/* NOW68K_PS_ROW_MAX is what the static assert in commands68.c reasons
   against. A bound nobody re-measures stops being one, so build the true
   worst case: the longest name, the longest kind, a ten-digit size and
   the front marker. */
static void test_ps_worst_case_row_bound(void)
{
    N68ProcRow rows[1];
    char out[kAmpleCap];
    long n;
    long head_and_tail;

    memset(&rows[0], 0, sizeof rows[0]);
    memset(rows[0].name, 'W', sizeof rows[0].name - 1);
    rows[0].name[sizeof rows[0].name - 1] = '\0';
    rows[0].kind = kN68ProcKindApplication;   /* the longest kind text */
    rows[0].front = 1;
    rows[0].size_kb = 2147483647L;            /* ten digits */

    n = n68_proclist_render_ps(2147483647L, rows, 1, out, (long)sizeof out);
    CHECK(n > 0, "the worst-case ps row builds");

    /* The head is everything before the first row; the tail is "]}}". */
    head_and_tail = (long)(strstr(out, "[\"") - out) + 3;
    CHECK((long)(strstr(out, "[\"") - out) <= NOW68K_PS_HEAD_MAX,
          "NOW68K_PS_HEAD_MAX still bounds the envelope");
    CHECK(n - head_and_tail <= NOW68K_PS_ROW_MAX,
          "NOW68K_PS_ROW_MAX still bounds the widest row");
}

int main(void)
{
    test_single_page();
    test_empty_and_past_the_end();
    test_paging();
    test_max_items();
    test_refuses_rather_than_looping();
    test_tail_is_reserved_at_every_cap();
    test_worst_case_row_bound();
    test_sanitizing();
    test_ps_shape();
    test_ps_empty();
    test_ps_states_its_truncation();
    test_ps_refuses_a_hopeless_cap();
    test_ps_worst_case_row_bound();

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
