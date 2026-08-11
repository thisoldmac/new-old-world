/*
 * n68_shotwire.h - the capture transfer's arithmetic and envelopes, with
 * no Toolbox in them.
 *
 * Slice two: the pixels reach the host. Slice one put a packed PICT on the
 * guest's own desktop and returned the measurement (shot68.h); this is the
 * lane the same screen goes down.
 *
 * ---- PICT IS NOT THE WIRE FORMAT, and that is already decided ----------
 *
 * contract/asyncapi.yaml (CaptureBegin.encoding) says it in as many words:
 * "NOT PICT: modern macOS cannot decode QuickDraw pictures, so the wire
 * uses a format both sides own (PICT remains the guest's on-disk format)."
 * So none of shot68.c's picture machinery is on this path. The wire format
 * is rows, top to bottom, optionally PackBits-compressed per row with a
 * big-endian u16 length prefix, preceded by the palette as RGB triples for
 * indexed depths - and the host already decodes exactly that, because the
 * PowerPC guest already sends it (now-guest-ppc/src/screenshots/pixels.h). Matching it byte for
 * byte is the whole reason this file quotes that header rather than
 * inventing a layout.
 *
 * `bytes` in capture.begin is the WHOLE bulk stream, palette included.
 * That is not what the contract's one-line description ("rowBytes *
 * height") suggests, and it is what the PowerPC guest actually sends
 * (`owned.total_bytes` is `GetHandleSize` of the palette block plus the
 * rows). The host is the thing that has to agree, and the host agrees with
 * the sender that exists.
 *
 * ---- RAW, AND WHY NOT PACKBITS YET ------------------------------------
 *
 * This first rung sends `raw`, and the reason is a hard constraint rather
 * than a shortcut. n68_bytesrc.h's first promise is that `total` is EXACT
 * AND KNOWN BEFORE THE FIRST FILL, because capture.begin must carry the
 * byte count and the receiver sizes its staging from it. For raw that is
 * arithmetic: rowBytes * height + palette, known from the PixMap. For
 * PackBits it is not knowable without packing, and this machine cannot
 * hold a packed frame to measure it:
 *
 *   - the whole packed frame is not bounded. The 180c's own desktop packs
 *     4.7:1 (65.6 KB), but PackBits EXPANDS incompressible data, so the
 *     worst case is ~303 KB against a 384 KB partition - it does not fit,
 *     and "usually fits" is not a memory budget;
 *   - a counting pass followed by an emitting pass would give an exact
 *     number for a screen that no longer exists. The two passes read the
 *     display at different moments, so their lengths can differ, and
 *     capture.begin would then be a lie the receiver sizes its buffer
 *     from. That is worse than sending more bytes.
 *
 * So packbits over this lane needs either a staged copy (a temporary file,
 * whose size IS exact - the disk write measured ~800 ms for 65 KB on the
 * 180c) or a contract that can carry a transfer of unknown length. Both
 * are decisions, not code, and neither is taken here. What is taken here
 * is the rung that needs no argument: raw, exact, incremental.
 *
 * The cost of that choice is honest and worth stating where it will be
 * read: raw is 300 KB where packed would be ~65 KB on a quiet screen.
 *
 * No Toolbox, no allocation, no printf family (numfmt.h only) - so this
 * compiles and runs under the host cc, and now-guest-68k/tests/test_shotwire.c
 * does exactly that.
 */
#ifndef NOW68K_N68_SHOTWIRE_H
#define NOW68K_N68_SHOTWIRE_H

enum {
    /* An indexed screen sends its own CLUT so the host needs no hardcoded
     * table - RGB triples, one byte per component, 256 entries at 8-bit.
     * The PowerPC guest's `palette_bytes`, same layout. */
    kN68ShotWirePaletteEntries = 256,
    kN68ShotWirePaletteBytes   = kN68ShotWirePaletteEntries * 3,

