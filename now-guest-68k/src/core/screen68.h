/*
 * screen68.h - the walk to this Mac's framebuffer, and one band of
 * offscreen at the screen's own depth and colour table.
 *
 * IT WAS vprobe68.c's, AND IT IS STILL ONE WALK. Both things that read
 * this machine's screen - `vprobe`, which measures what reading costs, and
 * `screenshot`, which captures it - need the same three answers: where the
 * framebuffer is, whether it is safe to touch, and how to move a band of
 * it into a port. A second copy of that walk would be a second set of
 * geometry checks to keep honest, and the failure mode of the one that
 * fell behind is a bus error on a 68030, in another room. So the walk
 * moved here when the second caller arrived, unchanged in behaviour - see
 * vprobe68.c, which now calls it and no longer contains it.
 *
 * FAIL-CLOSED IS THE POINT. Everything below n68_vprobe_geometry_ok() is
 * refused rather than guessed at. A PixMap this code walked to might not
 * be a PixMap at all if a system version moved a field, and finding that
 * out by dereferencing is how a machine dies mid-run.
 */
#ifndef NOW68K_SCREEN68_H
#define NOW68K_SCREEN68_H

#include <Quickdraw.h>
#include <QDOffscreen.h>

/* Microseconds(), the trap every timed thing in this tree reads. It lives
 * here rather than in each caller because vprobe and screenshot must be
 * timed by the SAME clock: their numbers are compared against each other
 * (docs/vram-readout-68k.md), and two clocks with different resolutions
 * would make that comparison quietly wrong. Only the low half is used - it
 * wraps every ~71 minutes and no phase in this tree is longer than a few
 * seconds. vprobe68.c carries the full note on why the trap is taken on
 * the documentation rather than gated by a trap-availability check. */
unsigned long screen68_micros(void);

typedef enum {
    kScreen68OK = 0,
    kScreen68NoScreen,    /* no main device / no PixMap to walk to */
    kScreen68Geometry,    /* the PixMap did not check out - refused to read */
    kScreen68Addressing   /* the CPU cannot be made to reach the
                           * framebuffer - see Screen68Reach */
} Screen68Status;

/* ---- 24-BIT ADDRESSING IS THE DEFAULT STATE OF A VINTAGE MAC -------------
 *
 * A 68K Mac's Memory control panel switch for 32-bit addressing is stored
 * in PRAM, and a machine old enough to run this application usually has a
 * dead PRAM battery - so it comes up in 24-BIT MODE every time it is
 * powered on, whatever anybody set last week. In 24-bit mode the top byte
 * of every address is ignored, so the PowerBook 180c's framebuffer at
 * 0xFC080000 is read as 0x00080000: main RAM. A raw walk then returns
 * "memory that was never a screen" at exactly full speed, which is what
 * made this bug so quiet - `vprobe` timed it green while every pixel was
 * wrong (docs/vram-readout-68k.md).
 *
 * CopyBits is immune because QuickDraw resolves addressing itself, which
 * is why the guest's own PICT screenshots were always correct while the
 * wire capture was noise.
 *
 * SwapMMUMode is the era's answer: switch to 32-bit for the read, restore
 * immediately. Requiring a person to visit the Memory control panel is
 * not one - the setting reverts on the next power cycle and the bug reads
 * as a regression.
 *
 * STRIPADDRESS IS A DIFFERENT QUESTION AND IS NOT THE FIX. StripAddress
 * clears the top byte in 24-bit mode, which is right for a pointer derived
 * from a Memory Manager handle (the top byte there is flags, not address)
 * and catastrophically wrong for a framebuffer above 16 MB - stripping
 * 0xFC080000 IS the bug, spelled deliberately. So this file uses
 * StripAddress in exactly two places: as a PREDICATE on the screen's base
 * ("does this address survive 24-bit mode at all?"), and as a
 * normalisation of the offscreen BAND's base, which is heap. It never
 * rewrites the framebuffer address with it. */
