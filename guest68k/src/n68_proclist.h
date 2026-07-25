/*
 * n68_proclist.h - the process.listing serializer, Toolbox-free.
 *
 * NOW-68K's share of the symmetric process family: "whoever RECEIVES
 * process.list serves its OWN running processes" (contract/asyncapi.yaml,
 * hostBrowsesProcesses). proc68.h already walks the Process Manager; this
 * module turns one snapshot of that walk into one page of process.listing
 * JSON, and it is deliberately split off so the paging arithmetic and the
 * never-truncate-a-row rule can be tested by the host cc with no Macintosh
 * anywhere near them (the connfields.c / n68_reader.c idiom).
 *
 * THE RULE THIS FILE EXISTS TO ENFORCE: a page never truncates mid-row.
 * A control frame that stops mid-JSON decodes to nothing on the host, so
 * a row half-written costs the WHOLE page, not one process - and the host
 * is left waiting on a process.listing the contract promises always comes.
 * So rows go in whole or not at all, and "not at all" means `more` is
 * true and the row starts the next page.
 *
 * THE PAGE SIZE IS NOT A NUMBER. It is whatever fits the caller's buffer,
 * bounded above by the contract's own maxItems. That is on purpose: the
 * one number this guest has to state is the outbound payload cap
 * (NOW68K_CONTROL_SEND_CAP, wire68.h), and deriving the page from it means
 * there is no second constant to disagree with the first. The 160-vs-512
 * command.result bug (commands68.h) was exactly two numbers for one limit;
 * this file declines to add a third.
 *
 * The three _MAX values below are not a second statement of that limit -
 * they are the worst-case sizes of the PARTS, which is what lets a
 * compiler check at build time that a page can always hold at least one
 * row. Without that check a too-small buffer would emit an empty page with
 * more:true forever and the host would page for eternity;
 * n68_proclist_build() refuses at runtime too, but the static assert is
 * what keeps it from ever being reachable.
 */
#ifndef NOW68K_N68_PROCLIST_H
#define NOW68K_N68_PROCLIST_H

/* ProcessListing.processes[].kind (contract enum). "background" is a
 * faceless process, "finder" is that machine's Finder. */
enum {
    kN68ProcKindApplication = 0,
    kN68ProcKindBackground,
    kN68ProcKindFinder
};

/* One row's worth of what the Process Manager knows, in plain C so this
 * file never sees a ProcessSerialNumber or a Str31. proc68.h's
 * proc_list_rows() fills these; nothing else does. name is the HFS limit
 * (31 + NUL) the names come from, code/creator are 4CC text. */
typedef struct {
    char          name[32];
    char          code[5];        /* "APPL"; "" when the process has none */
    char          creator[5];
    unsigned char kind;           /* kN68ProcKind* */
    unsigned char front;          /* the one frontmost process */
    long          size_kb;        /* partition size in KB, never negative */
    unsigned long psn_high;
    unsigned long psn_low;
} N68ProcRow;

/* ProcessListing.processes has maxItems: 24 in the contract. A page stops
 * there even if the buffer would hold more - the schema is the limit, not
 * our buffer. */
#define NOW68K_PROCLIST_MAX_ROWS 24

/* Worst cases, in bytes, of the three parts of the message. Each is the
 * exact count plus a little slack, and test_proclist.c builds the actual
 * worst case and fails if it ever grows past these - a bound nobody
 * re-measures is a bound that quietly stops being one.
 *
 *   head  {"type":"process.listing","id":<11>,"processes":[      = 56
 *   row   ,{"name":"<31>","kind":"application","code":"<4>",
 *          "creator":"<4>","sizeKB":<10>,"front":false,
 *          "psnHigh":<10>,"psnLow":<10>}                         = 170
 *   tail  ],"more":false,"cursor":<10>} + NUL                    = 36
 */
#define NOW68K_PROCLIST_HEAD_MAX 60
#define NOW68K_PROCLIST_ROW_MAX  176
#define NOW68K_PROCLIST_TAIL_MAX 40

/* The smallest buffer that can carry a page with a row in it. Anything
 * less and every page is empty-with-more:true, which is an infinite paging
 * loop rather than a small listing. */
#define NOW68K_PROCLIST_MIN_CAP                                            \
    (NOW68K_PROCLIST_HEAD_MAX + NOW68K_PROCLIST_ROW_MAX                    \
     + NOW68K_PROCLIST_TAIL_MAX)

/* Builds ONE page of process.listing into out[0, cap).
 *
 * id       - echoed from the request (required by the schema).
 * cursor   - 1-based index into `rows` of the first row this page should
 *            carry. A value below 1 (including the absent-cursor case the
 *            caller renders as 0) means "start at the beginning", matching
 *            the PowerPC guest's serve_process_list.
 * rows     - the whole snapshot, oldest-to-newest position as the caller
 *            chose to order it; this file does not reorder.
 * row_count- how many of `rows` are valid.
 * out/cap  - destination. cap must be >= NOW68K_PROCLIST_MIN_CAP for a
 *            non-empty listing to be possible; see that constant.
 * next_cursor - OUT, may be NULL. The cursor a host should send to
 *            continue: cursor + rows emitted. Always written on success.
 * more     - OUT, may be NULL. 1 if rows remain past this page.
 *
 * Returns the number of bytes written before the NUL terminator, or 0 if
 * the page could not be built - which happens when cap cannot hold the
 * envelope, or when rows remain but not one of them fits. Both are
 * caller bugs (the static assert at wire68.c's send site is what makes
 * them unreachable in the shipping build), and both are refusals rather
 * than a short page, because an empty page with more:true would make the
 * host ask again forever.
 *
 * A cursor past the end is NOT a failure: it produces a legitimate empty
 * final page with more:false, which is what a host that raced a shrinking
 * process list should see.
 *
 * Every string that reaches the wire is sanitized on the way in: '"',
 * '\\', control bytes AND every high-bit byte become '?'. The high-bit
 * mapping is not decoration - process names are MacRoman, the host parses
 * this with a UTF-8 JSON decoder, and one option-character in one
 * application's name would otherwise make the whole page undecodable.
 * (proc68.c's append_ascii enforces the same promise for `detail`, for
 * the same reason, one message family over.)
 */
long n68_proclist_build(long id, long cursor,
                        const N68ProcRow *rows, long row_count,
                        char *out, long cap,
                        long *next_cursor, int *more);

#endif /* NOW68K_N68_PROCLIST_H */
