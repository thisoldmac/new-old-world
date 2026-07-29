/* Host-side test for NOW-68K's software.listing serializer and the `sw`
 * table (src/software/n68_swlist.c).
 *
 * This is the half of the software family with no Toolbox in it, split off
 * for exactly that reason (n68_swlist.h). The catalog sweep in
 * n68_swenum.c cannot be reached from here and is NOT tested here - worth
 * saying plainly, because "the software listing is tested" would be a
 * misleading summary of this file. Nothing below proves that a real System
 * Folder reads back correctly, that PBCatSearch finds an application, or
 * that the sweep finishes inside its budget on a 68030. Those are emulator
 * and metal questions and they are open.
 *
 * What IS tested is everything that can silently corrupt a page or lie
 * about a bound:
 *
 *   - the never-truncate-a-row rule. A frame that stops mid-JSON decodes to
 *     nothing on the host, so one entry too many costs the WHOLE page. The
 *     interesting cases are the ones where an entry ALMOST fits.
 *   - the worst-case bounds. NOW68K_SWLIST_ROW_MAX and its head/tail
 *     siblings are what wire68.c's static assert reasons against, and the
 *     whole design of NOW68K_SWLIST_PATH_MAX is solved backwards from them
 *     - so this file BUILDS the worst case and measures it. If the row
 *     bound is wrong, the shipping guest can emit a page it cannot fit.
 *   - the paging arithmetic. Following `cursor` until `more` is false must
 *     visit every entry exactly once; off-by-one here is a lost or
 *     duplicated APPLICATION and neither shows in a single page.
 *   - the refusal to emit an empty page with more:true, which is an
 *     infinite paging loop on the host rather than a small listing.
 *   - the two-folder cursor split, which is where a folder domain's
 *     "enabled items, then the disabled sibling's" becomes one sequence.
 *   - the note being dropped WHOLE when it does not fit. Half a note
 *     truncates the frame mid-string and costs the entire page.
 *   - `path` being present on every entry even when empty, because the
 *     schema requires it and empty is a MEANING (not launchable from afar).
 *   - truncation being STATED by the `sw` table, twice over and for two
 *     different reasons - the page ended, versus the inventory stopped at
 *     this machine's bound. Those are different news.
 *   - MacRoman escaping. HFS names carry high bytes and the host decodes
 *     UTF-8; one option-character in one name must not cost the page.
 *
 * The parser here is deliberately dumb - substring searches over the
 * emitted text, not a JSON reader. A test that parsed with the guest's own
 * scanner would be testing one half twice (AGENTS.md).
 */

#include "n68_swlist.h"

#include <stdio.h>
#include <string.h>

/* Comfortably above the minimum. The SHIPPING cap is
   NOW68K_CONTROL_SEND_CAP in wire68.h and this file deliberately does not
   restate it - that header pulls in net.h and MacTCP, and a second copy of
   a limit is a bug this area has already paid for once. Every property
   below holds for any cap at or above NOW68K_SWLIST_MIN_CAP, which is why
   the paging walk is also run at the minimum. */
enum { kAmpleCap = 4096 };

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                             \
        g_checks++;                                                       \
        if (!(cond)) {                                                    \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, (msg));        \
            g_failures++;                                                 \
        }                                                                 \
    } while (0)

static void fill_row(N68SwRow *row, const char *name, const char *path,
                     const char *type, const char *creator, long size_k,
                     int off)
{
    memset(row, 0, sizeof *row);
    strncpy(row->name, name, sizeof row->name - 1);
    strncpy(row->path, path, sizeof row->path - 1);
    strncpy(row->file_type, type, sizeof row->file_type - 1);
    strncpy(row->creator, creator, sizeof row->creator - 1);
    row->size_k = size_k;
    row->off = (unsigned char)(off ? 1 : 0);
}

/* ---- the domain vocabulary ---------------------------------------------- */

