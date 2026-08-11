/*
 * n68_census.h - what a census probe FOUND, before anyone decides who is
 * reading it. The Toolbox-free half of NOW-68K's hardware census.
 *
 * The same split n68_cmdresult.h makes for a command: a probe fills an
 * N68CensusPage - the facts, no formatting - and this file's two renderers
 * turn that into either a contract `census.report` for the wire or the
 * [label, value] rows the `census` verb shows a person. The Toolbox
 * gatherers live in census68.c, which this header does not name and does
 * not need: everything below compiles under the host cc, and
 * now-guest-68k/tests/test_census.c runs it here.
 *
 * WHY THIS IS NOT now-guest-ppc/src/census/census.h. The two guests share no
 * source - they meet on the wire, and the contract is the thing they hold
 * in common (`x-census`). The PowerPC page is 16 rows of 144 bytes and its
 * serializer is built from snprintf; this one has to fit a 1024-byte
 * control frame on a 4 MB machine with no printf family in the binary. The
 * SHAPE is the contract's and is identical on purpose; the numbers are
 * this machine's.
 *
 * PAGING IS THE PAGE'S JOB, NOT THE PROBE'S.
 *
 * A gatherer calls n68_census_page_add() once per row it can see, from the
 * first row to the last, every time. The page holds the request's cursor
 * and silently drops the rows before it, stores what fits, and counts
 * everything - so `total` is a fact rather than an estimate, and a probe
 * needs no cursor arithmetic of its own. Getting that arithmetic wrong in
 * fourteen places is how a census grows a probe that loops forever on
 * page two.
 *
 * ROWS ARE SANITIZED TO PRINTABLE ASCII AT THE SEAM, in page_add, which is
 * the decision that makes the frame bound below a fact instead of a
 * six-times-worst-case guess. A MacRoman high byte escapes to \uXXXX at six
 * bytes each; at 104 bytes of row that is 624 bytes for one row of a
 * 1024-byte frame, and the pages that would blow up are the two whose text
 * comes from the machine rather than from this build (a volume's name, the
 * model string in Gestalt 'mnam'). A census row is a FACT, not a filename:
 * an accented volume name degrading to a dot costs a diacritic, where the
 * file family's escaper exists because a filename that loses one is a file
 * nobody can open. So: sanitize here, append plainly, and the numbers below
 * are arithmetic.
 */
#ifndef NOW68K_N68_CENSUS_H
#define NOW68K_N68_CENSUS_H

#include "n68_cmdresult.h"

enum {
    /* Sized against NOW68K_CONTROL_SEND_CAP (1024) through the bound at the
     * bottom of this file, not by taste. A row is [name, raw, meaning]: the
     * raw value always survives beside the decoded meaning, because a value
     * this build cannot decode must keep its raw form and say so in the
     * meaning column rather than be dropped. */
    kN68CensusNameCap    = 24,
    kN68CensusRawCap     = 32,
    kN68CensusMeaningCap = 48,
    kN68CensusNoteCap    = 96,
    /* A peer-controlled string echoed back into JSON we transmit. Bounded
     * here and sanitized on the way in, the same way wire68.c already
     * treats every string a peer sends. */
    kN68CensusProbeCap   = 24,
    /* Ten rows of 104 bytes = 1040 bytes of page, one instance, in BSS.
     * More would not reach the wire in one frame anyway (the bound below
     * fits six worst-case rows), and this file is not the place to spend a
     * kilobyte of a 384 KB partition twice over. */
    kN68CensusRowsMax    = 10
};

/* The contract's outcome vocabulary (`x-census/x-outcomes`), verbatim.
 *
 * absent is NEVER a synonym for refused. absent is the MACHINE's answer -
 * no PCI bus here, no ATA Manager on a PowerBook whose disk is SCSI -
 * and it is a finding, rendered as content. refused is THIS BUILD's
 * answer: we did not look. Conflating them is the defect the whole census
 * design exists to prevent, and on this guest it would be an easy one to
 * commit, because most of what a 68030 PowerBook says no to, it says no to
 * honestly. */
typedef enum {
    kN68CensusPresent = 0,
    kN68CensusAbsent,
    kN68CensusPartial,
    kN68CensusRefused,
    kN68CensusFailed,
    kN68CensusNotAttempted
} N68CensusOutcome;

typedef struct {
    char name[kN68CensusNameCap];
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];
} N68CensusRow;

typedef struct {
    N68CensusRow rows[kN68CensusRowsMax];
    int  count;                 /* rows stored in this page */
    long skip;                  /* the request's cursor: rows before it */
    long seen;                  /* rows the probe offered, in total */
    int  overflow;              /* the probe had more than the page holds */
    N68CensusOutcome outcome;
    char note[kN68CensusNoteCap];   /* one human sentence, or empty */
} N68CensusPage;

