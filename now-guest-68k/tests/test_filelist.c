/* Host-side test for NOW-68K's file.listing serializer and the `ls` table
 * (src/n68_filelist.c), and for the rows-shaped command result they render
 * through (src/n68_cmdresult.c).
 *
 * This is the half of file.list with no Toolbox in it, split off for
 * exactly that reason (n68_filelist.h). The catalog walk in n68_fileenum.c
 * cannot be reached from here and is NOT tested here - worth saying plainly,
 * because "browsing is tested" would be a misleading summary of this file.
 * Nothing below proves that a real folder on a real disk reads back
 * correctly; that is what the emulator run is for.
 *
 * What IS tested is everything that can silently corrupt a page or a reply:
 *
 *   - the never-truncate-a-row rule, in both renderers. A frame that stops
 *     mid-JSON decodes to nothing on the host, so the cost of one entry too
 *     many is the WHOLE page. The interesting cases are the ones where an
 *     entry ALMOST fits.
 *   - the paging arithmetic. Following `cursor` until `more` is false must
 *     visit every entry exactly once; the test walks a folder that way
 *     rather than asserting on one page's numbers, because off-by-one here
 *     is a lost or duplicated FILE and neither shows up in a single page.
 *   - the refusal to emit an empty page with more:true, which is an
 *     infinite paging loop on the host rather than a small listing.
 *   - the worst-case bounds. NOW68K_FILELIST_ROW_MAX and its head/tail
 *     siblings are what the static assert in wire68.c reasons against, and
 *     a bound nobody re-measures stops being one - so this file BUILDS the
 *     worst case and measures it.
 *   - `root` being dropped WHOLE when it does not fit. Half a caption
 *     truncates the frame mid-string and costs the entire listing.
 *   - truncation being STATED by the `ls` table, twice over and for two
 *     different reasons: entries the enumerator saw beyond the page, and
 *     rows the command.result buffer could not carry.
 *   - MacRoman escaping. HFS names carry high bytes and the host decodes
 *     UTF-8; one option-character in one file's name must not cost the page.
 *
 * The parser here is deliberately dumb - substring searches over the
 * emitted text, not a JSON reader. A test that parsed with the guest's own
 * scanner would be testing one half twice (AGENTS.md).
 */

#include "n68_filelist.h"

#include <stdio.h>
#include <string.h>

/* Comfortably above the minimum. The SHIPPING cap is
   NOW68K_CONTROL_SEND_CAP in wire68.h and this file deliberately does not
   restate it - that header pulls in net.h and MacTCP, and a second copy of
   a limit is the bug this area already paid for once. Nothing below depends
   on the shipping number: every property holds for any cap at or above
   NOW68K_FILELIST_MIN_CAP, which is why the paging walk is also run at the
   minimum. */
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

/* ---- helpers ------------------------------------------------------------ */

static void set_file(N68FileRow *r, const char *name, const char *type,
                     const char *creator, long data, long rsrc,
                     unsigned long modified)
{
    memset(r, 0, sizeof *r);
    strncpy(r->name, name, sizeof r->name - 1);
    strncpy(r->file_type, type, sizeof r->file_type - 1);
    strncpy(r->creator, creator, sizeof r->creator - 1);
    r->data_bytes = data;
    r->rsrc_bytes = rsrc;
    r->modified = modified;
}

static void set_folder(N68FileRow *r, const char *name,
                       unsigned long modified)
{
    memset(r, 0, sizeof *r);
    strncpy(r->name, name, sizeof r->name - 1);
    r->folder = 1;
    r->modified = modified;
}

/* A name of 31 bytes, every one of them a high-bit MacRoman character, so
 * every one escapes to six bytes of \uXXXX. This is the name the row bound
 * is measured against. */
static void worst_name(char *out)
{
    int i;

    for (i = 0; i < 31; ++i) {
        out[i] = (char)(unsigned char)0x80;   /* MacRoman A-diaeresis */
    }
    out[31] = '\0';
}

static int contains(const char *hay, const char *needle)
{
    return strstr(hay, needle) != NULL;
}

/* Counts non-overlapping occurrences. */
static int count_of(const char *hay, const char *needle)
{
    int n = 0;
    size_t len = strlen(needle);
    const char *p = hay;

    while ((p = strstr(p, needle)) != NULL) {
        ++n;
        p += len;
    }
    return n;
}

