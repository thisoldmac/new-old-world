/*
 * shotstage68.h - the capture, packed, staged on disk so its length is a
 * fact before the first byte goes out.
 *
 * ---- Why staging, when the byte source exists -------------------------
 *
 * shotsrc68.h streams the screen straight down the wire and needs no
 * staging at all - but only as `raw`, 300 KB, because n68_bytesrc.h's
 * first promise is that `total` is exact before the first fill and a
 * PackBits length is not knowable without packing. n68_shotwire.h carries
 * that argument in full: the packed frame is not bounded (~303 KB worst
 * case against a 384 KB partition), and a counting pass followed by an
 * emitting pass would measure a screen that no longer exists.
 *
 * Staging is the third way, and it is the one the measurement made
 * attractive. The 180c's own desktop packs 4.7:1 - 65 KB, not 300 - and
 * that machine wrote 65 KB in ~800 ms. So: pack once, to a file, and the
 * file's size IS the exact length capture.begin has to promise. The
 * packed bytes are then streamed by the file source that already exists
 * and is already tested, and the whole question of predicting a
 * compressed length disappears.
 *
 * n68_bytesrc.h argues against exactly this ("cannot be staged to a
 * temporary file first either - that needs the same bytes on a disk that
 * may not have room, and doubles the slowest part of the job"). That was
 * written before anyone had measured a capture. It is right about 300 KB
 * and wrong about 65 KB, and the disk cost it warns about is ~800 ms
 * against a transfer of the same bytes over a slower wire. The trade is
 * stated here rather than argued away: staging costs one disk round trip
 * and buys a 4.7x smaller transfer.
 *
 * ---- What the file contains -------------------------------------------
 *
 * The bulk stream, verbatim and complete: the palette as RGB triples,
 * then each row PackBits-compressed behind a big-endian u16 length. That
 * is the contract's `packbits` encoding (CaptureBegin.encoding), so the
 * sender streams the file byte for byte and never interprets it. Making
 * the staged file BE the payload rather than an intermediate is what
 * keeps this from becoming a second wire format nobody validated.
 *
 * ---- Memory, and time -------------------------------------------------
 *
 * ~2 KB: one screen row in, one packed row out, one palette. It never
 * holds a band, let alone a frame.
 *
 * It runs in ONE call and does not pump - read, pack and write for the
 * whole screen. On the 180c the read is ~200 ms and the disk write of
 * ~65 KB is ~800 ms; the hand-rolled pack is the unmeasured term and is
 * expected to be slower than QuickDraw's ~480 ms. Budgeted at a few
 * seconds against the host's ~65 s death timer, with the same reasoning
 * shot68.h gives for not pumping mid-capture: an event pumped through the
 * middle can move a window, and half a screen from before the move is a
 * torn capture.
 */
#ifndef NOW68K_SHOTSTAGE68_H
#define NOW68K_SHOTSTAGE68_H

#include "n68_shotdiag.h"
#include "n68_shotwire.h"

typedef enum {
    kShotStage68OK = 0,
    kShotStage68NoScreen,
    kShotStage68Geometry,
    kShotStage68Depth,      /* not 8-bit; this lane will not convert */
    kShotStage68File,       /* create, write or close said no */
    kShotStage68Addressing  /* the CPU cannot reach the framebuffer at all
                             * (screen68.h) - refused rather than sent as
                             * whatever the truncated address pointed at */
} ShotStage68Status;

/* The scratch file's name. Fixed rather than timestamped: there is one
 * capture in flight at a time (the transfer lane is one wide), and a name
 * that accumulates copies on a 4 MB machine is a disk that fills up
 * silently. Recreated from scratch every capture. */
#define kShotStageLeaf "NOW-68K Capture"

typedef struct {
    N68ShotWirePlan plan;      /* geometry; `total` is overwritten below */
    long total;                /* the staged file's exact size - what
                                * capture.begin must promise */
    long raw_bytes;            /* what it would have been unpacked */
    long capture_ms;           /* screen -> RAM, summed over the rows */
    long encode_ms;            /* PackBits, summed over the rows */
    long write_ms;             /* File Manager */
    char leaf[32];             /* kShotStageLeaf, for the file source */
} ShotStage68;

/* Captures the screen, packs it, and writes the whole bulk stream to the
 * scratch file beside the application. Fills `out` on success; on any
 * other status `why` carries the sentence and no file is left behind.
 *
 * Not re-entrant and not free of time - the same guard and the same
 * reasoning as shot68.c. */
ShotStage68Status shotstage68_write(ShotStage68 *out, char *why, long why_cap);

/* The SAME staging, with the addressing facts and a CopyBits second
 * opinion of row 0 recorded on the way past (n68_shotdiag.h says what they
 * settle and why they have to be sampled here rather than by a probe).
 *
 * shotstage68_write() is this function with `diag` NULL, so the capture the
 * diagnostic describes is the capture the wire sends - byte for byte, same
 * code, same order, same file. That is the entire reason it is a parameter
 * on the live path instead of a second routine that "does the same thing":
 * a diagnostic that runs beside the real path rather than inside it can
 * only ever clear the path it is not. */
ShotStage68Status shotstage68_diagnose(ShotStage68 *out, N68ShotDiag *diag,
                                       char *why, long why_cap);

/* Removes the scratch file. Called when a transfer ends, however it ends -
 * a staged capture nobody is sending is 65 KB of a 4 MB disk. */
void shotstage68_discard(void);

#endif /* NOW68K_SHOTSTAGE68_H */