static void test_domains(void)
{
    static const char *const words[] = {
        "apps", "extensions", "cdevs", "startup", "apple"
    };
    int i;

    CHECK(n68_swlist_domain(NULL) == kN68SwDomainNone,
          "NULL is the overview, not an error");
    CHECK(n68_swlist_domain("") == kN68SwDomainNone,
          "empty is the overview");
    CHECK(n68_swlist_domain("Apps") == kN68SwDomainUnknown,
          "the contract's enum is case-sensitive and so is this");
    CHECK(n68_swlist_domain("app") == kN68SwDomainUnknown,
          "a prefix of a domain is not a domain");
    CHECK(n68_swlist_domain("appsx") == kN68SwDomainUnknown,
          "a superstring of a domain is not a domain");
    CHECK(n68_swlist_domain("processes") == kN68SwDomainUnknown,
          "a word from another family is not a domain");

    /* Round-trip: every word the contract lists parses, and renders back to
     * the SAME word. A domain that is spellable in and not out would put a
     * host's own string on the wire. */
    for (i = 0; i < NOW68K_SWLIST_DOMAIN_COUNT; ++i) {
        N68SwDomain d = n68_swlist_domain(words[i]);

        CHECK(d != kN68SwDomainUnknown, "a contract domain must parse");
        CHECK(strcmp(n68_swlist_domain_word(d), words[i]) == 0,
              "a domain must render back to the word it parsed from");
    }
    CHECK(n68_swlist_domain_word(kN68SwDomainNone)[0] == '\0',
          "the overview has no wire word");
    CHECK(n68_swlist_domain_word(kN68SwDomainUnknown)[0] == '\0',
          "an unknown domain has no wire word");
}

/* Every note must fit the tail budget the frame arithmetic assumes. The .c
 * asserts this at compile time for its own literals; this asserts it
 * through the published accessors, which is what a caller actually sees. */
static void test_notes_fit(void)
{
    CHECK((long)strlen(n68_swlist_note_unknown_domain())
              <= NOW68K_SWLIST_NOTE_MAX,
          "the unknown-domain note exceeds the tail budget");
    CHECK((long)strlen(n68_swlist_note_truncated())
              <= NOW68K_SWLIST_NOTE_MAX,
          "the truncation note exceeds the tail budget");
    CHECK((long)strlen(n68_swlist_note_root_only())
              <= NOW68K_SWLIST_NOTE_MAX,
          "the root-only note exceeds the tail budget");
    CHECK(strcmp(n68_swlist_note_truncated(),
                 n68_swlist_note_root_only()) != 0,
          "a narrower search and a truncated one are different news");
}

/* ---- the two-folder cursor split ---------------------------------------- */

static void test_cursor_split(void)
{
    long index = 0;
    int in_disabled = 9;

    (void)n68_swlist_split_cursor(1, 5, &index, &in_disabled);
    CHECK(index == 1 && in_disabled == 0, "cursor 1 is the first enabled");

    (void)n68_swlist_split_cursor(5, 5, &index, &in_disabled);
    CHECK(index == 5 && in_disabled == 0,
          "the last enabled item is still enabled - the boundary is <=, and "
          "an off-by-one here shows an item in the wrong folder");

    (void)n68_swlist_split_cursor(6, 5, &index, &in_disabled);
    CHECK(index == 1 && in_disabled == 1,
          "one past the enabled folder is the FIRST disabled item");

    (void)n68_swlist_split_cursor(9, 5, &index, &in_disabled);
    CHECK(index == 4 && in_disabled == 1, "and it keeps counting from there");

    /* No enabled items at all: the whole cursor space is the disabled
     * folder. A machine whose Extensions folder is empty but whose
     * Extensions (Disabled) is not is a real machine. */
    (void)n68_swlist_split_cursor(1, 0, &index, &in_disabled);
    CHECK(index == 1 && in_disabled == 1,
          "with nothing enabled, cursor 1 is the first disabled item");

    /* Below 1 is read as 1, matching the contract's absent-cursor case and
     * n68_swlist_build's own clamp. */
    (void)n68_swlist_split_cursor(0, 5, &index, &in_disabled);
    CHECK(index == 1 && in_disabled == 0, "cursor 0 is the first page");
    (void)n68_swlist_split_cursor(-7, 5, &index, &in_disabled);
    CHECK(index == 1 && in_disabled == 0, "a negative cursor is the first page");

    /* A negative enabled_count cannot come from the File Manager, but a
     * split that trusted one would index a folder backwards. */
    (void)n68_swlist_split_cursor(1, -3, &index, &in_disabled);
    CHECK(index == 1, "a nonsense count must not produce a nonsense index");
}