/* Every string this guest emits must be a complete, balanced JSON object as
 * far as a dumb reader can tell: it starts with '{', ends with '}', and the
 * quotes pair up. Not a parser - a tripwire for the failure that matters,
 * which is a frame that stops in the middle of something. */
static int looks_whole(const char *json, long len)
{
    long i;
    int quotes = 0;

    if (len <= 0 || json[0] != '{' || json[len - 1] != '}') {
        return 0;
    }
    if ((long)strlen(json) != len) {
        return 0;          /* the returned length must be the NUL's index */
    }
    for (i = 0; i < len; ++i) {
        if (json[i] == '"' && (i == 0 || json[i - 1] != '\\')) {
            ++quotes;
        }
    }
    return (quotes % 2) == 0;
}

/* ---- the envelope ------------------------------------------------------- */

static void test_envelope(void)
{
    N68FileRow rows[2];
    char out[kAmpleCap];
    long next = -1;
    int more = -1;
    long n;

    set_folder(&rows[0], "Projects", 3000000000UL);
    set_file(&rows[1], "Notes", "TEXT", "ttxt", 4096, 0, 3000000000UL);

    n = n68_filelist_build(7, "", 1, rows, 2, 0, "Macintosh HD:Desktop:",
                           out, (long)sizeof out, &next, &more);
    CHECK(n > 0, "a two-entry root listing builds");
    CHECK(looks_whole(out, n), "the page is a whole JSON object");
    CHECK(contains(out, "\"type\":\"file.listing\""), "type is file.listing");
    CHECK(contains(out, "\"id\":7"), "the request id is echoed");
    CHECK(contains(out, "\"path\":\"\""), "the root path is echoed as \"\"");
    CHECK(contains(out, "\"more\":false"), "nothing beyond, so more is false");
    CHECK(contains(out, "\"cursor\":3"), "cursor advances past both entries");
    CHECK(next == 3, "next_cursor agrees with the emitted cursor");
    CHECK(more == 0, "the more out-parameter agrees with the field");

    /* A folder carries no type, creator or fork sizes - the PowerPC guest
       omits them too, and a folder claiming "dataBytes":0 answers a
       question nobody asked in the frame with least room to answer it. */
    CHECK(contains(out, "{\"name\":\"Projects\",\"kind\":\"folder\","
                        "\"modified\":3000000000}"),
          "a folder entry carries name, kind and modified only");
    CHECK(contains(out, "\"name\":\"Notes\",\"kind\":\"file\","
                        "\"fileType\":\"TEXT\",\"creator\":\"ttxt\","
                        "\"dataBytes\":4096,\"rsrcBytes\":0"),
          "a file entry carries its type, creator and both fork sizes");

    /* modified is unsigned. Past 2^31 it comes out NEGATIVE through a
       signed append, and a negative date decodes perfectly well into 1904 -
       the same hazard file.offer carries in the send half. */
    CHECK(!contains(out, "\"modified\":-"),
          "a Mac date past 2^31 is emitted unsigned");

    /* identity is deliberately absent: it is a precondition token for
       mutations this guest does not serve (n68_filelist.h). */
    CHECK(!contains(out, "\"identity\""),
          "no identity field, which this guest cannot honour");
}

static void test_root_only_on_the_root_listing(void)
{
    N68FileRow row;
    char out[kAmpleCap];
    long n;

    set_file(&row, "Notes", "TEXT", "ttxt", 10, 0, 0);

    n = n68_filelist_build(1, "", 1, &row, 1, 0, "Macintosh HD:Desktop:",
                           out, (long)sizeof out, NULL, NULL);
    CHECK(n > 0 && contains(out, "\"root\":\"Macintosh HD:Desktop:\""),
          "the root listing names the place it is looking at");

    n = n68_filelist_build(1, "Projects", 1, &row, 1, 0,
                           "Macintosh HD:Desktop:", out, (long)sizeof out,
                           NULL, NULL);
    CHECK(n > 0 && !contains(out, "\"root\""),
          "a subfolder listing does not repeat the root");
    CHECK(contains(out, "\"path\":\"Projects\""),
          "a subfolder listing echoes its own path");
}

/* The caption is dropped WHOLE or not at all. Half a root would truncate
   the frame mid-string, which decodes to nothing and costs the listing. */