/* Converts a 32-bit block count to the 32-bit byte value this guest can
 * render, saturating instead of wrapping at the target ABI's ULONG_MAX. */
unsigned long n68_census_block_bytes(unsigned long blocks,
                                     unsigned long block_size);

/* Zeroes the page and arms it for a request that asked to start at
 * `cursor`. A negative cursor is treated as 0 - a peer that sends one is
 * asking for the start, and refusing a whole probe over a sign is worse
 * than answering it. Outcome starts `present`; a gatherer that finds
 * nothing says so by setting one of the other five. */
void n68_census_page_init(N68CensusPage *page, long cursor);

/* Offers one row to the page. ALWAYS call this for every row the probe can
 * see, in order, whatever the cursor is - the page decides what to store.
 *
 * Each field is truncated at its member's capacity and sanitized to
 * printable ASCII (see the header comment). `raw` or `meaning` may be NULL
 * or "" - an empty meaning is how the PowerPC census marks a section
 * caption, and this guest keeps the convention.
 *
 * Returns 1 if the row was stored, 0 if it was skipped (before the cursor)
 * or did not fit (the page records that as overflow and reports `more`). */
int n68_census_page_add(N68CensusPage *page, const char *name,
                         const char *raw, const char *meaning);

/* Sets the outcome and the note in one call, because they are one thought:
 * an outcome that is not `present` and does not say why is the answer this
 * census is trying not to give. `note` may be NULL. */
void n68_census_page_say(N68CensusPage *page, N68CensusOutcome outcome,
                          const char *note);

/* The contract's spelling of an outcome. */
const char *n68_census_outcome_name(N68CensusOutcome outcome);

/*
 * Renders one complete, NUL-terminated `census.report` for the wire,
 * echoing `id` and `probe` per the schema. Returns the bytes written
 * before the terminator - what wire68.c's send path enqueues - or 0 with
 * out[0] = '\0' when even the envelope did not fit.
 *
 * THE PAGE PROPOSES, THIS DECIDES. A page may hold ten rows and a frame
 * may hold six of them; unlike `ps` and `ls`, which truncate and say so,
 * census has a CURSOR, so the rows that do not fit are not lost - `more`
 * is true and `cursor` names the first one left out. A caller that keeps
 * asking gets every row exactly once. That is why the row loop below
 * stops on the buffer rather than on the count, and why the cursor is
 * computed from what was WRITTEN rather than from what was gathered.
 *
 * `total` is emitted whenever the probe counted its rows (it always does -
 * see page_add), and `note` whenever there is one.
 */
long n68_census_report_json(const char *probe, long id,
                             const N68CensusPage *page, char *out, long cap);

/*
 * The same page as the `census` verb's answer: the contract collapses the
 * wire's [name, raw, meaning] triple to [name, meaning] for a text surface
 * ("x-commands/census"), and the raw value folds into the meaning column
 * when a row has no decoded form - so nothing the wire carries is dropped
 * on the way to a person.
 *
 * A page that is empty, not `present`, carries a note, or has more rows
 * behind it gets a trailing `(probe)` row saying so. A console that prints
 * nothing at all cannot be told apart from one whose command silently
 * failed, and `absent` is a finding a person came here to read.
 */
void n68_census_rows(const char *probe, const N68CensusPage *page,
                      N68CmdRows *out);

/* ---- what one report costs on the wire --------------------------------
 *
 * Stated here, once, where both the code that BUILDS a report and the code
 * that SENDS it read it - the 160-vs-512 command.result bug (commands68.h)
 * was two limits disagreeing where only the larger was ever exercised.
 *
 *   head  {"type":"census.report","id":<11>,"probe":"<24>",
 *         "outcome":"not-attempted","rows":[
 *   row   ,["<24>","<32>","<48>"]
 *   tail  ],"more":true,"cursor":<11>,"total":<11>,"note":"<96>"}
 *
 * No 6x anywhere: every string is printable ASCII by the time it is
 * appended (page_add sanitizes, and the probe name is sanitized by the
 * caller in wire68.c before it gets here).
 */
#define NOW68K_CENSUS_HEAD_MAX 128
#define NOW68K_CENSUS_ROW_MAX  120
#define NOW68K_CENSUS_TAIL_MAX 176

/* The smallest buffer that can carry ONE row and still say what it left
 * out. Below this a report would have to choose between a row and the
 * truth about the rest, and it must never have to - the floor
 * NOW68K_PS_MIN_CAP and NOW68K_CMDROWS_MIN_CAP state for their own
 * tables, for the same reason. */
#define NOW68K_CENSUS_MIN_CAP                                              \
    (NOW68K_CENSUS_HEAD_MAX + NOW68K_CENSUS_ROW_MAX + NOW68K_CENSUS_TAIL_MAX)

#endif /* NOW68K_N68_CENSUS_H */
