/*
 * n68_vprobe.h - the vprobe row table, its arithmetic and its two
 * renderers, Toolbox-free.
 *
 * vprobe measures what a VRAM read COSTS on this machine, by access
 * method. The measuring half needs a screen, a Microseconds trap and a
 * 68030; everything else - the row vocabulary, the bandwidth arithmetic,
 * the budget scaling that keeps the run from making the guest deaf, the
 * geometry checks that decide whether a base pointer may be dereferenced
 * at all, and both renderings of the result - is plain C and lives here,
 * where the host cc can run it (the n68_proclist.c / n68_reader.c idiom).
 *
 * That split is not tidiness. A bad base pointer BUS-ERRORS a 68030
 * instead of returning garbage, so the code that decides "this pointer is
 * safe to read <bytes> from" is the one piece of vprobe that must be
 * tested rather than watched: on the machine its failure mode is a dead
 * Mac, not a wrong number. n68_vprobe_geometry_ok() is that decision and
 * now-guest-68k/tests/test_vprobe.c is where it is exercised.
 *
 * THE ROW VOCABULARY IS SHARED WITH THE POWERPC GUEST ON PURPOSE.
 * now-guest-ppc/src/census/vprobe.c measures the same shapes on the PB1400c and
 * docs/vram-readout.md records what that run settled. Labels and value
 * formats match wherever the platform allows, because the point of
 * running this on a second machine is to compare the two numbers, and two
 * formats are one transcription error away from a wrong comparison.
 *
 * No Toolbox, no malloc/NewPtr/NewHandle, no printf family (numfmt.h
 * only, matching every other pure unit in this tree).
 */
#ifndef NOW68K_N68_VPROBE_H
#define NOW68K_N68_VPROBE_H

#include "n68_cmdresult.h"

enum {
    /* A row is [label, value] - the contract's x-rowArray shape for every
     * x-command's output (contract/asyncapi.yaml, x-commands.gestalt.
     * x-rowArray). These two caps and kN68VProbeMaxRows are what make the
     * reply's worst case a number a compiler can check; see
     * NOW68K_VPROBE_JSON_MAX below, which is the whole reason they are
     * caps rather than "whatever fits".
     *
     * 18: the longest label this probe emits is "Partial 480 rows" (16).
     * 30: the longest value is "1st 1234.5 / best 1234.5 ms" (27). */
    kN68VProbeLabelCap = 18,
    kN68VProbeValueCap = 30,

    /* Sixteen rows are emitted today (vprobe68.c). One spare, and no
     * more, because every row costs 54 bytes of a reply that CANNOT PAGE:
     * command.result has no cursor in the contract, so the only ways to
     * carry more rows are a bigger frame or fewer rows. An eighteenth row
     * means raising NOW68K_COMMAND_RESULT_CAP and NOW68K_CONTROL_SEND_CAP
     * with it, deliberately - not discovering on metal that the reply
     * vanished. */
    kN68VProbeMaxRows  = 17
};

typedef struct {
    char label[kN68VProbeLabelCap];
    char value[kN68VProbeValueCap];
} N68VProbeRow;

typedef struct {
    N68VProbeRow rows[kN68VProbeMaxRows];
    short        count;
    short        dropped;   /* rows offered after the table filled */
} N68VProbeTable;

/* The worst-case sizes of the three parts of one command.result carrying a
 * full table. Same discipline as n68_proclist.h's three _MAX values: they
 * are not a second statement of the wire's limit, they are what lets a
 * compiler check that the limit is big enough.
 *
 *   head  {"type":"command.result","id":<11>,"ok":true,"output":{"vprobe":[
 *                                                                     = 72
 *   row   ,["<17>","<29>"]                                            = 54
 *   tail  ]}} + NUL                                                   =  4
 *
 * Exact plus slack, and test_vprobe.c builds the actual worst case and
 * fails if it grows past them - a bound nobody re-measures stops being
 * one. Nothing in a row ever needs JSON escaping, because n68_vprobe_add()
 * sanitizes every byte on the way in (below), so the rendered size cannot
 * exceed the stored size the way an escaped MacRoman name can in
 * n68_cmdresult.c. */
#define NOW68K_VPROBE_HEAD_MAX 80
#define NOW68K_VPROBE_ROW_MAX \
    (kN68VProbeLabelCap - 1 + kN68VProbeValueCap - 1 + 8)
#define NOW68K_VPROBE_TAIL_MAX 8

/* The biggest command.result this guest can build. commands68.h
 * static-asserts that NOW68K_COMMAND_RESULT_CAP can hold one, and wire68.c
 * already asserts the outbound slot can hold a full command.result - so
 * the chain from "this table" to "the bytes actually sent" is checked at
 * compile time, end to end. That chain exists because the alternative was
 * already paid for once: a 166-byte reply silently dropped by a 160-byte
 * slot (commands68.h). */