static void test_root_is_dropped_whole(void)
{
    N68FileRow row;
    char out[512];
    char root[NOW68K_FILELIST_ROOT_MAX + 1];
    long cap;
    int dropped_at_least_once = 0;

    memset(root, 'R', sizeof root);
    root[sizeof root - 1] = '\0';
    set_file(&row, "Notes", "TEXT", "ttxt", 10, 0, 0);

    /* Sweep the buffer through the size where the caption stops fitting. */
    for (cap = 120; cap <= (long)sizeof out; ++cap) {
        long n = n68_filelist_build(1, "", 1, &row, 1, 0, root, out, cap,
                                    NULL, NULL);

        if (n == 0) {
            continue;      /* too small for the envelope at all */
        }
        CHECK(looks_whole(out, n), "a page is whole at every capacity");
        CHECK(n < cap, "a page never fills past the caller's buffer");
        if (!contains(out, "\"root\"")) {
            dropped_at_least_once = 1;
        } else {
            CHECK(contains(out, root),
                  "when the caption is present it is present in full");
        }
    }
    CHECK(dropped_at_least_once,
          "a caption that cannot fit is dropped rather than cut");
}

/* ---- the bounds the static asserts reason against ----------------------- */

static void test_worst_case_parts_are_within_their_bounds(void)
{
    N68FileRow row;
    char name[32];
    char path[NOW68K_FILELIST_PATH_MAX + 1];
    char out[8192];
    long empty, one, head_tail;

    worst_name(name);
    memset(&row, 0, sizeof row);
    strcpy(row.name, name);
    /* Four high bytes each, so the 4CCs escape at six bytes apiece too. */
    memcpy(row.file_type, "\x80\x80\x80\x80", 4);
    memcpy(row.creator, "\x80\x80\x80\x80", 4);
    row.data_bytes = -2147483647L - 1;   /* the widest signed long */
    row.rsrc_bytes = -2147483647L - 1;
    row.modified = 4294967295UL;         /* the widest unsigned 32 */

    memset(path, (char)(unsigned char)0x80, sizeof path - 1);
    path[sizeof path - 1] = '\0';

    empty = n68_filelist_build(-2147483647L - 1, path, 2147483647L,
                               NULL, 0, 0, NULL, out, (long)sizeof out,
                               NULL, NULL);
    CHECK(empty > 0, "the worst-case envelope builds");
    head_tail = empty;
    CHECK(head_tail
              <= NOW68K_FILELIST_HEAD_MAX + NOW68K_FILELIST_TAIL_MAX,
          "the worst-case head and tail fit their declared bounds");

    one = n68_filelist_build(-2147483647L - 1, path, 2147483647L,
                             &row, 1, 0, NULL, out, (long)sizeof out,
                             NULL, NULL);
    CHECK(one > 0, "the worst-case single entry builds");
    CHECK(one - head_tail <= NOW68K_FILELIST_ROW_MAX,
          "the worst-case entry fits NOW68K_FILELIST_ROW_MAX");

    /* The whole point of the three bounds: a page at the declared minimum
       always carries at least one entry. Anything less and every page is
       empty-with-more:true, which is an infinite paging loop. */
    one = n68_filelist_build(-2147483647L - 1, path, 2147483647L,
                             &row, 1, 0, NULL, out,
                             (long)NOW68K_FILELIST_MIN_CAP, NULL, NULL);
    CHECK(one > 0, "the worst case fits NOW68K_FILELIST_MIN_CAP");
    CHECK(looks_whole(out, one), "and is a whole object there");
}

/* ---- paging -------------------------------------------------------------- */

/* A page never truncates a row, and a page with rows to give never comes
   back empty. Swept across every capacity so the almost-fits cases are
   covered rather than hoped for. */
