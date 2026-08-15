#ifndef NOW_MIRROR_FACTS_H
#define NOW_MIRROR_FACTS_H

/* The guest-observed half of Mirror policy. This value contains only facts
   the classic Mac can prove about the one NOW Extension and its planes.
   Host policy never enters it. Kept Toolbox-free so layout and wire tests run
   with the native compiler. */

#include <MacTypes.h>

/* The anchor slot cap is the RESIDENT's, stated once where both halves
   read it. This file deliberately does not restate 32: the number that
   matters is how many slots the extension actually allocated, and only
   contract/peek_table.h knows it. AGENTS.md names the alternative as the
   defect this project has paid most for. */
#include "peek_table.h"
#include "mirror_policy.h"

enum {
    kMirrorFactsSchema = 1,
    kMirrorIdentityWords = 5,
    kMirrorReasonMax = 128,
    /* Str31-derived: the resident captures CurApName into a fixed field
       and this is that field, plus a terminator, as a C string. */
    kMirrorAnchorNameMax = kNowPeekAnchorNameSize + 1
};

typedef enum {
    kMirrorLifecycleAbsent = 0,
    kMirrorLifecycleNeedsRestart,
    kMirrorLifecycleWrongVersion,
    kMirrorLifecycleActive,
    kMirrorLifecycleDegraded
} MirrorLifecycle;

typedef enum {
    kMirrorPlaneStructure = 0,
    kMirrorPlaneSemantics,
    kMirrorPlaneContent,
    kMirrorPlaneInteraction,
    /* P5. Appended last, so every existing row keeps its index: the host
       reads these positionally and a reordering would silently relabel
       four planes. */
    kMirrorPlaneTransitions,
    /* NOT A PLANE — the enumeration's own end, and the only place the
       number of planes is written down.

       It was written down twice: `kMirrorPlaneCount = 5` in the enum
       above, and a four-row label table in mirror_layout.c. P5 landed in
       one of them, so the Workshop's Mirror page drew a fifth row whose
       name and purpose were read one PAST the end of two four-element
       arrays — undefined behaviour that happened to render as an empty
       string. That is this repository's most expensive defect class, the
       one the control-frame cap taught: a limit stated in more than one
       place is wrong the moment anything grows past the smallest.

       So the count is DERIVED from the list, and mirror_layout.c's table
       is checked against it at compile time on both compilers. A sixth
       plane cannot reintroduce this without failing the build. */
    kMirrorPlaneEnd
} MirrorPlane;

enum { kMirrorPlaneCount = kMirrorPlaneEnd };

typedef enum {
    kMirrorFreshUnavailable = 0,
    kMirrorFreshPending,
    kMirrorFreshStale,
    kMirrorFreshCurrent
} MirrorFreshness;

typedef enum {
    kMirrorPlaneUnsupported = 0,
    kMirrorPlaneInactive,
    kMirrorPlaneRequested,
    kMirrorPlaneRefused,
    kMirrorPlaneDegraded,
    kMirrorPlaneActiveStale,
    kMirrorPlaneActiveCurrent
} MirrorPlaneState;

typedef struct {
    unsigned long capability;
    Boolean supported;
    unsigned long format;
    Boolean requested;
    Boolean active;
    MirrorFreshness freshness;
    MirrorPlaneState state;
    unsigned long generation;
    char reason[kMirrorReasonMax];
} MirrorPlaneFact;

/* One captured anchor slot, as the reader sees it. The name is the
   decisive field and not decoration: A5 and the stack base only bound an
   address space, and a partition can be recycled, so the name out of the
   captured context is the one value that says WHICH application the
   resident was running inside when it wrote this slot. */
typedef struct {
    int slot;
    char name[kMirrorAnchorNameMax];
    unsigned long a5;
    unsigned long window_list;
    unsigned long stamp_ticks;
    unsigned long age_ticks;
} MirrorAnchorSlotFact;

/* The P1 hot path's own account of itself.
 *
 * This exists because `ax_oracle_not_found` cannot be diagnosed without
 * it. That verdict means "no slot claims this process's partition", and
 * it is reached by three different roads - the resident never ran in
 * that process's context, or it ran and the partition read disagreed, or
 * there was no partition to read. Those are different defects with
 * different fixes, and until these counters could be read out loud
 * nothing on either side could tell them apart: the resident counted
 * every one of these words and no face said them.
 *
 * `event_passes` is the load-bearing one, and it comes first for the
 * same reason `transitions status` puts `passes` before the record
 * count: it separates "the filter never ran while armed" from "it ran
 * and captured nothing". */
