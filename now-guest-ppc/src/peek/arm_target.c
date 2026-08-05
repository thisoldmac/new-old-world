/*
 * arm_target.c - see arm_target.h. This body was qdtrace_cmd.c's
 * `resolve_start_target` and is unchanged in behaviour; the move is what
 * makes it one rule rather than two.
 */

#include "arm_target.h"

#include "axprocess.h"
#include "peek_oracle.h"

int now_peek_arm_target_a5(const ProcessSerialNumber *psn,
                           unsigned long *a5,
                           const char **code, const char **message)
{
    NowAxContext ctx;
    NowPeekReadStatus status;

    /* Set before anything can fail, so no caller has to reason about
       which failure paths filled them. */
    if (code != NULL) {
        *code = "unreadable";
    }
    if (message != NULL) {
        *message = "this process's anchor cannot be validated safely";
    }
    if (psn == NULL || a5 == NULL) {
        return 0;
    }
    status = now_ax_bind_process(psn, &ctx);
    switch (status) {
    case kNowPeekReadOk:
        break;
    case kNowPeekReadNoPlane:
        if (code != NULL) { *code = "anchor-plane-absent"; }
        if (message != NULL) {
            *message = "the NOW Extension's window-anchor plane is not "
                       "armed, so no process can be resolved to an A5 "
                       "from here";
        }
        return 0;
    case kNowPeekReadNoAnchor:
        if (code != NULL) { *code = "not-pumped"; }
        if (message != NULL) {
            *message = "this process has not pumped its event loop since "
                       "anchors were armed; bring it forward and ask again";
        }
        return 0;
    case kNowPeekReadAmbiguous:
        if (code != NULL) { *code = "ambiguous"; }
        if (message != NULL) {
            *message = "two or more anchor slots claim this process; this "
                       "Mac will not guess which one is current";
        }
        return 0;
    case kNowPeekReadMismatch:
        if (code != NULL) { *code = "mismatch"; }
        if (message != NULL) {
            *message = "the matching anchor disagrees with this process's "
                       "partition and cannot be used";
        }
        return 0;
    case kNowPeekReadNoWindows:
    case kNowPeekReadStub:
    case kNowPeekReadUnreadable:
    default:
        return 0;                      /* the defaults set above say it */
    }
    /* The whole reason this is not "the match's fields are filled": Ok and
       Stale both carry an a5, and only Ok is safe to arm with. */
    if (!now_peek_anchor_a5_arm_trusted(ctx.verdict)) {
        if (code != NULL) { *code = "a5-stale"; }
        if (message != NULL) {
            *message = "this process's anchor is safe to observe but too "
                       "stale to arm; bring it forward so it pumps, then "
                       "retry";
        }
        return 0;
    }
    *a5 = ctx.a5;
    return 1;
}