static void test_a_row_goes_in_whole_or_not_at_all(void)
{
    N68FileRow rows[4];
    char out[kAmpleCap];
    long cap;
    int i;

    for (i = 0; i < 4; ++i) {
        char name[32];

        sprintf(name, "Document number %d", i);
        set_file(&rows[i], name, "TEXT", "ttxt", 1024L * (i + 1), 512, 0);
    }

    for (cap = 1; cap <= 900; ++cap) {
        long next = -1;
        int more = -1;
        long one = n68_filelist_build(3, "", 1, rows, 1, 1, NULL, out, cap,
                                      NULL, NULL);
        long n = n68_filelist_build(3, "", 1, rows, 4, 0, NULL, out, cap,
                                    &next, &more);

        /* THE PROPERTY THE TAIL RESERVE BUYS, and the reason it is checked
           against a one-entry build rather than against a constant: a
           capacity that can carry ONE entry must carry a page whatever
           number of entries is pending. Without the reserve, four pending
           entries fill the buffer, the closing `],"more":...` no longer
           fits, and the WHOLE page is refused at a capacity where three
           entries and a tail would have gone out - so the host gets nothing
           at a size where it should have got a page and a cursor.

           Caught by mutation: deleting the reserve leaves every other
           assertion in this function green, because a refused page is not
           a truncated one. */
        if (one > 0) {
            CHECK(n > 0, "a capacity that fits one entry always yields a page");
        }
        if (n == 0) {
            continue;
        }
        CHECK(looks_whole(out, n), "every page that builds is whole");
        CHECK(n < cap, "a page respects the caller's capacity");
        CHECK(next >= 1 && next <= 5, "next_cursor stays in range");
        if (next == 1) {
            /* No entry fitted. The builder must refuse rather than emit an
               empty page the host would ask about forever. */
            CHECK(0, "an empty page with entries pending was emitted");
        }
        CHECK((more != 0) == (next < 5),
              "more is true exactly while entries remain");
    }
}

/* Following `cursor` until `more` is false must visit every entry exactly
   once. Run at the declared minimum capacity, which is where pages are
   smallest and an off-by-one is most likely. */
static void test_paging_visits_every_entry_exactly_once(void)
{
    enum { kTotal = 9 };
    N68FileRow rows[kTotal];
    char out[NOW68K_FILELIST_MIN_CAP];
    long cursor = 1;
    int seen[kTotal];
    int guard = 0;
    int i;

    memset(seen, 0, sizeof seen);
    for (i = 0; i < kTotal; ++i) {
        char name[32];

        sprintf(name, "Entry%d", i);
        set_file(&rows[i], name, "TEXT", "ttxt", 100, 0, 0);
    }

    for (;;) {
        long next = 0;
        int more = 0;
        long remaining = kTotal - (cursor - 1);
        long n;

        CHECK(++guard < 100, "paging terminates");
        if (guard >= 100) {
            return;
        }
        n = n68_filelist_build(1, "", cursor, &rows[cursor - 1],
                               remaining > 0 ? remaining : 0, 0,
                               NULL, out, (long)sizeof out, &next, &more);
        CHECK(n > 0, "every page in the walk builds");
        if (n <= 0) {
            return;
        }
        for (i = (int)cursor - 1; i < (int)next - 1; ++i) {
            char needle[48];

            sprintf(needle, "\"name\":\"Entry%d\"", i);
            CHECK(contains(out, needle), "the page carries the entry it counted");
            CHECK(seen[i] == 0, "no entry is emitted twice");
            seen[i] = 1;
        }
        cursor = next;
        if (!more) {
            break;
        }
    }
    for (i = 0; i < kTotal; ++i) {
        CHECK(seen[i] == 1, "every entry was visited");
    }
}

/* A cursor past the end is a legitimate empty FINAL page, not an error -
   what a host that raced a folder being emptied should see. */
static void test_a_cursor_past_the_end_is_an_empty_final_page(void)
{
    char out[kAmpleCap];
    long next = -1;
    int more = -1;
    long n = n68_filelist_build(4, "", 40, NULL, 0, 0, NULL, out,
                                (long)sizeof out, &next, &more);

    CHECK(n > 0, "an empty page builds");
    CHECK(contains(out, "\"entries\":[]"), "and carries no entries");
    CHECK(contains(out, "\"more\":false"), "and does not promise more");
    CHECK(next == 40 && more == 0, "and leaves the cursor where it was");
}

/* The enumerator saw more even though every row it handed over fitted. */
static void test_more_beyond_is_carried_through(void)
{
    N68FileRow row;
    char out[kAmpleCap];
    int more = -1;
    long n;

    set_file(&row, "Notes", "TEXT", "ttxt", 1, 0, 0);
    n = n68_filelist_build(1, "", 1, &row, 1, 1, NULL, out,
                           (long)sizeof out, NULL, &more);
    CHECK(n > 0 && contains(out, "\"more\":true"),
          "more_beyond reaches the wire even when the page was not full");
    CHECK(more == 1, "and the out-parameter agrees");
}

