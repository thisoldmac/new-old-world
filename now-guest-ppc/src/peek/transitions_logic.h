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

/* How a caller names the ONE process to instrument. Presence is separate
   from value throughout, so a half serial is malformed rather than a
   different process.
 *
 * Here rather than beside now_transitions_start because what FILLS this
 * needs no Toolbox and what consumes it needs a great deal of one, and
 * the filling is where the plane's worst defect lived unseen. */
typedef struct {
    int has_a5;
    NowEventU32 a5;
    int has_serial_hi;
    int has_serial_lo;
    NowEventU32 serial_hi;
    NowEventU32 serial_lo;
    int has_front;
    int front_true;
    const char *target;  /* by name; NULL or "" is absent. NOT `name` -
                            see now_transitions_start_args below.       */
    long ttl_ticks;      /* 0 means the default                        */
} NowTransitionsStartReq;

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

/* Why the wire's grammar is here too, and not left inline in the command
 * file the way it was until 2026-08-05.
 *
 * The console line had a parser in this file, reachable by the native
 * test. The WIRE's arg extraction did not: it sat inside a static
 * function in transitions_cmd.c, above `#include <Carbon.h>`, where no
 * host compiler could reach it. So `transitions start` shipped with a
 * parse that could not arm ANY process by ANY route, past a green suite,
 * because every test entered the plane BELOW this line with a Req a test
 * had filled by hand.
 *
 * The defect was one key. `target` was declared `name`, and the guest
 * scans a request FLAT - so it matched the envelope's own
 * `"name":"transitions"` first and armed the literal string
 * `transitions`, which is never a process. Being the first route tried,
 * it short-circuited serial, front and a5 as well.
 *
 * TAKE THE WHOLE FRAME, NOT THE ARGS OBJECT. `request_json` is the
 * request exactly as the wire delivered it, envelope and all, because
 * that is what the caller has and what the flat scan actually sees. A
 * test that hands this only the inner `args` object proves nothing about
 * the bug this function exists to have caught: the collision is only
 * observable in the presence of the envelope. */
typedef enum {
    kNowTransitionsArgsOK = 0,
    kNowTransitionsArgsBadA5,
    kNowTransitionsArgsBadSerial,
    kNowTransitionsArgsBadFront,
    /* No request at all. Unreachable from either face; it carries
       now_transitions_start's own word for the same condition rather
       than borrowing a code that would name a field nobody sent. */
    kNowTransitionsArgsUnreadable
} NowTransitionsArgsResult;

/* Fills `req` from a whole request frame. `target_buf` backs `req->target`
   and must outlive it. Returns kNowTransitionsArgsOK, or a refusal whose
   wire code and message are below - the caller renders them, this decides
   them, so both faces refuse a malformed request identically. */
NowTransitionsArgsResult now_transitions_start_args(const char *request_json,
                                                    NowTransitionsStartReq *req,
                                                    char *target_buf,
                                                    long target_cap);

const char *now_transitions_args_code(NowTransitionsArgsResult r);
const char *now_transitions_args_message(NowTransitionsArgsResult r);

#endif /* NOW_TRANSITIONS_LOGIC_H */
