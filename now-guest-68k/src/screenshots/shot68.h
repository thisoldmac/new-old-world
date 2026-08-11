/*
 * shot68.h - `screenshot` on NOW-68K: the screen, packed, onto this Mac's
 * own desktop.
 *
 * SLICE ONE, AND ONLY SLICE ONE. The contract
 * (contract/asyncapi.yaml, x-commands/screenshot) describes exactly this:
 * the guest captures, encodes a packed PICT and - unless save is false -
 * writes it to its own desktop. No pixels cross the wire; what crosses is
 * the measurement. The bulk-channel transfer is the next contract step and
 * is not here. Nothing in the contract changed to add this command: it was
 * already declared, for both guests, and this is the 68K half arriving.
 *
 * THE BINDING CONSTRAINT IS MEMORY, and it shaped everything below.
 * A 640x480x8 frame is 300 KB. The application partition is 384 KB and the
 * application is already ~142 KB of it. So there is no frame buffer here
 * and no picture handle either.
 *
 * THE KEY FACT, WHICH IS EASY TO MISS: a picture being RECORDED is never
 * drawn. QuickDraw's bottlenecks check the port's picSave and emit an
 * opcode instead of touching pixels, so a CopyBits into a recording port
 * reads the source and writes nothing. The destination port therefore
 * needs no pixels at all - only a coordinate space, a depth and a clip
 * that cover the frame. The Window Manager's colour port is all three,
 * already exists, and costs nothing, so that is the recording port. The
 * picture never accumulates either: the port's putPicProc is replaced, so
 * QuickDraw hands each opcode straight to a 1 KB write buffer as it
 * produces it and the PicHandle stays at its 10-byte header.
 *
 * The capture's whole ceiling is therefore ~21 KB regardless of screen
 * size - 20 KB of it the read-baseline band this shares with vprobe, and
 * about 1 KB the write buffer - and it is a ceiling rather than an
 * estimate: those are the only two allocations on any path.
 *
 * WHY NOT A BANDED RECORDING, which is where this started. Recording the
 * screen a band at a time into a 640x32 offscreen port looks like the
 * obvious way to bound memory, and it is what the first version did. On
 * System 8.1 it killed the application on the THIRD band, every time,
 * while QuickDraw was writing that band's colour table - reproducibly,
 * and independently of the band's geometry, of whether anything was being
 * written to disk, and of the partition size (all three were bisected on
 * the emulator; docs/open-issues.md carries the trace). One recording
 * CopyBits over the whole frame has none of that, costs less, and emits
 * one colour table instead of fifteen. The banding that remains is the
 * READ baseline, which is a measurement and not the capture.
 *
 * WHY putPicProc RATHER THAN A HAND-ROLLED PackBits. The obvious
 * OpenPicture / CopyBits / ClosePicture route accumulates the whole
 * picture in a Handle - the one thing this partition cannot hold.
 * Replacing putPicProc streams it instead, and has a second payoff worth
 * as much as the first: CopyBits does the PackBits compression itself,
 * per row, correctly, on a code path Apple shipped and this project does
 * not have to test. Every piece of it was checked against this
 * toolchain's Universal Interfaces before it was written -
 * QDPutPicProcPtr, CQDProcs, SetStdCProcs, NewQDPutPicUPP and
 * ShieldCursor are all declared in Quickdraw.h for non-Carbon 68K. A
 * hand-rolled banded PackBits was the fallback and was not needed.
 *
 * 8-BIT NATIVE ONLY, AND IT REFUSES RATHER THAN CONVERTS. CopyBits will
 * convert depth for free, but on the PB1400c the RAM-side cost of a
 * non-native path ate the entire capture margin (docs/vram-readout.md). A
 * converted capture is a separate decision nobody has measured, so a
 * screen that is not 8-bit gets an honest refusal and no file.
 *
 * THE CURSOR. Shielded across every pixel read - each read-baseline band
 * and the recording pass - so it can never land in what is captured; a
 * watch cursor for the slow phases, because the seconds are in the
 * packing and the writing and a machine that looks hung for four seconds
 * is a machine someone reboots. Restored on every exit path, including
 * the failures.
 *
 * TIME, AND THE WIRE. Nothing here pumps, and the host declares a guest
 * dead after ~65 s of silence (wire68.c's kWireDeadTicks). The wire is
 * pumped before the capture starts and after it finishes, never inside
 * it: a pumped event can move a window, and a picture recorded across
 * that is a torn one. The worst case is bounded by arithmetic rather than
 * by a timer - see kShotWorstCaseMs in shot68.c.
 */
#ifndef NOW68K_SHOT68_H
#define NOW68K_SHOT68_H

#include "n68_shot.h"

typedef enum {
    kShot68OK = 0,
    kShot68Busy,        /* already running: a pumped request re-entered */
    kShot68NoScreen,    /* no main device / no PixMap to walk to */
    kShot68Geometry,    /* the PixMap did not check out - refused to read */
    kShot68Depth,       /* not an 8-bit screen, and this slice will not convert */
    kShot68NoMemory,    /* no 20 KB for the read band, even from temp mem */
    kShot68Encode,      /* QuickDraw did not record through the put proc */
    kShot68File         /* create / write / close said no */
} Shot68Status;

/* Captures the whole screen at `a->depth` (8 or nothing) and, when
 * a->save, writes it to the desktop. Fills `s` with the measurement on
 * success; on any other status `why` carries the short sentence for the
 * caller's error reply and `s` is left zeroed.
 *
 * NOT free of TIME and not re-entrant, for vprobe68.c's reasons: a second
 * call answers kShot68Busy rather than recording a second picture through
 * the same file-scope put-proc state, which would interleave two pictures
 * into one file. */
Shot68Status shot68_capture(const N68ShotArgs *a, N68ShotStats *s,
                            char *why, long why_cap);

#endif /* NOW68K_SHOT68_H */
