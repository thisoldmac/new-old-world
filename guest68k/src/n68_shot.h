/*
 * n68_shot.h - everything about `screenshot` that is arithmetic and text.
 *
 * The Toolbox-free half of the capture, split out for the same reason
 * n68_vprobe.h is split out of vprobe68.h: the parts that can be wrong
 * quietly - band arithmetic that leaves a strip of the screen uncaptured,
 * a file name that collides with yesterday's shot, a compression ratio
 * computed the wrong way up - are exactly the parts no one can watch on a
 * machine in another room. They compile and run under the host cc
 * (guest68k/tests/test_shot.c, in scripts/test-native's manifest).
 *
 * No Toolbox, no malloc/NewPtr/NewHandle, no printf family (numfmt.h
 * only), matching every other pure unit in this tree.
 *
 * WHAT THE NUMBERS MEAN, because this slice exists to produce them.
 * `screenshot` writes a PICT to the guest's own desktop; no pixels cross
 * the wire (contract/asyncapi.yaml, x-commands/screenshot). What it
 * returns is the measurement, and the measurement is the reason to build
 * the slice now rather than after:
 *
 *   read_ms     one banded CopyBits pass over the screen with NO picture
 *               open - the pure screen-to-RAM cost, the same thing
 *               vprobe's CopyBits row reports (docs/vram-readout-68k.md).
 *   encode_ms   the recording pass's CopyBits time, minus read_ms, minus
 *               write_ms. QuickDraw fuses the read and the PackBits into
 *               one call, so this number is a DIFFERENCE OF TWO PASSES
 *               and carries both passes' noise. It is still the only
 *               honest way to say what packing costs without hand-rolling
 *               an encoder to measure the encoder.
 *   write_ms    time spent inside the put-pic callback: buffer copies and
 *               FSWrite. Measured directly, not derived.
 *   pict_bytes  what landed on the disk, header included.
 *   ratio       raw_bytes : pict_bytes. THE NUMBER THIS SLICE IS FOR: it
 *               decides whether slice two - the same picture over MacTCP -
 *               is viable at all, and nothing short of a real screen on
 *               real hardware can answer it.
 */
#ifndef NOW68K_N68_SHOT_H
#define NOW68K_N68_SHOT_H

#include "n68_cmdresult.h"

enum {
    /* HFS caps a name at 31 bytes; the contemporary name below is 30. */
    kN68ShotNameCap = 32,

    /* One band of the READ BASELINE. 640 x 32 at 8 bits is 20 KB of
     * offscreen - vprobe's band, deliberately the same number, because the
     * two capabilities' CopyBits costs are compared and a different band
     * size would make that comparison a different measurement. The capture
     * itself is not banded and needs no offscreen at all; shot68.h says
     * why, and why the banded version of it was abandoned. */
    kN68ShotBandRows = 32,

    /* The only depth this slice captures. Not a limitation to route
     * around: CopyBits converts depth for free while a raw path pays
     * RAM-side, and on the PB1400c that asymmetry ate the whole capture
     * margin (docs/vram-readout.md). A non-native path is a separate
     * decision nobody has measured, so this one refuses instead. */
    kN68ShotDepth = 8
};

/* What a capture DID. Filled by shot68.c, rendered by this file. */
typedef struct {
    long width, height, depth;
    long raw_bytes;                    /* visible pixels, unpacked */
    long pict_bytes;                   /* what the file holds, header included */
    long read_ms, encode_ms, write_ms; /* see the header comment */
    char saved_name[kN68ShotNameCap];  /* "" when --no-save */
} N68ShotStats;

/* The console line's flags, parsed guest-side. `--depth N` and `--no-save`
 * (the contract's x-line for this command), and NOTHING ELSE IS AN ERROR:
 * an unrecognised token is ignored rather than refused, because a typo on
 * a console line must not cost someone a capture of a screen that will
 * have moved by the time they retype it. */
typedef struct {
    long depth;      /* kN68ShotDepth unless --depth said otherwise */
    int  save;       /* 0 after --no-save / --save=false */
} N68ShotArgs;

void n68_shot_args_init(N68ShotArgs *a);
void n68_shot_args_parse(const char *line, N68ShotArgs *a);

/* How many bands `height` takes at `rows` per band, and where band `i`
 * starts and how tall it is. The last band is SHORT rather than clipped:
 * 480 splits into fifteen 32-row bands exactly, but nothing guarantees a
 * screen height divides by the band size, and a capture that silently
 * dropped the remainder would produce a picture that looks right until
 * someone screenshots a 400-row display. rows <= 0 is treated as 1. */
long n68_shot_band_count(long height, long rows);
long n68_shot_band_top(long height, long rows, long i);
long n68_shot_band_rows(long height, long rows, long i);

/* The contemporary name, matching the PowerPC guest's byte for byte:
 * "Screenshot 2026-07-19 22.53.01" - 30 characters, which is why there is
 * no " at " in it. `attempt` 0 is that name; any later attempt appends
 * nothing and instead uses `ticks`, because a second shot inside the same
 * second must not silently overwrite the first. Returns the length. */
long n68_shot_name(char *out, long cap, long year, long month, long day,
                   long hour, long minute, long second,
                   unsigned long ticks, long attempt);

/* "3.9:1" - one decimal, rounded, raw over packed. A packed size of zero
 * or larger than raw renders "1.0:1" rather than a number a reader would
 * have to interpret: PackBits can expand incompressible data, and a ratio
 * below one is a real outcome that this string is not the place to
 * explain. Returns the length. */
long n68_shot_ratio(char *out, long cap, long raw_bytes, long packed_bytes);

/* Both faces' rendering of one capture, into the two rows an N68CmdResult
 * holds - which is the whole reason `screenshot` is NOT a fourth
 * row-array dispatch exception (docs/command-parity.md). Row one is what
 * happened and where it went; row two is what it cost. */
void n68_shot_summary(const N68ShotStats *s, N68CmdResult *res);

#endif /* NOW68K_N68_SHOT_H */
