#ifndef NOW_MIRROR_FACTS_H
#define NOW_MIRROR_FACTS_H

/* The guest-observed half of Mirror policy. This value contains only facts
   the classic Mac can prove about the one NOW Extension and its four planes.
   Host policy never enters it. Kept Toolbox-free so layout and wire tests run
   with the native compiler. */

#include <MacTypes.h>

enum {
    kMirrorFactsSchema = 1,
    kMirrorPlaneCount = 5,
    kMirrorIdentityWords = 5,
    kMirrorReasonMax = 128
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
    kMirrorPlaneTransitions
} MirrorPlane;

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
    Boolean has_build_identity;
    unsigned long source_manifest[kMirrorIdentityWords];
    unsigned long build_fingerprint[kMirrorIdentityWords];
    char reason[kMirrorReasonMax];
    MirrorPlaneFact planes[kMirrorPlaneCount];
} MirrorFacts;

#endif /* NOW_MIRROR_FACTS_H */