    /* capture.begin with every field this guest sends. Sized to the same
     * 1024-byte control slot every other reply uses; the assert lives with
     * the caller that owns that buffer. */
    kN68ShotWireJsonCap = 320
};

/* The shape of one capture on the wire. Filled before a byte is produced,
 * because every number in it goes out in capture.begin first. */
typedef struct {
    long width, height, depth;
    long row_bytes;       /* what THIS stream sends per row - see below */
    long palette_bytes;   /* 0 for direct colour */
    long total;           /* palette + rows: what capture.begin promises */
} N68ShotWirePlan;

/* Plans a raw transfer of a `width` x `height` screen at `depth`.
 *
 * row_bytes is the VISIBLE row, not the screen's rowBytes. A framebuffer
 * pads its rows (the Quadra 800's 640-pixel screen has rowBytes 1024; the
 * 180c's has 640), and that padding is neither pixels nor the host's
 * business. Declaring the visible row means the receiver reads exactly
 * what it draws, with nothing to crop and 384 bytes a row not sent.
 *
 * Returns 0 and leaves `plan` zeroed if the geometry is not one this lane
 * can send (non-positive, or a depth other than 8 - see shot68.h for why
 * 8-bit is the only depth this project has measured). */
int n68_shotwire_plan(long width, long height, long depth,
                      N68ShotWirePlan *plan);

/* Where byte `offset` of the bulk stream comes from. `row` is -1 while the
 * offset is still inside the palette, and `column` is then the offset into
 * the palette block. Past the end, returns 0 and leaves both -1.
 *
 * A tested function rather than two divisions at the call site because the
 * source fills in bands and this is the arithmetic that says which row a
 * resumed fill continues from. Off by one row here sends a picture that is
 * plausible and sheared. */
int n68_shotwire_locate(const N68ShotWirePlan *plan, long offset,
                        long *row, long *column);

/* capture.begin, exactly as now-guest-ppc/src/core/wire.c builds it, for the fields
 * this guest has. `packed` selects the encoding word.
 *
 * THE ENCODING IS A PARAMETER BECAUSE IT WAS ONCE A LITERAL, and the
 * literal was wrong. This file was written for the streaming rung, which
 * sends raw, and hardcoded "raw"; the staged rung then reused it to
 * announce PackBits rows. Every native test passed - they only ever
 * exercised the raw plan - and the guest sent a perfectly correct 137,794
 * bytes of packed pixels under a word that told the host to read 307,968
 * bytes of unpacked ones. Only a real receiver could notice, and one did,
 * on the first transfer that crossed. Returns the length written, or 0. */
long n68_shotwire_begin_json(const N68ShotWirePlan *plan, long id,
                             unsigned int transfer, long capture_ms,
                             long encode_ms, int packed, char *out, long cap);

/* ---- the walk that produces the bulk body -------------------------------
 *
 * WHY THIS IS HERE AND NOT IN shotstage68.c, WHICH IS WHERE IT LIVED.
 * The framebuffer walk - `base + row * the screen's OWN rowBytes`, copying
 * only the visible row - was the one part of the capture lane that no test
 * could reach, because it sat between an FSSpec and a ShieldCursor. That
 * mattered more than it looks: `vprobe` reads the same framebuffer and is
 * the only other thing that touches it, and vprobe only TIMES the read. A
 * walk that reads the wrong bytes reads them at exactly full speed, so
 * nothing in this tree would have said a word about it.
 *
 * So the walk moved here, where the host cc can drive it over a synthetic
 * framebuffer with poisoned padding (now-guest-68k/tests/test_shotemit.c),
 * and the Toolbox stayed in shotstage68.c behind the hooks below. The
 * hooks exist for the things the walk must not know about: hiding the
 * cursor over the row being read, timing, and - since the 24-bit
 * addressing fix - the act of touching the framebuffer at all.
 *
 * WHY `row_copy` IS A HOOK AND NOT A memcpy HERE. On a 68K Mac in 24-bit
 * addressing (the default state of a machine whose PRAM battery is dead,
 * which is most of them) the framebuffer's address does not resolve, and
 * the read has to be bracketed by SwapMMUMode - a Toolbox call, which
 * cannot live in this file without costing it the property the file exists
 * for. The split that keeps both: the ARITHMETIC stays here, where the
 * host cc drives it over a synthetic framebuffer with poisoned padding;
 * the act of DEREFERENCING that address goes out through a hook, because
 * it is the only part that depends on which machine this is. Chosen over
 * passing a mode flag down (which puts the Toolbox back in this file) and
 * over hoisting the walk into shotstage68.c (which is where it was,
 * untestable, and is what the previous pass fixed).
 */
