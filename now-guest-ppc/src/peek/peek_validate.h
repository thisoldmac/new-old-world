#ifndef NOW_PEEK_VALIDATE_H
#define NOW_PEEK_VALIDATE_H

/* The pure, host-testable half of the app-side anchor reader
   (peek_read.c). Following a foreign pointer on classic Mac OS is only
   safe because every process shares one address space AND because we
   refuse to dereference anything outside the target process's
   partition - that refusal is the whole safety story, so it lives here
   where it can be tested exhaustively without a Toolbox. No Mac types;
   now-guest-ppc/tests/peek_validate_test.c compiles this under the host cc. */

/* Is the byte range [addr, addr+len) wholly inside the partition
   [loc, loc+size)? Returns 0 for any overflow, zero length, zero base,
   or straddling the end - fail closed. Addresses are unsigned longs
   (32-bit on the target); the checks avoid addr+len wrapping. */
int now_peek_range_in_partition(unsigned long addr, unsigned long len,
                                unsigned long loc, unsigned long size);

/* A plausible on-screen window rectangle: strictly ordered, non-empty,
   and within a generous bound (no classic display exceeds a few
   thousand pixels; a window may poke slightly above the menu bar, so a
   small negative top/left is allowed). Rejects the garbage a
   wrong-offset read would yield. */
int now_peek_rect_sane(short top, short left, short bottom, short right);

#endif /* NOW_PEEK_VALIDATE_H */