/* ---- the message ---------------------------------------------------------- */

static void test_shape(void)
{
    N68SwRow rows[2];
    char out[kAmpleCap];
    long next = 0;
    int more = 9;
    long n;

    fill_row(&rows[0], "SimpleText", "HD:Applications:SimpleText", "APPL",
             "ttxt", 384, 0);
    fill_row(&rows[1], "Sound Manager",
             "HD:System Folder:Extensions (Disabled):Sound Manager", "INIT",
             "sndM", 72, 1);

    n = n68_swlist_build(41, "extensions", 1, rows, 2, 0, NULL, out,
                         (long)sizeof out, &next, &more);
    CHECK(n > 0, "a two-entry page must build");
    CHECK((long)strlen(out) == n, "the return is the byte count before NUL");
    CHECK(strstr(out, "\"type\":\"software.listing\"") != NULL,
          "the schema's type");
    CHECK(strstr(out, "\"id\":41") != NULL, "the id is echoed");
    CHECK(strstr(out, "\"domain\":\"extensions\"") != NULL,
          "the domain is echoed");
    CHECK(strstr(out, "\"name\":\"SimpleText\"") != NULL, "entry one's name");
    CHECK(strstr(out, "\"path\":\"HD:Applications:SimpleText\"") != NULL,
          "the path is the launch key and must survive verbatim");
    CHECK(strstr(out, "\"type\":\"APPL\"") != NULL, "the Finder type");
    CHECK(strstr(out, "\"creator\":\"ttxt\"") != NULL, "the creator");
    CHECK(strstr(out, "\"sizeK\":384") != NULL, "the size in KB");
    CHECK(strstr(out, "\"off\":true") != NULL,
          "the disabled entry must be marked");
    CHECK(strstr(out, "\"more\":false") != NULL, "nothing beyond this page");
    CHECK(next == 3, "next cursor is cursor + entries emitted");
    CHECK(more == 0, "and more agrees with it");
    CHECK(strstr(out, "\"note\"") == NULL,
          "a page with nothing to confess carries no note");

    /* `off` is emitted only when true - a false one is the default reading
     * of an absent field, and this frame has no bytes to spare. Exactly one
     * occurrence, from entry two. */
    CHECK(strstr(out, "\"off\":false") == NULL,
          "a false off must not be spelled out");
}

/* `path` is REQUIRED by SoftwareListing.entries and empty is its own
 * meaning ("listed but not launchable from afar"). An entry that dropped
 * the field to save bytes would be a schema violation dressed up as
 * brevity - and the host would have no way to tell it from a bug. */
static void test_empty_path_is_still_a_path(void)
{
    N68SwRow row;
    char out[kAmpleCap];
    long n;

    fill_row(&row, "Buried App", "", "APPL", "????", 12, 0);
    n = n68_swlist_build(1, "apps", 1, &row, 1, 0, NULL, out,
                         (long)sizeof out, NULL, NULL);
    CHECK(n > 0, "an entry with no nameable path must still be listed");
    CHECK(strstr(out, "\"path\":\"\"") != NULL,
          "path is required by the schema, and empty is the answer");
}

/* An unreadable size is -1 in the contract, which is an ANSWER and must be
 * emitted rather than suppressed into a plausible 0. */
static void test_unreadable_size(void)
{
    N68SwRow row;
    char out[kAmpleCap];

    fill_row(&row, "Vanished", "HD:Vanished", "", "", -1, 0);
    (void)n68_swlist_build(1, "apps", 1, &row, 1, 0, NULL, out,
                           (long)sizeof out, NULL, NULL);
    CHECK(strstr(out, "\"sizeK\":-1") != NULL,
          "-1 is the contract's word for unreadable");
    CHECK(strstr(out, "\"type\":\"\"") == NULL,
          "an absent Finder type is omitted, not sent as an empty string");
    CHECK(strstr(out, "\"creator\":\"\"") == NULL,
          "and so is an absent creator");
}

/* ---- the bounds wire68.c's static assert reasons against ---------------- */