typedef struct {
    /* False when the resident is older than these counters - reported,
       never guessed, by the accretive length rule every other cell in
       this struct follows. */
    Boolean present;
    unsigned long event_passes;
    unsigned long slot_scans;
    unsigned long full_publishes;
    unsigned long change_publishes;
    unsigned long cadence_publishes;
    unsigned long last_publish_ticks;
    /* Slots the filter maintains, as the RESIDENT counts them. Kept
       beside the array below rather than derived from it, because the
       two disagreeing is itself a fact worth seeing. */
    unsigned long count;
    unsigned long now_ticks;
    /* Occupied slots, oldest field first. `slot_count` is how many were
       READ; `slots_omitted` is how many were occupied and did not fit
       the reply, because a short list presented as a whole one is the
       error this project keeps paying for. */
    int slot_count;
    int slots_omitted;
    MirrorAnchorSlotFact slots[kNowPeekMaxAnchors];
} MirrorAnchorFacts;

typedef struct MirrorFacts {
    MirrorLifecycle lifecycle;
    unsigned long resident_major;
    unsigned long resident_minor;
    unsigned long table_length;
    unsigned long capabilities;
    unsigned long requested_bits;
    unsigned long active_bits;
    unsigned long heartbeat;
    /* P6's proof-of-life: the resident's interrupt-time task bumps this
       and nothing else does, so a reader either side of a starvation can
       say whether anything on the machine kept running while no
       application did. Zero means a resident without the vehicle — which
       an older one reports simply by being shorter. */
    unsigned long liveness_ticks;
    /* § 4's reachability answer, and the ONLY thing it claims: whether
       the resident could open MacTCP's `.ipp` driver. Nothing has been
       dialled. `transport_result` carries the driver's own OSErr, so a
       refusal arrives with its reason rather than as a bare false. An
       extension too old to have looked reports untried by being shorter,
       which is the accretive rule every other cell here follows. */
    unsigned long transport_probe;
    long transport_result;
    /* The channel itself, which is what the probe above deliberately was
       not. `channel_state` is a state and not a boolean because the ways
       this can be not-up are four different things to tell a person:
       nothing published, dialling, refused, or no transport at all.
       `channel_sends` counts frames the RESIDENT put on the wire — the
       evidence that it spoke, as `liveness_ticks` is the evidence that
       it ran. */
    unsigned long channel_state;
    long channel_result;
    unsigned long channel_sends;
    /* WHAT THE RESIDENT IS STILL HOLDING, which is a third question from
       `capabilities` and `active_bits` and was for a long time answered by
       neither.
       ------------------------------------------------------------------
       `capabilities` says what this binary CAN do; `active_bits` says what
       the wire asked for and got. Both are about intent. Neither answers
       the question a person asks before deciding to keep a system
       extension installed: with nothing running, what is still hooked?

       The sharpest thing it reports cannot be undone. Once the act plane
       has armed even once, six trap patches are in this machine's
       dispatch table until it reboots — they are bypassed, not removed,
       because unpatching from the middle of a chain another extension may
       have joined is how a Macintosh jumps into freed code. That is a
       true and durable fact about the machine in front of the user and it
       belongs on the page, not in a source comment.

       `gne_passes` is the denominator beside it: bumped on every filter
       pass whether or not anything is armed, so a page showing every
       plane's counter at zero can distinguish a resident at rest from one
       that never ran. Zero here on a resident that reports active is
       itself the interesting reading. */
    unsigned long rest_state;
    unsigned long gne_passes;
    Boolean has_rest_state;
    Boolean has_build_identity;
    unsigned long source_manifest[kMirrorIdentityWords];
    unsigned long build_fingerprint[kMirrorIdentityWords];
    char reason[kMirrorReasonMax];
    /* This Mac's own consent. Unlike the plane rows it remains reportable
       when the extension is absent: the preferences file belongs to this
       application, not to the resident. */
    MirrorPolicy policy;
    MirrorAnchorFacts anchors;
    MirrorPlaneFact planes[kMirrorPlaneCount];
} MirrorFacts;

#endif /* NOW_MIRROR_FACTS_H */
