/*
 * n68_swlist.h - the software.listing serializer and the `sw` table,
 * Toolbox-free.
 *
 * NOW-68K's share of the symmetric software family: "whoever RECEIVES
 * software.list serves its OWN installed software" (contract/asyncapi.yaml,
 * hostBrowsesSoftware). n68_swenum.h reads the disk; this module turns one
 * page of that read into one software.listing, and into the `sw` command's
 * rows. The split is n68_filelist.c's, for n68_filelist.c's reason: the
 * paging arithmetic, the bound, and the never-truncate-a-row rule are the
 * parts that go subtly wrong, and here the host cc can run them.
 *
 * NO CONTRACT CHANGE. SoftwareList and SoftwareListing have been in
 * contract/asyncapi.yaml since revision 1, the host already decodes both,
 * the PowerPC guest already answers them, and `sw` is already in
 * `x-commands`. Checked rather than assumed (AGENTS.md): this direction is
 * additive on this guest alone.
 *
 * ---- What this guest can and cannot answer -----------------------------
 *
 * The contract's SoftwareEntry has eight fields. NOW-68K serves six of
 * them, and the two it omits are omitted rather than guessed:
 *
 *   name, path, type, creator, sizeK, off   - served.
 *   version   - NOT served. The 'vers' resource needs a resource-fork open
 *               per served entry. The contract calls that "an explicitly
 *               bounded cost" and it is - on the 1400c. On a 68030 with 4 MB
 *               and a 384 KB partition it is a resource map per file in a
 *               heap that has no slack, for a field the schema marks
 *               optional and marks ABSENT when there is no readable 'vers'.
 *               So it is absent here, always, and this paragraph is the
 *               honest statement of that rather than a plausible "".
 *   running   - NOT served. The PowerPC guest joins against its process
 *               list by the FSSpec triple; that is a Process Manager walk
 *               per page on a machine where `ps` is already the slowest
 *               thing a person types. Absent, not false: the schema makes
 *               it optional, and `false` would be a claim.
 *
 * A field a guest cannot answer is left out. Sending `"version":""` or
 * `"running":false` would be this guest fabricating two facts per entry,
 * which is the one thing worse than a shorter row.
 *
 * ---- The page is small here, and the path is short ---------------------
 *
 * NOW-68K's outbound payload cap is 1024 bytes (NOW68K_CONTROL_SEND_CAP),
 * sized against a 384 KB partition; the PowerPC guest's frames are 4 KB.
 * The contract caps a page at ten entries and this buffer usually stops it
 * first, exactly as it does for file.listing - that is paging working, and
 * `more`/`cursor` say so.
 *
 * The bound that had to move for it is the PATH. The PowerPC guest carries
 * 224 characters; an HFS path is MacRoman and escapes to six bytes a
 * character, so 224 alone would be 1344 bytes - larger than the whole
 * frame. NOW68K_SWLIST_PATH_MAX is what leaves room for one worst-case row
 * inside the shipping cap, and the arithmetic is below rather than asserted.
 * A path longer than it comes back EMPTY, which is a case the contract
 * already defines: "Empty when the parent chain could not be named honestly
 * (too deep, or the walk failed); such an entry is listed but not
 * launchable from afar." Deep-nested is one of the two reasons it names.
 */
#ifndef NOW68K_N68_SWLIST_H
#define NOW68K_N68_SWLIST_H

#include "n68_cmdresult.h"

/* SoftwareListing.entries has maxItems: 10 in the contract. A page stops
 * there even if the buffer would hold more - the schema is the limit, not
 * our buffer. (In practice the buffer stops it first.) */
#define NOW68K_SWLIST_MAX_ROWS 10

/* The longest full HFS path this guest will put on the wire. See the header
 * comment: past this the path is EMPTY and the entry is honest about not
 * being launchable from afar, rather than truncated into a path that names
 * a different file. */
#define NOW68K_SWLIST_PATH_MAX 80

/* The `note` field's ceiling. Every note this guest sends is one of its own
 * ASCII literals (below), so this is a byte count and not a character count
 * that escapes sixfold. */
#define NOW68K_SWLIST_NOTE_MAX 64

/*
 * THE INVENTORY BOUND, stated once because both halves need it: the wire's
 * apps cache (n68_swenum.c) sizes itself from it, and the note that reports
 * hitting it is rendered here.
 *
 * A whole-volume sweep can find hundreds of applications and this machine
 * cannot hold them. 48 FSSpecs is 3360 bytes of BSS - about 0.9% of the
 * 384 KB partition, and the same order as the ~2.7 KB the browse half
 * already costs. Past 48 the sweep STOPS and the listing says so; it does
 * not quietly return a prefix, which is the failure `ls`'s trailing "..."
 * row exists to prevent one message family over.
 *
 * The folder domains have no cache and therefore no such bound: they are
 * enumerated live by catalog index each request, the way file.list is, so
 * an Extensions folder with 300 items in it pages to the end.
 */