static void test_bounds(void)
{
    N68SwRow row;
    char name[32];
    char path[NOW68K_SWLIST_PATH_MAX + 1];
    char out[kAmpleCap];
    long empty_len;
    long one_len;
    long head_tail;
    long row_cost;
    long n;
    int i;

    /* The worst case is every byte escaping to six: an HFS name is MacRoman
     * and 0x80.. is exactly what an option-character file name is made of. */
    for (i = 0; i < 31; ++i) {
        name[i] = (char)0xC9;
    }
    name[31] = '\0';
    for (i = 0; i < NOW68K_SWLIST_PATH_MAX; ++i) {
        path[i] = (char)0xC9;
    }
    path[NOW68K_SWLIST_PATH_MAX] = '\0';

    memset(&row, 0, sizeof row);
    memcpy(row.name, name, sizeof name);
    memcpy(row.path, path, sizeof path);
    /* A 4CC can carry high bytes too; nothing forbids it. */
    memset(row.file_type, 0xC9, 4);
    memset(row.creator, 0xC9, 4);
    row.size_k = 2147483647L;   /* the widest a long prints */
    row.off = 1;

    /* Head + tail: an empty page with the longest domain word, the widest
     * id and cursor, and the longest note. */
    empty_len = n68_swlist_build(99999999999L, "extensions", 99999999999L,
                                 NULL, 0, 0, n68_swlist_note_truncated(),
                                 out, (long)sizeof out, NULL, NULL);
    CHECK(empty_len > 0, "an empty page with a note must build");
    head_tail = empty_len;
    CHECK(head_tail <= NOW68K_SWLIST_HEAD_MAX + NOW68K_SWLIST_TAIL_MAX,
          "head+tail exceed their declared bounds - wire68.c's static "
          "assert is now reasoning against the wrong number");

    one_len = n68_swlist_build(99999999999L, "extensions", 99999999999L,
                               &row, 1, 1, n68_swlist_note_truncated(),
                               out, (long)sizeof out, NULL, NULL);
    CHECK(one_len > 0, "the worst-case row must build at an ample cap");
    row_cost = one_len - head_tail;
    CHECK(row_cost <= NOW68K_SWLIST_ROW_MAX,
          "the worst-case row exceeds NOW68K_SWLIST_ROW_MAX - either shrink "
          "NOW68K_SWLIST_PATH_MAX or raise the bound AND re-check that "
          "MIN_CAP still fits the shipping frame");

    /* And the whole point of the arithmetic: one worst-case row, with the
     * longest note, inside the smallest buffer the header promises. If this
     * fails, the shipping guest can build a page it cannot send. */
    n = n68_swlist_build(99999999999L, "extensions", 99999999999L, &row, 1,
                         1, n68_swlist_note_truncated(), out,
                         (long)NOW68K_SWLIST_MIN_CAP, NULL, NULL);
    CHECK(n > 0,
          "MIN_CAP must hold one worst-case entry - below that every page "
          "is empty with more:true and the host pages forever");
}

/* ---- never truncate a row ------------------------------------------------ */

