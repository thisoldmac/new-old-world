/*
 * transitions_cmd.h - P5's reader, as both faces reach it.
 *
 * Everything above the line is FACTS and everything below it is one
 * renderer. The Console page renders the same facts as text in
 * console_model.c, so the two faces format differently and decide
 * nothing (docs/command-parity.md). `mirror` is the existing example of
 * exactly this shape.
 *
 * The plane itself is contract/event_tail.h; the ring reader is
 * event_read.h; the decisions that need no Toolbox are
 * transitions_logic.h. What is left in transitions_cmd.c is TickCount,
 * the shared table, the anchor oracle and the plane lease.
 */
#ifndef NOW_TRANSITIONS_CMD_H
#define NOW_TRANSITIONS_CMD_H

#include <Processes.h>

#include "transitions_logic.h"
#include "transition_coordinator.h"

/* NowTransitionsStartReq moved to transitions_logic.h, because what fills
   it is now Toolbox-free and testable there while what CONSUMES it is
   not. The boundary is the request/reply one: the parse produces the Req
   with no Toolbox, the resolve turns it into the Arm below with plenty. */

typedef struct {
    NowEventU32 a5;
    NowEventU32 expiry;
    NowEventU32 now_ticks;
    const char *route;   /* serial | front | a5 | name; never NULL    */
    char process[32];    /* the resolved process's name, or ""        */
} NowTransitionsArm;

/* The published block, or NULL when this machine has no P5 plane: no
   extension, an extension older than the plane, or a table that does not
   carry the capability bit. NULL is a complete answer and both faces
   render it as a refusal with a reason. */
NowEventBlock *now_transitions_block(void);

/* Reads the plane. Writes nothing, moves nothing. */
void now_transitions_status(NowEventU32 cursor, NowTransitionsStatus *out);

/* Resolves the target and writes the request. Returns 1 having written
   `out`, or 0 having set `code` and `message` to static strings.
 *
 * A 1 means REQUESTED, never armed: nothing records until the extension's
 * own pass runs inside the target and agrees. `status`'s `passes` is what
 * tells those apart afterwards. */
int now_transitions_start(const NowTransitionsStartReq *req,
                          NowTransitionsArm *out,
                          const char **code, const char **message);

/* Withdraws the request and releases the plane lease. Same claim
   discipline: the resident stops recording at its next pass inside the
   target, in that process's own context. */
void now_transitions_stop(void);

/* Copies out up to `max` records from `cursor`, oldest first, and reports
   where the caller now stands. Does NOT move the shared reader cursor —
   see now_transitions_commit_read. `usable` distinguishes "no readable
   plane" from "a plane with nothing in it", which are not the same
   answer. */
unsigned long now_transitions_read(NowEventU32 cursor, NowEventRecord *out,
                                   unsigned long max, NowEventU32 *next,
                                   unsigned long *lost, int *usable);

/* Moves the SHARED reader cursor to `next`, forward only.
 *
 * Separate from the read on purpose, and called only once a face has
 * successfully delivered what it read: a caller that read records and
 * then could not render them must not have lost them (event_read.h). The
 * forward-only rule is transitions_logic.h's, and it is what keeps
 * `dropped` meaningful. */
void now_transitions_commit_read(NowEventU32 next);

/* Ordinary application-context service. This is the sole owner of the
 * resident ring's reader_cursor; command and console drains consume its
 * application-owned ledger instead. */
void now_transitions_poll(void);
int now_transitions_take_invalidation(NowMirrorInvalidation *out);

/* The wire face: writes one whole command.result. */
void now_transitions_run(const char *request_json, long id,
                         char *out, long cap);

#endif /* NOW_TRANSITIONS_CMD_H */