#define NOW68K_VPROBE_JSON_MAX                                             \
    (NOW68K_VPROBE_HEAD_MAX + kN68VProbeMaxRows * NOW68K_VPROBE_ROW_MAX    \
     + NOW68K_VPROBE_TAIL_MAX)

/* ---- the table ----------------------------------------------------------- */

void n68_vprobe_table_init(N68VProbeTable *t);

/* Appends one row, truncating label and value to their caps.
 *
 * Every byte is sanitized on the way in: '"' and '\\' become '\'', and
 * bytes below 0x20, 0x7F and every high-bit byte become '.'. Not
 * decoration - it is what makes NOW68K_VPROBE_ROW_MAX a real bound (an
 * escaped byte costs six), and a high-bit byte inside a JSON string is
 * invalid UTF-8, which a spec-correct host parser rejects for the WHOLE
 * frame. Nothing this probe formats is non-ASCII today; sanitizing anyway
 * means a future row that interpolates, say, a monitor's name cannot
 * quietly become an undecodable page.
 *
 * Returns 1 if the row was stored, 0 if the table was full - and then
 * `dropped` is incremented, so the caller can say so rather than lose it
 * silently. */
int n68_vprobe_add(N68VProbeTable *t, const char *label, const char *value);

/* ---- the arithmetic ------------------------------------------------------ */

/* Formats one bandwidth measurement into `out` the way the PowerPC guest's
 * bw_row() does, plus the one thing that guest never needed: the
 * percentage of a whole frame the pass actually read.
 *
 *   "104.1 ms 8.7 MB/s 100%"
 *
 * The percentage is load-bearing. On a 33 MHz 68030 a full-frame 8-bit
 * pass may not fit the time budget this probe is allowed (see
 * n68_vprobe_scaled_bytes), so a row may be measured over part of the
 * screen. MB/s stays comparable with the PB1400c's numbers either way -
 * the milliseconds do not, and a reader who could not see that a row
 * covered a quarter of the screen would compare it against
 * docs/vram-readout.md's whole one.
 *
 * us == 0 renders "0.0 ms too fast to time": a bandwidth computed from a
 * zero interval is not a large number, it is no measurement, and the one
 * thing a timing row must never do is invent a value the timer could not
 * supply. */
void n68_vprobe_bw_value(char *out, long cap, long bytes, long full_bytes,
                         unsigned long us);

/* Milliseconds with one decimal: 104123 -> "104.1". The probe's whole time
 * vocabulary in one place, so no row invents a second one. */
void n68_vprobe_ms_value(char *out, long cap, unsigned long us);

/* Just the rate: "8.7 MB/s", or "n/a" when there is no measurement. The
 * "Best raw" row prefixes it with the winning method's name and has 29
 * bytes for both, which a full bandwidth value would not leave room for -
 * and that row's job is which-method-won, not how-long-it-took. */
void n68_vprobe_rate_value(char *out, long cap, long bytes, unsigned long us);

/* How many bytes of a pass fit `budget_us`, given that `slice_bytes` took
 * `slice_us`.
 *
 * THIS IS WHAT KEEPS THE GUEST ANSWERING. Nothing inside a read loop pumps
 * the wire, and the host declares a guest dead after ~65 s of silence
 * (wire68.c's kWireDeadTicks). The probe therefore measures a small slice
 * first, predicts the full pass from it, and shortens the pass when the
 * prediction exceeds the per-phase budget - so the longest single stretch
 * of deafness is one budget, whatever the machine turns out to be. The
 * PB1400c ran the whole probe in ~3 s; a 33 MHz 68030 reading VRAM could
 * be an order of magnitude slower, and assuming otherwise is how a
 * measurement becomes a disconnection.
 *
 * Returns a byte count in [align, full_bytes], always a multiple of
 * `align` (the read loops step 32 bytes at a time; a remainder would be
 * read by a different code path and pollute the row). A slice that
 * measured 0 us returns full_bytes - too fast to bound is not a reason to
 * shorten. align <= 0 is treated as 1. */
long n68_vprobe_scaled_bytes(unsigned long slice_us, long slice_bytes,
                             long full_bytes, unsigned long budget_us,
                             long align);

/* What `want_bytes` SHOULD cost if cost is linear in bytes, given that
 * `ref_bytes` cost `ref_us`. The partial-read row prints this beside the
 * measured value: predictive dirty-row reads only pay off if reading N
 * rows costs ~N/height of a full pass, and on the PB1400c they did (60
 * rows, 10.3 ms measured vs 10.4 predicted - docs/vram-readout.md).
 *
 * Returns 0 only when the inputs cannot support a prediction at all
 * (nothing measured, nothing wanted). A true answer too large for 32 bits
 * SATURATES at 0xFFFFFFFF - about 71 minutes - rather than returning 0,
 * because the caller reads a 0 as "no evidence" and reads a huge number as
 * "far past any budget", and for an impossibly slow machine the second is
 * the correct reading. */
