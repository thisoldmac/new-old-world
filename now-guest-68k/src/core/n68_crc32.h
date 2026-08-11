#ifndef NOW68K_CRC32_H
#define NOW68K_CRC32_H

/*
 * CRC-32 (IEEE, the zlib polynomial 0xEDB88320) for the file family's
 * end-to-end integrity check.
 *
 * SAME FUNCTION, SAME CONVENTION as the PowerPC guest's now_crc32
 * (now/now-guest-ppc/src/files/fileshare.h): seed with 0, feed successive runs of
 * bytes, and the return value is always the finished CRC of everything
 * fed so far. That is not a coincidence to be maintained by care - the
 * host computes one number and both guests must agree with it, so a
 * divergence here would present as "the 68K guest corrupts files" and
 * the bytes on disk would be perfect. now-guest-68k/tests/test_crc32.c pins
 * the two published check values (the standard "123456789" vector and
 * the empty input) plus the composition property, which is the one that
 * actually matters on a wire: a CRC accumulated across N arbitrary
 * splits must equal the CRC of the whole.
 *
 * Table-driven, 256 entries of unsigned long. On a 68030 that is 1 KB of
 * const data against roughly an 8x speedup over the bitwise form, which
 * is the right trade in a 384 KB partition: the bitwise version costs
 * about 8 seconds of a 4 MB transfer on the 180c and this costs about
 * one. The table is built once, lazily, on first use rather than being
 * a const initializer - 256 hand-written constants is 256 chances to
 * transcribe one wrong, and a wrong table is a corruption report about
 * a file that arrived intact.
 *
 * No Toolbox call, no allocation: compiles and runs unchanged under the
 * host cc for its test and under Retro68 68K, the same split
 * json_scan.c and n68_reader.c already use.
 */

/* Feeds `len` bytes into a running CRC. Seed the first call with 0 and
 * pass each result to the next. `bytes` may be NULL only when len is 0. */
unsigned long now68k_crc32(unsigned long crc, const void *bytes, long len);

#endif /* NOW68K_CRC32_H */