/* ---- escaping ------------------------------------------------------------ */

static void test_a_macroman_name_does_not_cost_the_page(void)
{
    N68FileRow row;
    char out[kAmpleCap];
    long n;

    memset(&row, 0, sizeof row);
    strcpy(row.name, "Caf\xA9 notes");    /* MacRoman (c) */
    strcpy(row.file_type, "TEXT");
    strcpy(row.creator, "ttxt");
    n = n68_filelist_build(1, "", 1, &row, 1, 0, NULL, out,
                           (long)sizeof out, NULL, NULL);
    CHECK(n > 0 && looks_whole(out, n), "a high-bit name still builds");
    CHECK(contains(out, "\\u00A9"), "and is escaped rather than sent raw");

    /* A quote in a name is legal on HFS and must not open a second field. */
    memset(&row, 0, sizeof row);
    strcpy(row.name, "the \"good\" one");
    n = n68_filelist_build(1, "", 1, &row, 1, 0, NULL, out,
                           (long)sizeof out, NULL, NULL);
    CHECK(n > 0 && looks_whole(out, n), "a quoted name still builds");
    CHECK(contains(out, "\\\""), "and its quotes are escaped");
}

/* ---- the `ls` table ------------------------------------------------------ */

static void test_describe_matches_the_powerpc_vocabulary(void)
{
    N68FileRow row;
    char out[kN68CmdRowValueCap];

    set_folder(&row, "Projects", 0);
    n68_filelist_describe(&row, out, (long)sizeof out);
    CHECK(strcmp(out, "folder") == 0, "a folder is described as one");

    set_file(&row, "App", "APPL", "MACS", 400L * 1024, 12L * 1024, 0);
    n68_filelist_describe(&row, out, (long)sizeof out);
    CHECK(strcmp(out, "APPL  400 KB + 12 KB rsrc") == 0,
          "a two-fork file names both forks");

    set_file(&row, "Icon", "ICON", "MACS", 0, 3L * 1024, 0);
    n68_filelist_describe(&row, out, (long)sizeof out);
    CHECK(strcmp(out, "ICON  3 KB rsrc") == 0,
          "a resource-only file names only the resource fork");

    set_file(&row, "Notes", "TEXT", "ttxt", 4096, 0, 0);
    n68_filelist_describe(&row, out, (long)sizeof out);
    CHECK(strcmp(out, "TEXT  4 KB") == 0, "a data-only file names one size");

    /* A file with no type is not an error and must still describe. */
    set_file(&row, "Odd", "", "", 100, 0, 0);
    n68_filelist_describe(&row, out, (long)sizeof out);
    CHECK(strcmp(out, "????  0 KB") == 0, "a typeless file still describes");
}

static void test_ls_rows_say_where_they_are_looking(void)
{
    N68FileRow rows[2];
    N68CmdRows table;
    char out[2048];
    long n;

    set_folder(&rows[0], "Projects", 0);
    set_file(&rows[1], "Notes", "TEXT", "ttxt", 2048, 0, 0);
    n68_filelist_rows("", "Macintosh HD:Desktop:", rows, 2, 0, &table);

    CHECK(table.ok, "a listing is a success");
    CHECK(strcmp(table.key, "ls") == 0, "the output key is the verb");
    CHECK(table.count == 4, "two headings plus two entries");
    CHECK(strcmp(table.rows[0].label, "Share") == 0
              && strcmp(table.rows[0].value, "Macintosh HD:Desktop:") == 0,
          "the first row names the share");
    CHECK(strcmp(table.rows[1].label, "Folder") == 0
              && strcmp(table.rows[1].value, "(root)") == 0,
          "the second row names the folder");

    n = n68_cmdrows_render_json(&table, 9, out, (long)sizeof out);
    CHECK(n > 0 && looks_whole(out, n), "the table renders as whole JSON");
    CHECK(contains(out, "\"type\":\"command.result\""), "as a command.result");
    CHECK(contains(out, "\"id\":9"), "echoing the request id");
    CHECK(contains(out, "\"ok\":true"), "and reporting success");
    CHECK(contains(out, "\"output\":{\"ls\":[["), "under output.ls");
    CHECK(contains(out, "[\"Notes\",\"TEXT  2 KB\"]"),
          "with the entry described the way the console describes it");
    CHECK(!contains(out, "more not shown"),
          "and no truncation note when nothing was dropped");

    n68_filelist_rows("Projects", "Macintosh HD:Desktop:", rows, 2, 0,
                      &table);
    CHECK(strcmp(table.rows[1].value, "Projects") == 0,
          "a subfolder listing names the subfolder");
}

