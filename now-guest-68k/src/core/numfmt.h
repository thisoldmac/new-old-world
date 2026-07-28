#ifndef NOW68K_NUMFMT_H
#define NOW68K_NUMFMT_H

/* Bounded, allocation-free append helpers for hand-built JSON, used by
 * ping.c and hello.c in place of snprintf's %ld/%s.
 *
 * Why: these payloads interpolate integers and strings only, never a
 * float, but newlib's ordinary vfprintf (what snprintf calls) is one
 * monolithic implementation -- referencing it at all links
 * _dtoa_r/_svfprintf_r and the __mprec tables regardless of which
 * conversions a given call site actually uses. Measured at roughly 41 KB
 * pulled into a 384 KB application partition for float formatting this
 * deliverable never performs. Hand-rolling the two integer
 * interpolations avoids the dependency outright, on host and target
 * alike (the host's libc does not even provide newlib's integer-only
 * sniprintf/siprintf, so hand-rolling is also the portable choice here).
 *
 * Each function appends into buf[*pos, cap) and advances *pos on
 * success. On failure (would not fit) it returns 0 and leaves *pos
 * unspecified -- callers must stop building on a 0 return rather than
 * keep appending.
 */

/* Appends the decimal text of `value` (sign included if negative).
 * Returns 1 on success, 0 if it would not fit in cap - *pos bytes. */
int now68k_fmt_append_long(char *buf, long cap, long *pos, long value);

/* Appends `s` verbatim, unquoted. Returns 1 on success, 0 if it would
 * not fit in cap - *pos bytes. */
int now68k_fmt_append_str(char *buf, long cap, long *pos, const char *s);

/* Appends the decimal text of an UNSIGNED 32-bit value.
 *
 * Not a convenience over append_long: `long` is 32 bits signed on this
 * toolchain, so a CRC-32 above 0x7FFFFFFF - half of them - comes out
 * NEGATIVE through append_long. The contract types crc32 as an integer
 * and the host reads it as one, so a negative number there is a checksum
 * mismatch on a file that arrived perfectly. The low 32 bits are used
 * whatever the host's `unsigned long` happens to be, so this behaves the
 * same under the 64-bit host cc that runs the native test. */
int now68k_fmt_append_u32(char *buf, long cap, long *pos,
                           unsigned long value);

#endif
