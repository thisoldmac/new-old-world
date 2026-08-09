#ifndef MIRROR_NOWPEEK_H
#define MIRROR_NOWPEEK_H

#include "axshared.h"

/* Mirror's agent, reading NOW's single resident extension.
 * ---------------------------------------------------------------------
 * This machine used to carry four INITs: NOW's own, plus AXPeek, QDPeek
 * and the Portal. Four resident 68K extensions to run one mirror is not
 * a product, and installing them was a set of instructions rather than a
 * step. NOW's extension already publishes the same facts - it was
 * written from these ones - so the agent reads THAT and the other three
 * come off the disk.
 *
 * WHAT THIS FILE IS, PRECISELY. It fills an AXShared - AXPeek's own
 * shape - from NowPeekTable's anchor slots, and nothing downstream
 * changes. The oracle that elects a slot (axoracle.c :: match) is
 * unaltered: it still requires A5 and stack base inside the target's
 * partition, still refutes on CurApName, still refuses when two slots
 * match. That logic was never the part that was AXPeek-specific; only
 * the buffer was.
 *
 * THE TWO REAL DIFFERENCES, both of which this file handles:
 *
 *   1. NOW's anchors capture ONLY WHILE ARMED. AXPeek sampled always.
 *      So the agent must ask, by setting the anchor bit in the table's
 *      arm_request, and keep asking - the extension clears arm_active
 *      when nobody wants it. now_peek_arm() is called before every
 *      snapshot; it is two stores and costs nothing.
 *
 *   2. The seqlock is PER SLOT, not per block. AXPeek published one
 *      `seq` over a 1700-byte buffer and the agent copied the lot under
 *      it. NOW commits each slot with stamp_ticks written last, so a
 *      slot is read on its own and a torn one is skipped rather than
 *      failing the whole read.
 *
 * Nothing here follows a pointer into a foreign heap. The extension
 * publishes addresses; walking them stays where it always was, in the
 * application, behind ax_memory's bounds.
 */

/* Ask the extension to capture anchors, and keep asking. Cheap, and safe
   to call on every request: it writes one bit into one word the
   application half of the contract owns. */
void now_peek_arm(void);

/* Fill `out` from NowPeekTable, in AXShared's shape. Returns the same
   AX_ORACLE_* codes ax_oracle_snapshot returned, so callers do not
   change:

     AX_ORACLE_NOT_FOUND  no NOW Extension is resident
     AX_ORACLE_INVALID    resident, but not a table this build can read
                          (magic, major, or too short), or every slot
                          read came out torn
     AX_ORACLE_OK         `out` holds the anchors as of now

   `system_lo`/`system_hi` bound the system heap for the same reason
   AXPeek's reader took them: the Gestalt answer is an address and is
   range-checked before it is dereferenced. */
int now_peek_snapshot(unsigned long system_lo, unsigned long system_hi,
                      AXShared *out);

#endif /* MIRROR_NOWPEEK_H */