/* Two different reasons for a short list, both said out loud. A reader that
   saw only one of them would draw the wrong conclusion about the other. */
static void test_both_kinds_of_truncation_are_stated(void)
{
    N68FileRow rows[NOW68K_FILELIST_MAX_ROWS];
    N68CmdRows table;
    char out[NOW68K_CMDROWS_MIN_CAP];
    char big[4096];
    long n;
    int i;

    for (i = 0; i < NOW68K_FILELIST_MAX_ROWS; ++i) {
        char name[32];

        sprintf(name, "Document number %d", i);
        set_file(&rows[i], name, "TEXT", "ttxt", 1024, 0, 0);
    }

    /* (1) the enumerator saw more than the page held. */
    n68_filelist_rows("", "HD:", rows, NOW68K_FILELIST_MAX_ROWS, 1, &table);
    CHECK(strcmp(table.rows[table.count - 1].label, "...") == 0,
          "a folder that goes on past the page says so");
    CHECK(strcmp(table.rows[table.count - 1].value,
                 "more entries follow") == 0,
          "in the enumerator's own words");

    n = n68_cmdrows_render_json(&table, 1, big, (long)sizeof big);
    CHECK(n > 0 && contains(big, "[\"...\",\"more entries follow\"]"),
          "and that row reaches the wire");

    /* (2) the reply buffer could not carry every row the table held. */
    n = n68_cmdrows_render_json(&table, 1, out, (long)sizeof out);
    CHECK(n > 0 && looks_whole(out, n),
          "a table too big for the buffer still renders whole");
    CHECK(contains(out, "more not shown"),
          "and says how many rows it dropped rather than shortening quietly");
    CHECK(count_of(out, "\"...\"") >= 1, "through a final ... row");
}

/* ---- the rows result type ------------------------------------------------ */

static void test_rows_render_json_never_truncates_a_row(void)
{
    N68CmdRows table;
    char out[2048];
    long cap;
    int i;

    n68_cmdrows_init(&table);
    table.ok = 1;
    strcpy(table.key, "ls");
    for (i = 0; i < 8; ++i) {
        char label[kN68CmdRowLabelCap];

        sprintf(label, "Row number %d", i);
        (void)n68_cmdrows_add(&table, label, "TEXT  128 KB + 4 KB rsrc");
    }

    for (cap = 1; cap <= (long)sizeof out; ++cap) {
        long n = n68_cmdrows_render_json(&table, 5, out, cap);

        if (n == 0) {
            continue;
        }
        CHECK(looks_whole(out, n), "every rendering that fits is whole");
        CHECK(n < cap, "and respects the caller's capacity");
        /* If a row was dropped the reply must say so; if none was, it must
           not claim one. Counting the rows that made it is the only way to
           tell the two apart from out here. */
        if (count_of(out, "\"Row number ") < 8) {
            CHECK(contains(out, "more not shown"),
                  "a dropped row is always accounted for");
        } else {
            CHECK(!contains(out, "more not shown"),
                  "a complete table claims no truncation");
        }
    }
}

