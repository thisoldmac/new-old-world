#ifndef NOW_MIRROR_FACTS_H
#define NOW_MIRROR_FACTS_H

/* The guest-observed half of Mirror policy. This value contains only facts
   the classic Mac can prove about the one NOW Extension and its four planes.
   Host policy never enters it. Kept Toolbox-free so layout and wire tests run
   with the native compiler. */

#include <MacTypes.h>

enum {
    kMirrorFactsSchema = 1,
    kMirrorPlaneCount = 4,
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
    kMirrorPlaneInteraction
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
    Boolean has_build_identity;
    unsigned long source_manifest[kMirrorIdentityWords];
    unsigned long build_fingerprint[kMirrorIdentityWords];
    char reason[kMirrorReasonMax];
    MirrorPlaneFact planes[kMirrorPlaneCount];
} MirrorFacts;

#endif /* NOW_MIRROR_FACTS_H */