unsigned long n68_vprobe_predict_us(unsigned long ref_us, long ref_bytes,
                                    long want_bytes);

/* ---- geometry: the check between this probe and a bus error -------------- */

/* Why a value was refused. A reason rather than a bare 0/1, because
 * "refused to probe" is only useful if it names what looked wrong. */
typedef enum {
    kN68VProbeGeomOK = 0,
    kN68VProbeGeomNoBase,        /* NULL base pointer */
    kN68VProbeGeomOddBase,       /* odd address: a word read address-errors */
    kN68VProbeGeomBadBounds,     /* empty, inverted or absurd rectangle */
    kN68VProbeGeomBadDepth,      /* not a QuickDraw pixel size */
    kN68VProbeGeomShortRow,      /* rowBytes cannot hold one row of pixels */
    kN68VProbeGeomHugeRow,       /* rowBytes past anything a screen has */
    kN68VProbeGeomHugeFrame,     /* more bytes than any framebuffer here */
    kN68VProbeGeomWraps          /* base + bytes wraps the address space */
} N68VProbeGeom;

/* Decides whether `base` may be dereferenced for `row_bytes * height`
 * bytes, and computes that total into `*bytes_out` (0 unless the answer is
 * OK).
 *
 * FAIL-CLOSED, and worth a tested function rather than four ifs at the
 * call site: on a 68030 a wrong base pointer does not return garbage that
 * shows up as a strange row - it takes a bus error and the machine is
 * gone, in another room, mid-run. Every field here comes from a PixMap
 * this code walked to; the checks are what says the walk landed on a
 * PixMap rather than on whatever sits at that offset in a structure that
 * moved between system versions. The house pattern is
 * now-guest-ppc/src/peek/peek_validate.c; this is its 68K sibling with the
 * framebuffer's own invariants added.
 *
 * `base` is an unsigned long rather than a pointer so this function is
 * testable on a host where no such address exists. */
N68VProbeGeom n68_vprobe_geometry_ok(unsigned long base, long row_bytes,
                                     long width, long height, long depth,
                                     long *bytes_out);

/* The short sentence for a refusal, e.g. "rowBytes too small for the
 * screen width". Never NULL. */
const char *n68_vprobe_geom_reason(N68VProbeGeom g);

/* ---- the two renderers --------------------------------------------------- */

/* One complete, NUL-terminated command.result carrying the whole table as
 * output.vprobe. Returns the byte count before the terminator (what
 * wire68.c enqueues), or 0 with out[0] = '\0' if it did not fit - never a
 * partial object, because a control frame that stops mid-JSON decodes to
 * nothing on the host and costs the whole reply rather than one row.
 *
 * `cap` must be at least NOW68K_VPROBE_JSON_MAX for a full table;
 * commands68.h asserts that the buffer it passes is. */
long n68_vprobe_render_json(const N68VProbeTable *t, long id,
                            char *out, long cap);

/* The same table as console text, one row per line, CR-separated (the
 * terminator n68_linesplit.h splits on), labels padded into a column so
 * sixteen rows read as a table on a ~58-column Monaco 9 pane. Returns the
 * byte count, 0 if nothing fit.
 *
 * NOT REACHED BY THE CONSOLE YET, and that is a stated gap rather than an
 * oversight: conwin.c renders a command's result through
 * n68_cmdresult_render_text(), and an N68CmdResult holds at most two rows.
 * Wiring this in is one call in conwin.c's submit_line(); until then the
 * console face of vprobe is the two-row summary below. See the report and
 * docs/command-parity.md - a capability on one face is half a feature. */
long n68_vprobe_render_text(const N68VProbeTable *t, char *out, long cap);

/* The table collapsed to what an N68CmdResult can carry: row 0 is the
 * screen line, row 1 the fastest raw method measured. This is what the
 * console gets today by delegation through now68k_commands_run(), so a
 * person standing at the machine can ask the question and get this
 * machine's headline answer. It reads the SAME table the wire renders -
 * one implementation, two renderers - it is only a smaller window onto
 * it. */
void n68_vprobe_summary(const N68VProbeTable *t, N68CmdResult *res);

/* The labels the summary looks for. Published so vprobe68.c cannot spell
 * them differently from the code that reads them back. */
#define NOW68K_VPROBE_SCREEN_LABEL "Screen"
#define NOW68K_VPROBE_BEST_LABEL   "Best raw"

#endif /* NOW68K_N68_VPROBE_H */