static void test_row_is_whole_or_absent(void)
{
    N68SwRow rows[4];
    char out[kAmpleCap];
    long cap;
    int i;

    /* WORST-CASE rows, not comfortable ones. With small entries the sweep
     * below never reaches a page boundary, so every cap fits every row and
     * the interesting arithmetic is never run - which is exactly how a
     * removed tail reserve passed a sweep of nine hundred capacities. At
     * ~790 bytes an entry, the boundary lands inside the range. */
    for (i = 0; i < 4; ++i) {
        int k;

        memset(&rows[i], 0, sizeof rows[i]);
        for (k = 0; k < 31; ++k) {
            rows[i].name[k] = (char)0xC9;
        }
        for (k = 0; k < NOW68K_SWLIST_PATH_MAX; ++k) {
            rows[i].path[k] = (char)0xC9;
        }
        memset(rows[i].file_type, 0xC9, 4);
        memset(rows[i].creator, 0xC9, 4);
        rows[i].size_k = 2147483647L;
        rows[i].off = 1;
    }

    /* Sweep every cap from the minimum to comfortably past a full page. At
     * each one the emitted text must be complete JSON - the closing "]}"
     * present, no dangling entry - or nothing at all. The interesting caps
     * are the handful where the next entry ALMOST fits. */
    for (cap = NOW68K_SWLIST_MIN_CAP; cap <= NOW68K_SWLIST_MIN_CAP + 900;
         ++cap) {
        long next = 0;
        int more = 0;
        long n = n68_swlist_build(7, "apps", 1, rows, 4, 0, NULL, out, cap,
                                  &next, &more);

        /* AT OR ABOVE MIN_CAP A PAGE MUST BUILD. This is the assertion the
         * tail reserve exists for, and the one that catches its removal:
         * without room held back for "],\"more\":...}", the loop spends the
         * last bytes on a row, the tail then fails to append, and the whole
         * page is refused - which reads to a host as a guest that went
         * silent, at the caps where a shorter page was available all along.
         * Losing a row is the intended trade; losing the page is not. */
        CHECK(n > 0, "a page must build at any cap at or above MIN_CAP - a "
                     "refusal here means the tail was not reserved for");
        if (n <= 0) {
            continue;
        }
        CHECK(n < cap, "a page must fit the buffer it was given");
        CHECK(out[n] == '\0', "and be terminated");
        CHECK(strstr(out, "],\"more\":") != NULL,
              "a page that emitted anything must close its entry array - a "
              "frame that stops mid-JSON costs the WHOLE page, not one row");
        CHECK(out[n - 1] == '}', "and close the object");
        /* Whatever it emitted, the cursor and `more` must agree with it. */
        if (next - 1 < 4) {
            CHECK(more == 1,
                  "entries were left behind, so more must be true or the "
                  "host stops asking and silently loses them");
        }
    }
}

/* An empty page with more:true makes a host ask for the same cursor
 * forever. It must be refused instead - the caller's buffer is below
 * MIN_CAP, which is a build-time bug that wire68.c's static assert keeps
 * unreachable in the shipping guest. */
static void test_no_empty_page_with_more(void)
{
    N68SwRow row;
    char out[kAmpleCap];
    long cap;

    fill_row(&row, "SimpleText", "HD:Applications:SimpleText", "APPL",
             "ttxt", 384, 0);
    for (cap = 1; cap < NOW68K_SWLIST_MIN_CAP; ++cap) {
        long n = n68_swlist_build(1, "apps", 1, &row, 1, 0, NULL, out, cap,
                                  NULL, NULL);

        if (n > 0) {
            CHECK(strstr(out, "\"entries\":[{") != NULL,
                  "a page that built at a small cap must contain the entry "
                  "it claims to - an empty page with more:true is an "
                  "infinite paging loop, not a small listing");
        }
    }
}

/* ---- paging ---------------------------------------------------------------- */

/* Following `cursor` until `more` is false must visit every entry exactly
 * once. Asserting on one page's numbers cannot see an off-by-one; walking
 * can, and an off-by-one here is a lost or duplicated application. */
static void test_paging_walk(long cap)
{
    enum { kTotal = 23 };
    N68SwRow rows[kTotal];
    char out[kAmpleCap];
    int seen[kTotal];
    long cursor = 1;
    int guard = 0;
    int i;

    for (i = 0; i < kTotal; ++i) {
        char nm[16];

        sprintf(nm, "Item %02d", i);
        fill_row(&rows[i], nm, "HD:System Folder:Extensions:Item", "INIT",
                 "abcd", 40 + i, i % 3 == 0);
        seen[i] = 0;
    }

    while (guard++ < 200) {
        long remaining = kTotal - (cursor - 1);
        long next = 0;
        int more = 0;
        long n;
        long emitted;
        long k;

        if (remaining < 0) {
            remaining = 0;
        }
        n = n68_swlist_build(3, "extensions", cursor, &rows[cursor - 1],
                             remaining, 0, NULL, out, cap, &next, &more);
        CHECK(n > 0, "every page of the walk must build");
        if (n <= 0) {
            return;
        }
        emitted = next - cursor;
        CHECK(emitted >= 1 || remaining == 0,
              "a page with entries left must emit at least one");
        CHECK(emitted <= NOW68K_SWLIST_MAX_ROWS,
              "a page must not exceed the schema's maxItems");
        for (k = 0; k < emitted; ++k) {
            seen[cursor - 1 + k] += 1;
        }
        cursor = next;
        if (!more) {
            break;
        }
    }
    CHECK(guard < 200, "the walk terminated");
    for (i = 0; i < kTotal; ++i) {
        CHECK(seen[i] == 1,
              "every entry must be served exactly once across the walk");
    }
}

