/*
 * n68_shotdiag.h - the facts a single metal pass needs to settle where a
 * garbled capture went wrong, and the one renderer that turns them into
 * rows.
 *
 * ---- Why this exists --------------------------------------------------
 *
 * A capture taken on the PowerBook 180c saves correctly to that machine's
 * own Desktop and arrives at the host as structured noise - banded at a
 * plausible stride, looking like memory that was never a screen. The same
 * lane crosses byte-accurately on the Quadra 800 emulator, so the fault is
 * that machine's, and that machine is in another room.
 *
 * Two hypotheses survive, and ONE OBSERVATION SEPARATES THEM:
 *
 *   - the walk read the wrong memory. Then the first bytes of row 0 as the
 *     walk sees them differ from the same row as CopyBits copies it, and
 *     `base`, `StripAddress(base)` and the MMU mode say why.
 *   - the walk read the screen and something downstream damaged it. Then
 *     those two samples are IDENTICAL and every byte of this table is
 *     boring, which is the useful answer: it retires the whole upper half
 *     of the pipeline in one pass.
 *
 * IT RAN, AND IT ANSWERED. On 2026-07-28 the 180c reported `Addressing
 * 24-bit (!)`, `Base 0xFC080000`, `StripAddress 0x00080000`, `Walk` and
 * `Walk again` identical (so the screen held still), `Blit row 0` all
 * zeroes, and `DIFFERS at byte 0 - wrong memory`. The machine was in
 * 24-BIT ADDRESSING, so the top byte of that base was thrown away and
 * every raw read went to main RAM. Confirmed by remedy: 32-bit addressing
 * switched on in the Memory control panel, and captures crossed correctly.
 *
 * The fix is in core/screen68.c - the raw read is bracketed by
 * SwapMMUMode, so the mode the machine happens to boot in no longer
 * changes what a capture contains. A dead PRAM battery makes 24-bit the
 * state most of these machines come up in, so this table's `Addressing`
 * row is now a fact rather than a fault and the `Raw read` row beside it
 * is what says whether it mattered.
 *
 * WHY vprobe'S CLEAN SWEEP MISLED, corrected. It was read as "vprobe is
 * clean and the capture is not, so the difference is the file the capture
 * opens first". It was not: vprobe was measured in an earlier session
 * when the machine happened to be in 32-bit mode, and when it was re-run
 * beside this diagnostic it reported 480/480 rows DIFFERING - broken in
 * exactly the same way. Two runs of the same probe on the same machine
 * are not comparable unless the addressing mode is recorded beside them,
 * which is why `vprobe` now carries an Addressing row of its own.
 *
 * ---- Why three samples and not two ------------------------------------
 *
 * The staged walk and the CopyBits comparison cannot happen at the same
 * instant: the walk is the whole screen and takes seconds on this machine.
 * A bare walk-vs-blit disagreement would therefore be ambiguous - the base
 * could be wrong, or somebody could have moved a window. So the walk is
 * sampled twice: once during the capture (`walk`), and once again beside
 * the blit (`walk_again`), with nothing pumped in between the second pair.
 * `walk_again` vs `blit` answers "is the base right"; `walk` vs
 * `walk_again` answers "did the screen hold still", which is what makes
 * the first answer worth quoting.
 *
 * STATIC BUDGET: none. No BSS, no allocation, no Toolbox, no printf family
 * - so it compiles under the host cc and now-guest-68k/tests/test_shotdiag.c
 * runs it here.
 */
#ifndef NOW68K_N68_SHOTDIAG_H
#define NOW68K_N68_SHOTDIAG_H

#include "n68_cmdresult.h"

/* What screen68.h's Screen68Reach values mean, spelled here as plain ints
 * so this file needs no Toolbox header. The two enums are pinned to each
 * other by a static assert in n68_shotdiag.c's Toolbox-side caller. */
enum {
    kN68ShotDiagReachDirect = 0,
    kN68ShotDiagReachSwitch = 1,
    kN68ShotDiagReachRefused = 2
};

enum {
    /* Sixteen bytes, rendered as "FF FF ... FF" = 47 characters, which is
     * exactly what kN68CmdRowValueCap (48, one of them the NUL) holds. A
     * seventeenth byte would be silently truncated by n68_cmdrows_add and
     * the row would still look complete, so the two numbers are pinned
     * against each other in test_shotdiag.c rather than left to agree by
     * coincidence. */
    kN68ShotDiagSampleBytes = 16
};

typedef struct {
    /* Where the walk was told the screen is, and what the machine thinks
     * of that address at the moment the walk runs. */
    unsigned long base;          /* screen68_info()'s baseAddr */
    unsigned long stripped;      /* StripAddress(base), same instant */
    int           mmu32;         /* LMGetMMU32Bit(): non-zero = 32-bit */
    /* Screen68Reach as an int, so this header stays Toolbox-free and the
     * host cc can build the renderer. What the walk DID about the mode is
     * a different fact from what the mode was, and reporting only the
     * second is what made the first metal pass ambiguous: after the fix a
     * 24-bit machine is expected, and "24-bit, read through a 32-bit
     * switch" is a pass rather than the finding it used to be. */
    int           reach;

    /* The geometry the walk used. fb_row_bytes is the screen's own stride;
     * row_bytes is the visible part the host was promised, and the two are
     * different numbers on purpose (n68_shotwire.h). */
    long width;
    long height;
    long depth;
    long fb_row_bytes;
    long row_bytes;

    /* What the staged capture actually wrote, so a reader can tell a
     * diagnostic run apart from a refusal at a glance. */
    long staged_bytes;

    int  walk_ok;       /* `walk` was sampled during the staged walk */
    int  pair_ok;       /* `walk_again` and `blit` were sampled together */
    unsigned char walk[kN68ShotDiagSampleBytes];
    unsigned char walk_again[kN68ShotDiagSampleBytes];
    unsigned char blit[kN68ShotDiagSampleBytes];
} N68ShotDiag;

/* Zeroes every field. Call before filling; a field left unset must read as
 * "not sampled" rather than as a plausible zero. */
void n68_shotdiag_init(N68ShotDiag *d);

/* "FF 00 A3 ..." for `n` bytes, NUL-terminated, into `cap` bytes.
 * Truncates at the buffer rather than overrunning it, and returns the
 * number of bytes written before the terminator. */
long n68_shotdiag_hex(const unsigned char *bytes, long n,
                      char *out, long cap);

/* The verdict sentence, which is the row a person reads first. Written
 * into `out` and NUL-terminated; never longer than kN68CmdRowValueCap - 1.
 *
 * It is a SENTENCE and not a code because the useful outcomes here are not
 * pass/fail: "identical" retires half the pipeline, "differs" names the
 * next place to look, and "the screen moved" says the run proved nothing
 * and should be repeated on a still screen. A caller that collapsed those
 * to a boolean would throw away the third one, which is the one that
 * wastes a trip to the other room. */
long n68_shotdiag_verdict(const N68ShotDiag *d, char *out, long cap);

/* Renders the whole table into `rows`, which the caller has already
 * initialised. One implementation behind both faces: commands68.c hands
 * this to the wire's row-array renderer and to the console's, exactly as
 * `ls` is handled (docs/command-parity.md). */
void n68_shotdiag_rows(const N68ShotDiag *d, N68CmdRows *rows);

#endif /* NOW68K_N68_SHOTDIAG_H */
