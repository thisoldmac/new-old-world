#ifndef NOW_QDTRACE_TARGET_H
#define NOW_QDTRACE_TARGET_H

/* `qdtrace start`'s target selector, chosen without Toolbox calls.

   A wire caller names a process, not an A5. The ordinary route is a
   complete ProcessSerialNumber; `front:true` is available when the
   caller intentionally wants whichever process is front at dispatch.
   Raw A5 remains only as a compatibility fallback for a caller that has
   already resolved one. Resolution itself stays in qdtrace_cmd.c, where
   the guest can use the same validated anchor oracle as observation. */
typedef enum {
    kNowQDTargetSerial,
    kNowQDTargetFront,
    kNowQDTargetA5,
    kNowQDTargetNone,
    kNowQDTargetBadSerial
} NowQDTarget;

/* Presence is separate from value. A half serial is always malformed,
   even when another selector is present. Precedence is serial, front,
   then raw A5. */
NowQDTarget now_qdtrace_pick_target(int has_a5,
                                    int has_serial_hi, int has_serial_lo,
                                    int has_front, int front_true);

const char *now_qdtrace_target_route_name(NowQDTarget target);

/* Redraw is a courtesy only for a Process Manager selector that resolved to
   this command-serving application. Raw A5 never proves process identity. */
int now_qdtrace_target_may_redraw(NowQDTarget target, int same_process);

#endif /* NOW_QDTRACE_TARGET_H */