#define NOW68K_SWLIST_APP_CACHE_MAX 48

/* One installed item, in plain C so this file never sees a CInfoPBRec.
 * n68_swenum.c fills these; nothing else does. */
typedef struct {
    char          name[32];       /* HFS leaf, 31 + NUL */
    char          path[NOW68K_SWLIST_PATH_MAX + 1];  /* "" = not nameable */
    char          file_type[5];   /* "APPL"; "" when the catalog gave none */
    char          creator[5];
    long          size_k;         /* data + resource forks in KB; -1 when
                                   * the catalog could not be read */
    unsigned char off;            /* in an Extensions Manager disabled
                                   * folder */
} N68SwRow;

/* The domains the contract's SoftwareList.domain enumerates, plus the two
 * cases a parser needs: no domain at all (the `sw` overview) and a word
 * this machine does not know. */
typedef enum {
    kN68SwDomainNone = 0,       /* absent/empty - the overview */
    kN68SwDomainApps,
    kN68SwDomainExtensions,
    kN68SwDomainCdevs,
    kN68SwDomainStartup,
    kN68SwDomainApple,
    kN68SwDomainUnknown
} N68SwDomain;

/* How many real domains there are, and therefore how long an overview's
 * count array is. Ordered apps, extensions, cdevs, startup, apple - index
 * `d - kN68SwDomainApps`. */
#define NOW68K_SWLIST_DOMAIN_COUNT 5

/* One domain's tally for the overview. `available` is 0 when this machine
 * has no such folder at all, which is a different answer from a folder that
 * is there and empty - and on a System 7.1 machine with no Extensions
 * Manager the disabled siblings are exactly that case. */
typedef struct {
    long enabled;
    long disabled;
    int  truncated;    /* the tally stopped at this guest's bound */
    int  available;
} N68SwCount;

/* The domain named by `word`. NULL or "" is kN68SwDomainNone; anything not
 * in the contract's enum is kN68SwDomainUnknown. Case-sensitive, because
 * the contract's enum is. */
N68SwDomain n68_swlist_domain(const char *word);

/* The contract's own word for `d`, echoed in the listing's `domain`. Always
 * one of this build's ASCII literals - never the host's string - so nothing
 * a host sends can reach the wire unescaped through here. "" for None and
 * Unknown, which never reach a served page. */
const char *n68_swlist_domain_word(N68SwDomain d);

/* The notes this guest sends, as literals so the renderer and the test
 * cannot disagree about their length. All are inside
 * NOW68K_SWLIST_NOTE_MAX, which a static assert and the test both check.
 *
 * The third is the one that says the answer is NARROWER than it looks:
 * PBCatSearch is not available on every System 7.1 volume (it depends on
 * vMAttrib), and the fallback walks the startup volume's ROOT only. An apps
 * listing that swept one folder must never read like one that swept the
 * disk - that is proc68.c's rule for the same fallback under `launch`,
 * applied to the family that reports rather than acts. */
const char *n68_swlist_note_unknown_domain(void);
const char *n68_swlist_note_truncated(void);
const char *n68_swlist_note_root_only(void);

/*
 * Maps a 1-based cursor over a folder domain's [enabled, disabled] pair
 * onto one folder and a 1-based index inside it.
 *
 * A folder domain is TWO catalogs presented as one sequence: the live
 * folder's `enabled_count` items, then the disabled sibling's. The cursor
 * the contract pages by is an index into that concatenation, so the split
 * is arithmetic and belongs here where it can be tested, not beside the
 * File Manager calls where it cannot.
 *
 * Returns 1 and fills index and in_disabled, or 0 when the cursor is past the
 * enabled folder and there is no disabled one to fall into (the caller
 * serves an empty final page - not an error).
 */
int n68_swlist_split_cursor(long cursor, long enabled_count,
                            long *index, int *in_disabled);