/* The schema caps a page at ten entries. The buffer usually stops it first;
 * when it does not, the schema still must. */
static void test_max_items(void)
{
    enum { kTotal = 16 };
    N68SwRow rows[kTotal];
    char out[kAmpleCap];
    long next = 0;
    int more = 0;
    int i;

    for (i = 0; i < kTotal; ++i) {
        char nm[8];

        sprintf(nm, "A%d", i);
        fill_row(&rows[i], nm, "HD:A", "APPL", "abcd", 1, 0);
    }
    (void)n68_swlist_build(1, "apps", 1, rows, kTotal, 0, NULL, out,
                           (long)sizeof out, &next, &more);
    CHECK(next - 1 == NOW68K_SWLIST_MAX_ROWS,
          "a page stops at the schema's maxItems even when the buffer would "
          "hold more");
    CHECK(more == 1, "and says the rest are still coming");
}

/* ---- the note ------------------------------------------------------------- */

static void test_note_is_all_or_nothing(void)
{
    N68SwRow row;
    char out[kAmpleCap];
    long cap;

    fill_row(&row, "SimpleText", "HD:Applications:SimpleText", "APPL",
             "ttxt", 384, 0);

    /* Squeeze the buffer through the range where the note stops fitting.
     * The page must stay complete JSON throughout: a half-written note
     * truncates the frame mid-string and costs the whole listing, which is
     * a far worse trade than losing a sentence. */
    for (cap = NOW68K_SWLIST_MIN_CAP; cap <= NOW68K_SWLIST_MIN_CAP + 200;
         ++cap) {
        long n = n68_swlist_build(1, "apps", 1, &row, 1, 1,
                                  n68_swlist_note_truncated(), out, cap,
                                  NULL, NULL);
        const char *note_at;

        if (n <= 0) {
            continue;
        }
        CHECK(out[n - 1] == '}', "the object must close");
        note_at = strstr(out, "\"note\":");
        if (note_at != NULL) {
            CHECK(strstr(out, n68_swlist_note_truncated()) != NULL,
                  "a note that appears must appear WHOLE - half a note is a "
                  "frame that stops mid-string");
        }
    }
}

/* ---- MacRoman ------------------------------------------------------------- */

static void test_high_bytes_escape(void)
{
    N68SwRow row;
    char out[kAmpleCap];
    long n;

    memset(&row, 0, sizeof row);
    /* "Ne\xCDo" - an option-character in a file name, which is ordinary on
     * a Mac disk and must not reach a UTF-8 host raw. */
    strcpy(row.name, "Ne");
    row.name[2] = (char)0xCD;
    row.name[3] = 'o';
    strcpy(row.path, "HD:Ne");
    row.path[5] = (char)0xCD;
    row.path[6] = 'o';
    strcpy(row.file_type, "APPL");
    row.size_k = 1;

    n = n68_swlist_build(1, "apps", 1, &row, 1, 0, NULL, out,
                         (long)sizeof out, NULL, NULL);
    CHECK(n > 0, "a name with a high byte must not cost the page");
    CHECK(strchr(out, (char)0xCD) == NULL,
          "no raw high byte may reach the wire");
    CHECK(strstr(out, "\\u") != NULL, "it is escaped instead");
}

/* ---- the `sw` table -------------------------------------------------------- */

