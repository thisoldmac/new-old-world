/*
 * n68_packbits.h - PackBits, one row at a time, by hand.
 *
 * ---- Why this exists when QuickDraw already packs ---------------------
 *
 * shot68.c gets its compression free: CopyBits into an open picture emits
 * PackBits-compressed rows on a code path Apple shipped. That is the right
 * answer for the DISK format and the wrong one for the wire, twice over.
 * The wire is not PICT (contract: "NOT PICT: modern macOS cannot decode
 * QuickDraw pictures"), and the picture path is one CopyBits that runs to
 * completion and cannot be asked how long its output will be until it has
 * produced all of it.
 *
 * The capture transfer needs the packed length BEFORE the first byte goes
 * out - capture.begin carries it and the receiver sizes its staging from
 * it - so the packing has to happen somewhere this code can measure. That
 * means owning the encoder. It is thirty lines and it has an independent
 * oracle (Apple's own published vector, in the test), which is the only
 * reason hand-rolling a compression format is defensible at all.
 *
 * ---- The format, which is not negotiable ------------------------------
 *
 * A control byte, then data, repeated:
 *
 *   0..127    the next (n + 1) bytes are literal
 *   129..255  the next single byte repeats (257 - n) times
 *   128       reserved, never emitted
 *
 * The contract's `packbits` encoding is this, per row, each row prefixed
 * with a big-endian u16 packed length (contract/asyncapi.yaml,
 * CaptureBegin.encoding). The prefix is not part of what this file
 * produces - the caller writes it - because this file compresses bytes and
 * knows nothing about rows.
 *
 * ---- IT CAN GROW, and the caller must have room ----------------------
 *
 * PackBits expands incompressible data: worst case one control byte per
 * 128 literal bytes. n68_packbits_max() is that bound and it is the size a
 * caller's buffer must be, not a size anyone should expect. A 640-byte row
 * of pure noise packs to 645 bytes. This is the same fact that stops the
 * capture transfer from predicting a whole frame's packed length without
 * packing it (n68_shotwire.h).
 *
 * No Toolbox, no allocation, no printf family - host cc and Retro68 alike.
 */
#ifndef NOW68K_N68_PACKBITS_H
#define NOW68K_N68_PACKBITS_H

/* The most PackBits can produce from `len` input bytes: every 128 bytes
 * costs a control byte, and a trailing partial run costs one more. A
 * caller sizes its destination with this and never with `len`. */
long n68_packbits_max(long len);

/* Packs `len` bytes from `src` into `dst`, which must hold at least
 * n68_packbits_max(len) bytes. Returns the packed length, or -1 if `cap`
 * was too small (nothing is written in that case) or the arguments make no
 * sense. len == 0 returns 0.
 *
 * Deterministic: the same input always produces the same bytes, which is
 * what lets a staged copy's length be trusted as the length that will be
 * sent. */
long n68_packbits_row(const unsigned char *src, long len,
                      unsigned char *dst, long cap);

/* Unpacks `len` bytes from `src` into `dst`. Returns the unpacked length,
 * or -1 on a malformed stream or a destination too small.
 *
 * HERE FOR THE TEST, and named as such rather than hidden: the guest never
 * unpacks anything. It exists so the encoder can be checked against a
 * round trip IN ADDITION to Apple's published vector - a test that only
 * round-trips its own encoder tests one half twice (AGENTS.md), so the
 * vector is the real check and this is the supporting one. */
long n68_packbits_unrow(const unsigned char *src, long len,
                        unsigned char *dst, long cap);

#endif /* NOW68K_N68_PACKBITS_H */