/*
 * Builds ONE page of software.listing into out[0, cap).
 *
 * id          - echoed from the request (required by the schema).
 * domain      - the domain word, echoed (required). This build's literal.
 * cursor      - the 1-based inventory index rows[0] was read from.
 * rows        - the entries for this page, in inventory order.
 * row_count   - how many of `rows` are valid.
 * more_beyond - 1 if the enumerator saw at least one entry past `rows`.
 * note        - the honest edge, or NULL. Appended last and dropped WHOLE
 *               if it does not fit, exactly as file.listing drops `root`:
 *               half a note truncates the frame mid-string and costs the
 *               entire page, which is a far worse trade than losing a
 *               sentence.
 * out/cap     - destination; cap must be >= NOW68K_SWLIST_MIN_CAP for a
 *               non-empty page to be possible.
 * next_cursor - OUT, may be NULL. cursor + entries actually emitted.
 * more        - OUT, may be NULL. 1 if entries remain past this page.
 *
 * Returns bytes written before the NUL, or 0 if the page could not be built
 * (cap cannot hold the envelope, or rows remain and not one fits). Both are
 * caller bugs that wire68.c's static assert makes unreachable in the
 * shipping build.
 *
 * A cursor past the end is NOT a failure: it produces a legitimate empty
 * final page with more:false.
 *
 * An entry whose `path` is "" is emitted WITH an empty path rather than
 * without the field. The contract's SoftwareListing requires `path` on
 * every entry and gives empty its own meaning; omitting it would be a
 * schema violation dressed up as brevity.
 */
long n68_swlist_build(long id, const char *domain, long cursor,
                      const N68SwRow *rows, long row_count,
                      int more_beyond, const char *note,
                      char *out, long cap,
                      long *next_cursor, int *more);

/* Worst cases, in bytes, of the three parts of the message. test_swlist.c
 * builds the actual worst case and fails if it grows past these - a bound
 * nobody re-measures is a bound that quietly stopped being one.
 *
 *   head  {"type":"software.listing","id":<11>,"domain":"<10>",
 *         "entries":[                                              =  76
 *   row   ,{"name":"<31 escaped = 186>","path":"<80 escaped = 480>",
 *         "type":"<24>","creator":"<24>","sizeK":<11>,"off":true}   = 790
 *   tail  ],"more":false,"cursor":<11>,"note":"<64>"} + NUL         = 110
 *
 * The row is the one that had to be designed rather than measured: it is
 * what NOW68K_SWLIST_PATH_MAX was solved for, against a 1024-byte frame. */
#define NOW68K_SWLIST_HEAD_MAX  80
#define NOW68K_SWLIST_ROW_MAX  800
#define NOW68K_SWLIST_TAIL_MAX 120

/* The smallest buffer that can carry a page with an entry in it. Anything
 * less and every page is empty-with-more:true, which is an infinite paging
 * loop on the host rather than a small listing. */
#define NOW68K_SWLIST_MIN_CAP                                              \
    (NOW68K_SWLIST_HEAD_MAX + NOW68K_SWLIST_ROW_MAX + NOW68K_SWLIST_TAIL_MAX)

/* ---- the same rows, as the `sw` command -------------------------------- */

/* Describes one item the way a person reads it: type/creator, size in KB,
 * and "(off)" when it is in a disabled folder. `out` is NUL-terminated;
 * cap should be kN68CmdRowValueCap. */
void n68_swlist_describe(const N68SwRow *row, char *out, long cap);

/*
 * Renders the SAME rows as the `sw` command's table - the second renderer
 * over one enumeration (docs/command-parity.md), which is what keeps a
 * person at the PowerBook and a host driving the wire from being told two
 * different stories about one disk.
 *
 * `sw` does NOT paginate: the contract gives command.result no cursor and a
 * console has none to send back. So a domain longer than one page is
 * truncated and the truncation is STATED - the same trailing ["...", ...]
 * row `ls` uses, and for the same reason.
 *
 * `truncated` is the OTHER kind of short answer and gets its own row: the
 * inventory stopped at this guest's bound (NOW68K_SWLIST_APP_CACHE_MAX)
 * rather than at the page. A reader who saw only one of the two would draw
 * the wrong conclusion about the other.
 */
void n68_swlist_rows(N68SwDomain d, const N68SwRow *rows, long row_count,
                     int more_beyond, int truncated, N68CmdRows *out);

/* The overview - `sw` with no domain. One row per domain with its enabled
 * and disabled counts, which is what the contract's x-command describes.
 * counts is NOW68K_SWLIST_DOMAIN_COUNT entries in domain order. */
void n68_swlist_overview_rows(const N68SwCount *counts, N68CmdRows *out);

/* The `sw` failure for a word that is not a domain, rendered into `out`.
 * One place, so the console and the wire refuse the same word with the same
 * sentence. */
void n68_swlist_unknown_domain_rows(N68CmdRows *out);

#endif /* NOW68K_N68_SWLIST_H */