static void test_sw_rows(void)
{
    N68SwRow rows[3];
    N68CmdRows table;
    int i;
    int found_more = 0;
    int found_bound = 0;

    fill_row(&rows[0], "SimpleText", "HD:Applications:SimpleText", "APPL",
             "ttxt", 384, 0);
    fill_row(&rows[1], "Sound Manager", "HD:x", "INIT", "sndM", 72, 1);
    fill_row(&rows[2], "Mystery", "HD:y", "", "", -1, 0);

    n68_swlist_rows(kN68SwDomainExtensions, rows, 3, 0, 0, &table);
    CHECK(table.ok == 1, "a listing is a success");
    CHECK(strcmp(table.key, "sw") == 0,
          "the output key the contract's x-command declares");
    CHECK(table.count == 4, "a heading row plus three items");
    CHECK(strcmp(table.rows[0].label, "Domain") == 0,
          "a table that does not say what it is looking at is a table a "
          "person has to guess about");
    CHECK(strcmp(table.rows[0].value, "Control Panels") != 0,
          "the heading must name the domain that was asked for");
    CHECK(strstr(table.rows[1].value, "APPL") != NULL, "type is shown");
    CHECK(strstr(table.rows[1].value, "384 KB") != NULL, "size is shown");
    CHECK(strstr(table.rows[2].value, "(off)") != NULL,
          "a disabled item must SAY it is disabled - it is the one fact a "
          "person reading an Extensions list is looking for");
    CHECK(strstr(table.rows[3].value, "? KB") != NULL,
          "an unreadable size must read as unknown, not as zero");

    /* The two short-answer reasons are separate rows, because they are
     * separate news: page again, versus there is no cursor that reaches
     * the rest. */
    n68_swlist_rows(kN68SwDomainApps, rows, 3, 1, 1, &table);
    for (i = 0; i < table.count; ++i) {
        if (strcmp(table.rows[i].label, "...") == 0) {
            found_more = 1;
        }
        if (strstr(table.rows[i].value, "bound") != NULL) {
            found_bound = 1;
        }
    }
    CHECK(found_more, "a page that ended early must say so");
    CHECK(found_bound,
          "an inventory that stopped at this Mac's bound must say so, and "
          "SEPARATELY - a reader shown only one would draw the wrong "
          "conclusion about the other");
}

static void test_sw_overview(void)
{
    N68SwCount counts[NOW68K_SWLIST_DOMAIN_COUNT];
    N68CmdRows table;
    int i;

    memset(counts, 0, sizeof counts);
    for (i = 0; i < NOW68K_SWLIST_DOMAIN_COUNT; ++i) {
        counts[i].available = 1;
        counts[i].enabled = 10 + i;
    }
    counts[1].disabled = 4;
    counts[0].truncated = 1;
    counts[3].available = 0;      /* no Startup Items folder at all */

    n68_swlist_overview_rows(counts, &table);
    CHECK(table.ok == 1, "the overview is a success");
    CHECK(table.count == NOW68K_SWLIST_DOMAIN_COUNT,
          "one row per domain");
    CHECK(strstr(table.rows[0].value, "10 on") != NULL,
          "the enabled count");
    CHECK(strstr(table.rows[0].value, "bound") != NULL,
          "a count that stopped at the bound must say so - otherwise it "
          "reads as the number of applications on the disk");
    CHECK(strstr(table.rows[1].value, "4 off") != NULL,
          "the disabled sibling's count");
    CHECK(strstr(table.rows[0].value, "off") == NULL
              || strstr(table.rows[0].value, "0 off") == NULL,
          "a domain with no disabled items must not say '0 off'");
    CHECK(strcmp(table.rows[3].value, "(not on this Mac)") == 0,
          "a folder this Mac does not have is not a folder with nothing in "
          "it, and reporting 0 would claim it had one");

    n68_swlist_overview_rows(NULL, &table);
    CHECK(table.ok == 0, "an overview with no counts is a failure, not zeros");
}

static void test_unknown_domain_table(void)
{
    N68CmdRows table;

    n68_swlist_unknown_domain_rows(&table);
    CHECK(table.ok == 0, "a word that is not a domain is a refusal");
    CHECK(strcmp(table.code, "bad-domain") == 0, "with a code");
    CHECK(strcmp(table.text, n68_swlist_note_unknown_domain()) == 0,
          "and the SAME sentence the wire's note carries - a person and a "
          "host must not be told two different stories about one word");
    CHECK(table.count == 0, "a refusal is not also a table");
}

int main(void)
{
    test_domains();
    test_notes_fit();
    test_cursor_split();
    test_shape();
    test_empty_path_is_still_a_path();
    test_unreadable_size();
    test_bounds();
    test_row_is_whole_or_absent();
    test_no_empty_page_with_more();
    test_paging_walk(kAmpleCap);
    test_paging_walk(NOW68K_SWLIST_MIN_CAP);
    test_max_items();
    test_note_is_all_or_nothing();
    test_high_bytes_escape();
    test_sw_rows();
    test_sw_overview();
    test_unknown_domain_table();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
