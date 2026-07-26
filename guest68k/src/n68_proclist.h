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
    /* The one row that is NOW-68K itself. It is the only identity a
     * caller can trust for "the process on the other end of this
     * connection": a build's FILE NAME and the version it puts in hello
     * are independent strings, so a name built from the version names
     * the running process only by convention - and on 2026-07-25 the
     * convention had lapsed and a retire step asked this guest to quit a
     * process that did not exist. See n68_proclist.h's header and the
     * contract's isSelf. */
    unsigned char is_self;
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
 *          "psnHigh":<10>,"psnLow":<10>,"isSelf":true}           = 185
 *   tail  ],"more":false,"cursor":<10>} + NUL                    = 36
 */
#define NOW68K_PROCLIST_HEAD_MAX 60
#define NOW68K_PROCLIST_ROW_MAX  192
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

/* ---- the same rows, as the `ps` command -------------------------------- */

/* Worst cases of the `ps` reply's parts, the same way the three above
 * bound process.listing's. test_proclist.c builds the true worst case and
 * fails if it grows past these.
 *
 *   head  {"type":"command.result","id":<11>,"ok":true,"output":{"ps":[  = 68
 *   row   ,["<31>","application, <10> KB, front, self"]                  = 78
 *   note  ,["...","<10> more not shown"]                                 = 36
 *   tail  ]}} + NUL                                                      =  4
 */
#define NOW68K_PS_HEAD_MAX 72
#define NOW68K_PS_ROW_MAX  88
#define NOW68K_PS_NOTE_MAX 40
#define NOW68K_PS_TAIL_MAX  8

/* The smallest buffer that can carry a row AND still say that it dropped
 * the rest. Below this the reply would have to choose between a row and
 * the truth about what it left out, and it must never have to. */
#define NOW68K_PS_MIN_CAP                                                  \
    (NOW68K_PS_HEAD_MAX + NOW68K_PS_ROW_MAX + NOW68K_PS_NOTE_MAX           \
     + NOW68K_PS_TAIL_MAX)

/* Renders the SAME rows as one `ps` command.result into out[0, cap).
 *
 * The second renderer over one implementation (docs/command-parity.md):
 * proc68.c walks the Process Manager once, n68_proclist_build() renders
 * that walk as process.listing for the host's Processes module, this
 * renders it as the contract's [label, value] rows for anyone typing at a
 * console - the host's, which is a dumb shell and reaches this guest only
 * through command.request, or NOW-68K's own, which renders the rows as
 * text instead (conwin.c).
 *
 * id       - echoed from the request.
 * rows     - the snapshot; row_count says how many are valid.
 * out/cap  - destination; cap must be >= NOW68K_PS_MIN_CAP.
 *
 * `ps` does NOT paginate - the contract says so, because a console has no
 * cursor to send back. So a list too long for one control frame is
 * truncated, and truncation is STATED: the last row is ["...", "N more
 * not shown"]. A short list that silently claimed to be the whole machine
 * is the failure mode this row exists to prevent; the Processes module
 * pages the full list.
 *
 * Returns the bytes written before the NUL, or 0 if cap cannot hold even
 * the envelope. Names are sanitized exactly as process.listing sanitizes
 * them, and for the same reason.
 */
long n68_proclist_render_ps(long id, const N68ProcRow *rows, long row_count,
                            char *out, long cap);

#endif /* NOW68K_N68_PROCLIST_H */