typedef struct {
    void *ctx;

    /* Finished wire bytes. Called for the palette once and then twice per
     * row (the length prefix, then the packed row), because a sink that
     * buffers wants them separately anyway. */
    void (*put)(void *ctx, const void *bytes, long n);

    /* THE READ ITSELF: `n` bytes out of the framebuffer at `src` into
     * `dst`. REQUIRED - a NULL here is refused rather than quietly filled
     * in with memcpy, because on the machine this was written for memcpy
     * is precisely the wrong answer and a caller that forgot would send a
     * frame of main RAM at full speed with every test green. Fail-closed
     * costs the host test one three-line shim and the guest nothing. */
    void (*row_copy)(void *ctx, void *dst, const void *src, long n);

    /* Around the framebuffer read of `row`, and after that row is packed.
     * Any may be NULL. `row_begin`/`row_read` bracket the read ALONE - a
     * shield held across the packing would take the cursor away from the
     * person at the machine for the whole capture. */
    void (*row_begin)(void *ctx, long row);
    void (*row_read)(void *ctx, long row);
    void (*row_packed)(void *ctx, long row);

    /* Non-zero abandons the walk (a write error, on the caller that has a
     * disk). May be NULL. */
    int (*stop)(void *ctx);

    /* The caller's scratch: one screen row, and one packed row at the
     * PackBits bound. Passed in rather than owned because this file has no
     * BSS and the 68K guest budgets its statics in one place. */
    unsigned char *row_buf;
    long           row_cap;
    unsigned char *pack_buf;
    long           pack_cap;
} N68ShotWireSink;

/* Emits the palette and then every row of the framebuffer at `base`,
 * PackBits-packed with a big-endian u16 length prefix - the body the host
 * decodes (CaptureDecoder.decodeRows).
 *
 * `fb_row_bytes` is the SCREEN's rowBytes, padding included; what is read
 * out of each row is `plan->row_bytes`, the visible part. On the 180c the
 * two are both 640 and a confusion between them is invisible; on a Quadra
 * 800 they are 1024 and 640, and the confusion shears every capture. The
 * test drives both.
 *
 * Returns the number of bytes handed to `put`, or -1 if it refused: a
 * scratch buffer too small for the row or its PackBits bound, a stride
 * narrower than the visible row, a palette that is not the length the plan
 * promised, no `row_copy`, or `stop` asking it to give up. Nothing is
 * emitted after a refusal, but bytes already emitted stay emitted - the
 * caller discards. */
long n68_shotwire_emit(const N68ShotWirePlan *plan,
                       const unsigned char *base, long fb_row_bytes,
                       const unsigned char *palette, long palette_bytes,
                       const N68ShotWireSink *sink);

/* capture.end. `ok` false is the contract's way to close a transfer that
 * failed after it was announced - the receiver is already staging bytes
 * for this id and needs to be told to stop, which is why this envelope
 * exists at all. Returns the length written, or 0. */
long n68_shotwire_end_json(long id, unsigned int transfer, int ok,
                           char *out, long cap);

#endif /* NOW68K_N68_SHOTWIRE_H */
