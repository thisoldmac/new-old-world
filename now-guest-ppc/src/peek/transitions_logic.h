/*
 * transitions_logic.h - the `transitions` verb's decisions, with no
 * Toolbox in them.
 *
 * The same split ext/src/now_event_logic.c uses on the other side of the
 * contract, for the same reason: what can be decided without the Toolbox
 * is decided here and run by `scripts/test-native` with the host
 * compiler. What is left in transitions_cmd.c is TickCount, the shared
 * table, the anchor oracle, and the plane lease.
 *
 * The one decision here that is not arithmetic is
 * `now_transitions_reader_advance`, and it is the reason this file
 * exists rather than the status being assembled inline. See its comment.
 */
#ifndef NOW_TRANSITIONS_LOGIC_H
#define NOW_TRANSITIONS_LOGIC_H

#include "event_read.h"

enum {
    /* Ticks. 60 = one second. The floor is a second because a request
       shorter than the resident's own heartbeat cadence can lapse before
       a single record exists, which reads exactly like a plane that does
       not work. The ceiling is ten minutes; the default is one, because
       the resident writes one heartbeat a second on a quiet machine and
       60 records fit the 256-record ring with room for real transitions.
       Judgements against the ring's size, not measurements - the
       contract's row says so too, in the one place both sides read. */
    kNowTransitionsTtlMin = 60,
    kNowTransitionsTtlMax = 36000,
    kNowTransitionsTtlDefault = 3600
};

/* Everything either face needs to render a `status`, and nothing about
   how either renders it. One producer, two renderers - the rule in
   docs/command-parity.md, and the reason the Console and the wire cannot
   drift into two accounts of the same plane. */
typedef struct {
    int usable;                 /* the block passed event_read's gate    */
    NowEventU32 format;
    /* What THIS side asked for. */
    NowEventU32 arm_a5;
    NowEventU32 arm_expiry;
    NowEventU32 arm_commit;
    int expired;                /* the deadline has passed; see below    */
    /* What the resident did about it. */
    NowEventU32 passes;
    NowEventU32 write_cursor;
    NowEventU32 dropped;
    NowEventU32 last_ticks;
    NowEventU32 reader_cursor;  /* the shared high-water mark            */
    /* What this caller's own cursor sees. */
    NowEventU32 cursor;
    unsigned long capacity;
    unsigned long pending;
    unsigned long lost;
    NowEventU32 now_ticks;
} NowTransitionsStatus;

/* Fills `out` from the block as it stands. Never writes the block:
   status is the only subcommand that neither writes nor moves a record,
   and a default that armed something would be a plane armed by a typo. */
void now_transitions_fill_status(const NowEventBlock *block,
                                 NowEventU32 cursor, NowEventU32 now_ticks,
                                 NowTransitionsStatus *out);

/* Whether a request with this deadline is still live at `now_ticks`.
 *
 * NOTHING CLEARS `arm_commit` WHEN A REQUEST LAPSES. The resident checks
 * the deadline on every pass and declines, but it does not write the
 * application's own cells - so a block whose request expired an hour ago
 * still reads commit=1, and a status that showed only that word would
 * report a live request that records nothing, forever. This is what
 * turns those into two different answers. */
int now_transitions_expired(NowEventU32 expiry, NowEventU32 now_ticks);

/* The ttl a caller asked for, bounded. Returns 0 and writes nothing when
   the request is out of range - refused rather than clamped, because a
   silently shortened arm looks exactly like a plane that stopped. */
int now_transitions_ttl(long asked, NowEventU32 *out);

/* Where the shared `reader_cursor` should stand after a drain that got
   as far as `next`.
 *
 * THE ONLY RULE HERE THAT IS NOT ARITHMETIC. The resident reads this
 * word to decide whether a write costs a reader its view - it is the
 * only way `dropped` can mean anything (contract/event_tail.h). So it is
 * a HIGH-WATER MARK, not a position: a caller replaying an old cursor
 * still gets its records back out of the ring, and must not rewind the
 * resident's idea of how far behind anyone is. Rewinding it would make
 * the resident count drops for records nobody is waiting for, and
 * `dropped` would stop being a fact about loss.
 *
 * Unsigned throughout, so a wrapped cursor still compares correctly. */
NowEventU32 now_transitions_reader_advance(NowEventU32 stored,
                                           NowEventU32 next);

/* The word for a record kind, or "unknown". Never a guess: the resident
   loads at boot from a separately built binary, so one newer than this
   application is a real case, and a decoder that renamed an unfamiliar
   kind to a familiar one would be plausible output. The NUMBER goes on
   the wire beside this. */
const char *now_transitions_kind_name(NowEventU32 kind);

/* The console line's grammar: an op word, then the rest of the line as a
   process name. Writes the op into `op` ("status" when the line is
   empty) and returns a pointer INTO `args` at the name, which is "" when
   there is none.
 *
 * Here rather than in console_model.c so the two faces cannot end up
 * disagreeing about what a line means, and so it is reachable from the
 * native test — the same argument proc_quit_args.c makes for `quit`. The
 * name is the whole rest of the line because process names have spaces
 * in them. */
const char *now_transitions_parse_line(const char *args,
                                       char *op, long op_cap);

#endif /* NOW_TRANSITIONS_LOGIC_H */