static void test_rows_hold_their_declared_bounds(void)
{
    N68CmdRows table;
    char label[kN68CmdRowLabelCap];
    char value[kN68CmdRowValueCap];
    char out[4096];
    long envelope, one;

    memset(label, (char)(unsigned char)0x80, sizeof label - 1);
    label[sizeof label - 1] = '\0';
    memset(value, (char)(unsigned char)0x80, sizeof value - 1);
    value[sizeof value - 1] = '\0';

    n68_cmdrows_init(&table);
    table.ok = 1;
    strcpy(table.key, "ls");
    envelope = n68_cmdrows_render_json(&table, -2147483647L - 1, out,
                                       (long)sizeof out);
    CHECK(envelope > 0 && envelope <= NOW68K_CMDROWS_HEAD_MAX
                                       + NOW68K_CMDROWS_TAIL_MAX,
          "the worst-case envelope fits its declared bounds");

    (void)n68_cmdrows_add(&table, label, value);
    one = n68_cmdrows_render_json(&table, -2147483647L - 1, out,
                                  (long)sizeof out);
    CHECK(one > 0 && one - envelope <= NOW68K_CMDROWS_ROW_MAX,
          "the worst-case row fits NOW68K_CMDROWS_ROW_MAX");

    /* And the whole reason those bounds exist. */
    one = n68_cmdrows_render_json(&table, -2147483647L - 1, out,
                                  (long)NOW68K_CMDROWS_MIN_CAP);
    CHECK(one > 0 && looks_whole(out, one),
          "a worst-case row fits NOW68K_CMDROWS_MIN_CAP");
}

static void test_a_full_table_reports_the_row_it_could_not_hold(void)
{
    N68CmdRows table;
    int i;
    int refused = 0;

    n68_cmdrows_init(&table);
    for (i = 0; i < kN68CmdRowsMax + 4; ++i) {
        if (!n68_cmdrows_add(&table, "x", "y")) {
            ++refused;
        }
    }
    CHECK(table.count == kN68CmdRowsMax, "the table stops at its capacity");
    CHECK(refused == 4, "and says so rather than dropping rows quietly");
}

static void test_an_error_is_an_error_and_not_a_table(void)
{
    N68CmdRows table;
    char out[1024];
    long n;

    n68_cmdrows_init(&table);
    table.ok = 1;
    strcpy(table.key, "ls");
    (void)n68_cmdrows_add(&table, "Share", "HD:");
    n68_cmdrows_set_error(&table, "bad-path",
                          "that path is not one this Mac will list");
    CHECK(table.count == 0, "an error clears the rows already added");

    n = n68_cmdrows_render_json(&table, 2, out, (long)sizeof out);
    CHECK(n > 0 && looks_whole(out, n), "a refusal renders whole");
    CHECK(contains(out, "\"ok\":false"), "as a failure");
    CHECK(contains(out, "\"code\":\"bad-path\""), "naming the code");
    CHECK(!contains(out, "\"output\""), "and carrying no output object");

    n = n68_cmdrows_render_text(&table, out, (long)sizeof out);
    CHECK(n > 0 && strncmp(out, "! bad-path: ", 12) == 0,
          "and reads as a failure from the first character on a 1-bit panel");
}

static void test_rows_render_as_console_text(void)
{
    N68FileRow row;
    N68CmdRows table;
    char out[1024];
    long n;

    set_file(&row, "Notes", "TEXT", "ttxt", 2048, 0, 0);
    n68_filelist_rows("", "HD:Desktop:", &row, 1, 0, &table);

    n = n68_cmdrows_render_text(&table, out, (long)sizeof out);
    CHECK(n > 0, "a table renders as text");
    CHECK((long)strlen(out) == n, "and the returned length is the NUL's index");
    CHECK(count_of(out, "\r") == 2, "one CR between each of three rows");
    CHECK(contains(out, "Share"), "the share row is there");
    CHECK(contains(out, "Notes"), "and the entry");
    CHECK(!contains(out, "\n"), "CR only - the ring splits on what we write");

    /* The value column lines up, which is the only way a listing reads as a
       table on a 1-bit panel in Monaco 9. */
    CHECK(contains(out, "Share               HD:Desktop:"),
          "labels are padded to a fixed column");

    /* A line that does not fit is dropped whole rather than left half
       written - the same rule as the wire, for a different reason. */
    n = n68_cmdrows_render_text(&table, out, 12);
    CHECK(n >= 0 && (long)strlen(out) == n,
          "a short buffer still yields a terminated string");
    CHECK(!contains(out, "\r") || out[n - 1] != '\r',
          "and never ends on a dangling separator");
}

/* ---- the bytes, pinned ---------------------------------------------------
 *
 * These three strings are transcribed verbatim into Guest68KWire in
 * now-host/Tests/HostTests/GuestWireFixtureTests.swift, and that is the whole
 * point of pinning them here: this test proves the guest BUILDS these
 * bytes, the host's proves it DECODES them and that they carry the fields
 * the contract requires. Neither half proves anything on its own, and a
 * test that constructs the message it then parses proves less than either
 * (AGENTS.md). It is the arrangement test_puttx.c already uses for the
 * send half.
 *
 * If one of these changes, the host fixture changes with it or the two
 * halves have stopped meeting.
 */