typedef enum {
    kScreen68ReachDirect = 0,  /* read it as it is: the machine's own mode
                                * already reaches this address */
    kScreen68ReachSwitch,      /* 32-bit addressing must be switched on
                                * around each read */
    kScreen68ReachRefused      /* no raw read of this framebuffer is
                                * trustworthy on this Mac */
} Screen68Reach;

typedef struct {
    unsigned long base;
    long          row_bytes;
    long          width;
    long          height;
    long          depth;
    long          bytes;
    long          visible_row;   /* bytes of a row that hold pixels */
    Rect          bounds;        /* global, as QuickDraw sees it */
    PixMapHandle  pix;           /* NULL when there is no Color QuickDraw */
    Screen68Reach reach;         /* how a raw read gets to `base` */
} Screen68;

/* How a raw read reaches `base` on THIS Mac, decided from the machine's
 * actual state and never from a build-time assumption:
 *
 *   - 32-bit capable (Gestalt, confirmed by performing the switch once and
 *     checking the low-memory byte moved) -> kScreen68ReachSwitch. This is
 *     returned whether the machine is currently in 24-bit mode or not: the
 *     mode can change under us between this call and the read (the File
 *     Manager runs in between on the capture path, which is the whole
 *     reason `vprobe` looked clean while the capture did not), and a swap
 *     to 32-bit while already in 32-bit is a no-op.
 *   - not 32-bit capable, and the address survives 24 bits -> Direct. A
 *     machine that cannot do 32-bit addressing has its framebuffer inside
 *     the 24-bit space, and nothing needs doing.
 *   - not 32-bit capable, and the address does NOT survive 24 bits ->
 *     Refused. There is no honest read here: the top byte is address, and
 *     this CPU cannot be made to see it. */
Screen68Reach screen68_reach(unsigned long base);

/* The mode the machine is in RIGHT NOW (low memory 0x0CB2). Reported
 * rather than acted on: `reach` is what a reader should branch on, and
 * this is what a person debugging a vintage Mac wants to see, because it
 * is the setting that silently reverts. */
int screen68_mode_is_32bit(void);

/* The sentence for a refusal, or NULL when there is nothing to say. */
const char *screen68_reach_reason(Screen68Reach reach);

/* The 32-bit window. `enter` is a no-op unless `reach` is Switch.
 *
 * NOTHING BETWEEN THEM MAY CALL THE TOOLBOX, THE OS, OR ANY ROUTINE THAT
 * MIGHT. The machine is in an addressing mode the rest of the system was
 * not told about; a Memory Manager call, a File Manager call, or a
 * cross-segment jump that faults in the Segment Loader would all
 * dereference handle-derived addresses whose top byte is flags. That is
 * why the capture brackets ONE ROW COPY rather than the capture, whose
 * body interleaves PackBits with File Manager writes.
 *
 * Exposed as a pair (rather than only the copy below) because `vprobe`
 * times whole read loops that must be measured in one mode, and those
 * loops call nothing at all.
 *
 * INTERRUPTS ARE NOT MASKED, and the window is not always short: the
 * capture's is one row, but vprobe's is a whole timed pass of 150 ms and
 * more. That is judged safe rather than overlooked. A machine that reports
 * itself 32-bit capable has a 32-bit-clean ROM and system software - it is
 * the mode the machine runs in FULL TIME when the Memory control panel
 * says so, which is the state this fix exists to stop depending on. What
 * it does not cover is a third-party 24-bit-only INIT taking an interrupt
 * inside the window, and that machine would already be unable to run with
 * the control panel setting on. Unverified on metal; if a long vprobe pass
 * turns out to be where a machine falls over, the honest next step is to
 * narrow vprobe's window to one row and pay the per-row switch, not to
 * mask interrupts. */
