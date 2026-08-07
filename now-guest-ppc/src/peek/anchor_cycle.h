#ifndef NOW_ANCHOR_CYCLE_H
#define NOW_ANCHOR_CYCLE_H

#include <Carbon.h>

#include "peek_table.h"

/* **Cycle the desktop applications so the Mirror can see the machine.**
 *
 * THE DEFECT (docs/open-issues.md, 2026-08-07). The anchor plane captures
 * a process when THAT process executes GetNextEvent while `arm_request`
 * has the anchors bit set. On a freshly booted Macintosh nothing else is
 * scheduled inside the short armed windows a scene request opens, so the
 * resident's filter made 451 armed passes and was inside a foreign
 * process on NONE of them. The Mirror could only show you a machine you
 * had already driven. The deep fix — an arm that outlives the walk, or a
 * hook that fires in a foreign context — is future work and is written
 * up rather than attempted here.
 *
 * THIS IS THE WORKAROUND, AND IT IS DELIBERATE. A person or an agent asks
 * for it; it is never automatic and never silent, because it visibly
 * disturbs the machine — applications come forward in turn and windows
 * flash. Two stated uses: once on a fresh boot to populate everything,
 * and on demand when state has gone stale.
 *
 * THE ORDER OF OPERATIONS IS THE WHOLE DESIGN.
 *
 * 1. **Arm first, and hold it armed for the whole cycle.** Fronting is
 *    not what acquires the slot; executing GetNextEvent while armed is.
 *    A cycle that fronted every application while the plane happened to
 *    be dark would acquire nothing and would look like it worked, so the
 *    claim is taken under this file's own lease owner and the counters
 *    are what is believed afterwards — not the flashing.
 * 2. **Try the invisible way first.** `now_peek_anchor_acquire` wakes
 *    un-anchored processes with WakeUpProcess, which costs a trap and
 *    disturbs nothing. Whatever that reaches is not fronted.
 * 3. **Then front what is left, one at a time**, yielding after each so
 *    it pumps, and only applications — a background-only process is out
 *    of scope and is REPORTED as out of scope rather than counted as a
 *    failure.
 * 4. **Restore the previous frontmost, on every path out.** Success,
 *    refusal, timeout, or an interrupted cycle. If the application that
 *    was front has quit meanwhile there is nothing to restore to, and
 *    the report says so in words rather than leaving a person to notice.
 *
 * HONEST DEGRADATION. No resident, or a plane that will not arm, and the
 * cycle refuses before it has fronted anything — the machine is left
 * exactly as it was and the Mirror behaves exactly as it does today. */

enum {
    kNowAnchorCycleNoteMax = 96,
    /* How many un-reached processes are NAMED rather than merely counted.
       A count says a cycle was incomplete; a name says WHICH machine a
       person is being shown less than all of, and that is the difference
       between a caveat and something actionable. Bounded because this
       report is a wire reply and a list nobody sized is how a reply comes
       back truncated while claiming to be whole. */
    kNowAnchorCycleNamedMax = 8,
    kNowAnchorCycleNameMax = 32
};

typedef struct {
    /* The instrument, before and after, because a cycle that reports its
       own success is not evidence. These are the resident's own counters
       (mirror.extension.anchors): `count` is occupied slots, `slot_scans`
       counts contexts the filter noticed changing, `event_passes` counts
       armed passes. A cycle that raised `event_passes` and not
       `slot_scans` fronted things and acquired nothing. */
    unsigned long before_count;
    unsigned long before_slot_scans;
    unsigned long before_event_passes;
    unsigned long after_count;
    unsigned long after_slot_scans;
    unsigned long after_event_passes;

    short considered;      /* processes enumerated, excluding ourselves   */
    short already;         /* held an anchor before the cycle began       */
    short woken;           /* reached invisibly, never brought forward    */
    short fronted;         /* applications actually brought forward       */
    short acquired;        /* of those, ones that then held an anchor     */
    short refused;         /* would not come forward, or never pumped     */
    short vanished;        /* quit between enumeration and its turn       */
    short background_only; /* faceless: out of scope, not a failure       */

    int armed;             /* the plane was armed for the cycle           */
    int complete;          /* every candidate got its turn                */
    int restored;          /* the previous frontmost is front again       */

    /* THE PROCESSES THIS CYCLE COULD NOT REACH, by name - the faced ones
       only. A background-only process is not listed: it is out of scope
       by declaration rather than by failing, which is the whole reason
       the roster reads `modeOnlyBackground` up front the way
       `process.list` does. Anything named here has no anchor after a
       cycle that tried, and a consumer must read it as UNKNOWN rather
       than as empty. */
    char unreached[kNowAnchorCycleNamedMax][kNowAnchorCycleNameMax];
    short unreached_count;   /* names filled, <= kNowAnchorCycleNamedMax */
    short unreached_omitted; /* more that did not fit, counted not dropped */

    char note[kNowAnchorCycleNoteMax];
} NowAnchorCycleReport;

/* Runs a cycle and fills `out` (never NULL). Returns 1 when the cycle
   ran, 0 when it refused before disturbing anything — and a refusal
   fills `note` with the reason, which is the only thing either face
   prints in that case. */
int now_peek_anchor_cycle(NowAnchorCycleReport *out);

#endif /* NOW_ANCHOR_CYCLE_H */