static void test_the_exact_bytes(void)
{
    N68FileRow rows[3];
    N68CmdRows table;
    char out[1024];
    long n;

    set_folder(&rows[0], "Projects", 3000000000UL);
    set_file(&rows[1], "Read Me", "TEXT", "ttxt", 4096, 0, 3000000000UL);
    set_file(&rows[2], "NOW-68K", "APPL", "NW68", 131072, 262144,
             3000000000UL);

    n = n68_filelist_build(11, "", 1, rows, 3, 1,
                           "Macintosh HD:Desktop Folder:", out,
                           (long)sizeof out, NULL, NULL);
    CHECK(n > 0 && strcmp(out,
        "{\"type\":\"file.listing\",\"id\":11,\"path\":\"\",\"entries\":["
        "{\"name\":\"Projects\",\"kind\":\"folder\","
        "\"modified\":3000000000},"
        "{\"name\":\"Read Me\",\"kind\":\"file\",\"fileType\":\"TEXT\","
        "\"creator\":\"ttxt\",\"dataBytes\":4096,\"rsrcBytes\":0,"
        "\"modified\":3000000000},"
        "{\"name\":\"NOW-68K\",\"kind\":\"file\",\"fileType\":\"APPL\","
        "\"creator\":\"NW68\",\"dataBytes\":131072,\"rsrcBytes\":262144,"
        "\"modified\":3000000000}"
        "],\"more\":true,\"cursor\":4,"
        "\"root\":\"Macintosh HD:Desktop Folder:\"}") == 0,
        "the root page is byte-for-byte what the host fixture decodes");

    n = n68_filelist_build(12, "Projects", 4, &rows[1], 1, 0, NULL, out,
                           (long)sizeof out, NULL, NULL);
    CHECK(n > 0 && strcmp(out,
        "{\"type\":\"file.listing\",\"id\":12,\"path\":\"Projects\","
        "\"entries\":[{\"name\":\"Read Me\",\"kind\":\"file\","
        "\"fileType\":\"TEXT\",\"creator\":\"ttxt\",\"dataBytes\":4096,"
        "\"rsrcBytes\":0,\"modified\":3000000000}],"
        "\"more\":false,\"cursor\":5}") == 0,
        "the last subfolder page is byte-for-byte the host's fixture");

    n68_filelist_rows("", "Macintosh HD:Desktop Folder:", rows, 3, 1,
                      &table);
    n = n68_cmdrows_render_json(&table, 13, out, (long)sizeof out);
    CHECK(n > 0 && strcmp(out,
        "{\"type\":\"command.result\",\"id\":13,\"ok\":true,"
        "\"output\":{\"ls\":["
        "[\"Share\",\"Macintosh HD:Desktop Folder:\"],"
        "[\"Folder\",\"(root)\"],"
        "[\"Projects\",\"folder\"],"
        "[\"Read Me\",\"TEXT  4 KB\"],"
        "[\"NOW-68K\",\"APPL  128 KB + 256 KB rsrc\"],"
        "[\"...\",\"more entries follow\"]]}}") == 0,
        "the ls reply is byte-for-byte what the host fixture decodes");
}

int main(void)
{
    test_envelope();
    test_root_only_on_the_root_listing();
    test_root_is_dropped_whole();
    test_worst_case_parts_are_within_their_bounds();
    test_a_row_goes_in_whole_or_not_at_all();
    test_paging_visits_every_entry_exactly_once();
    test_a_cursor_past_the_end_is_an_empty_final_page();
    test_more_beyond_is_carried_through();
    test_a_macroman_name_does_not_cost_the_page();
    test_describe_matches_the_powerpc_vocabulary();
    test_ls_rows_say_where_they_are_looking();
    test_both_kinds_of_truncation_are_stated();
    test_rows_render_json_never_truncates_a_row();
    test_rows_hold_their_declared_bounds();
    test_a_full_table_reports_the_row_it_could_not_hold();
    test_an_error_is_an_error_and_not_a_table();
    test_rows_render_as_console_text();
    test_the_exact_bytes();

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
