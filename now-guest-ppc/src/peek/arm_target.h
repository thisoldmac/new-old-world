/*
 * arm_target.h - resolving ONE process to an A5 that is safe to ARM.
 *
 * Two verbs now hand a resident an A5 and ask it to run inside that
 * process: `qdtrace start` (P3) and `transitions start` (P5). The
 * question they ask is identical, and so is the rule that answers it -
 * peek_oracle.h's, which is stricter for arming than for observing
 * because a Stale anchor names a process that has not pumped its event
 * loop since the plane was armed.
 *
 * It lives here, once, rather than as a static in each caller. Two
 * copies of a safety rule do not fail to build when they drift; they
 * fail to AGREE, and the symptom is a resident armed against a world
 * that has moved.
 */
#ifndef NOW_PEEK_ARM_TARGET_H
#define NOW_PEEK_ARM_TARGET_H

#include <Processes.h>

/* Binds `psn` through the same validated anchor oracle observation uses,
   then applies the stricter arming gate. On success writes the process's
   current A5 and returns 1.

   On failure returns 0 and points `code` and `message` at static strings
   naming WHICH way it failed - the refusal vocabulary is the contract's
   (`anchor-plane-absent`, `not-pumped`, `ambiguous`, `mismatch`,
   `a5-stale`, `unreadable`), and it is returned rather than rendered
   because the two faces render a refusal differently. Neither pointer is
   ever left unset. */
int now_peek_arm_target_a5(const ProcessSerialNumber *psn,
                           unsigned long *a5,
                           const char **code, const char **message);

#endif /* NOW_PEEK_ARM_TARGET_H */
