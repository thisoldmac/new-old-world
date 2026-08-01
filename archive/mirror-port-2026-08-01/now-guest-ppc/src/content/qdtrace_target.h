#ifndef NOW_QDTRACE_TARGET_H
#define NOW_QDTRACE_TARGET_H

/* `qdtrace start`'s target selector - which of the three ways a caller
   may name the process to arm, PICKED without resolving any of them.

   THE WIRE CALLER NAMES A PROCESS, NOT AN A5. Upstream's own `qdtrace`
   took an A5 because upstream's host had one to hand it; NOW's does
   not, and the fix is not to teach the host to resolve one - it has no
   anchor oracle to resolve it against - but to let the wire send what
   it actually has (a ProcessSerialNumber, or "whichever one is
   frontmost") and have the GUEST resolve it, the same way `observe`
   already resolves a process's A5 for display. See
   MirrorContentJoin.swift's header for the gap this closes.

   Three selectors, and never more than one takes effect:

     serialHi + serialLo   the target's own ProcessSerialNumber, the
                            same pair `aesend` takes and for the same
                            reason both are required together - half a
                            serial names a different process, not "no
                            process".
     front                 whichever process is frontmost when the
                            guest reads the request. A bare `true`;
                            absent or `false` is not a selector.
     a5                     the raw A5, kept as a fallback for a caller
                            that already resolved one itself (an
                            `observe`/`axsnap` reply names it).

   PICKING IS TOOLBOX-FREE ON PURPOSE. Resolving a serial or `front` to
   an A5 means GetFrontProcess/GetProcessInformation and a walk through
   the anchor oracle - all Toolbox, all in qdtrace_cmd.c, all
   unreachable from a native test. Which selector a request named, and
   the one malformed shape that is a REQUEST problem rather than a
   resolution problem - half a serial - has no such dependency, so it
   lives here where a host cc can prove it. */

typedef enum {
    kNowQDTargetSerial,    /* serialHi and serialLo both present        */
    kNowQDTargetFront,     /* front is present and true                 */
    kNowQDTargetA5,        /* the raw a5 fallback                       */
    kNowQDTargetNone,      /* nothing named a target                    */
    kNowQDTargetBadSerial  /* exactly one of serialHi/serialLo is present*/
} NowQDTarget;

/* `has_a5`/`has_serial_hi`/`has_serial_lo`/`has_front` are presence, not
   value - a caller that sent `front:false` has `has_front` true and
   `front_true` false, and that is deliberately not a selector (see the
   header above). Precedence, when more than one is present: serial,
   then front, then the raw a5 - a wire caller that has resolved a serial
   already knows more than one that is only guessing "the frontmost", and
   raw a5 is the fallback of last resort for a caller that resolved
   nothing itself. */
NowQDTarget now_qdtrace_pick_target(int has_a5,
                                    int has_serial_hi, int has_serial_lo,
                                    int has_front, int front_true);

/* The selector as the word the reply's `resolvedVia` carries. "" for
   the two non-selecting verdicts (`None`, `BadSerial`) - both are
   refused before anything is resolved, so there is no route to name. */
const char *now_qdtrace_target_route_name(NowQDTarget target);

#endif /* NOW_QDTRACE_TARGET_H */