typedef struct {
    /* SIGNED because SwapMMUMode's parameter is. This toolchain's active
     * include set is `universal/CIncludes`, where OSUtils.h declares it
     * `pascal void SwapMMUMode(SInt8 *mode)` as a THREEWORDINLINE
     * (0x1010, 0xA05D, 0x1080 - move.b (a0),d0 / _SwapMMUMode / move.b
     * d0,(a0)). That matters twice: the call is INLINE, so unlike
     * GetMMUMode it needs no glue and links with nothing added; and
     * `multiversal/CIncludes/needs-glue.txt` - which lists both - is
     * describing a different include set than the one this target
     * compiles against. -Wpointer-sign found the mismatch, which is one
     * more entry for CMakeLists' note about -Werror earning its place. */
    signed char   saved;    /* the mode to go back to */
    unsigned char armed;    /* non-zero: `leave` has something to undo */
} Screen68Mode;

void screen68_vram_enter(Screen68Reach reach, Screen68Mode *m);
void screen68_vram_leave(Screen68Mode *m);

/* One copy out of the framebuffer, in whatever mode it takes. Calls no
 * library routine while switched, for the reason above - the loop is
 * written out here rather than handed to memcpy. */
void screen68_vram_read(Screen68Reach reach, void *dst, const void *src,
                        long n);

/* memcmp against the framebuffer, in whatever mode it takes. Non-zero if
 * the `n` bytes are equal. Exists so `vprobe`'s fidelity sweep can compare
 * a screen row against an offscreen band without either calling memcmp
 * inside the 32-bit window or growing a row-sized buffer to copy into. */
int screen68_vram_same(Screen68Reach reach, const void *a, const void *b,
                       long n);

/* Walks to the framebuffer. Two routes, because a caller should say
 * something useful on a machine without Color QuickDraw rather than
 * refuse: the GDevice's PixMap when there is one, and QuickDraw's own
 * screenBits otherwise. Whichever route produced the numbers, they go
 * through n68_vprobe_geometry_ok() before anything is dereferenced.
 *
 * `who` names the caller in the refusal sentence ("vprobe", "screenshot"),
 * so a person reading a one-line error knows which capability declined and
 * on what grounds.
 *
 * It also fills `reach`, and returns kScreen68Addressing when that comes
 * back Refused - a caller gets ONE answer about whether this screen can be
 * read, rather than a base it has to second-guess. */
Screen68Status screen68_info(Screen68 *s, const char *who,
                             char *why, long why_cap);

/* One band of offscreen at the screen's own depth AND colour table. */
typedef struct {
    GWorldPtr    world;
    PixMapHandle pix;
    short        rows;
    long         row_bytes;
    Ptr          base;
} Band68;

/* Opens a `rows`-tall band the width of the screen. Returns 0 if there is
 * no Color QuickDraw or no memory for it; the band is clamped to the
 * screen's height.
 *
 * THE COLOUR TABLE IS NOT A DETAIL. CopyBits between two 8-bit pixmaps
 * with different tables translates indices, which would make vprobe's
 * fidelity comparison fail on a perfectly good copy and would make
 * screenshot record remapped pixels.
 *
 * `base` is StripAddress'd on the way out, which the framebuffer's base
 * deliberately is NOT (see Screen68Reach). The band is a Memory Manager
 * block, so in 24-bit mode its top byte is master-pointer flags rather
 * than address, and a comparison made inside a 32-bit window would follow
 * them somewhere else entirely. In 32-bit mode the call is the identity. */
int screen68_band_open(Band68 *b, const Screen68 *s, short rows);
void screen68_band_close(Band68 *b);

/* Copies rows [top, top + b->rows) of the screen into the band and returns
 * what the CopyBits itself cost, in microseconds. The port swap is outside
 * the timed region on purpose: the number is meant to be comparable with a
 * raw read of the same bytes, not with a whole capture pipeline.
 *
 * The band is the DESTINATION here. screenshot uses the same call with a
 * picture open on the band's port, where CopyBits records instead of
 * blitting and the band's pixels are never written at all - see shot68.c,
 * which is the one place that distinction matters. */
unsigned long screen68_band_copy(Band68 *b, const Screen68 *s, long top);

#endif /* NOW68K_SCREEN68_H */
