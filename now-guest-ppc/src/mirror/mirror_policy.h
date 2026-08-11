#ifndef NOW_MIRROR_POLICY_H
#define NOW_MIRROR_POLICY_H

#include <MacTypes.h>

/* Application-owned policy for the four different ways Mirror may observe
   or disturb this Mac. These are deliberately not plane bits: Finder
   complements and foreground discovery are acquisition strategies, while
   structure and content are resident-backed observation domains. Keeping
   them named here prevents a caller from treating "Mirror enabled" as one
   permission that silently enables all four. */
typedef enum MirrorPolicyDomain {
    kMirrorPolicyStructure = 0,
    kMirrorPolicyFinderComplements,
    kMirrorPolicyContent,
    kMirrorPolicyForegroundCycle,
    kMirrorPolicyEnd
} MirrorPolicyDomain;

enum { kMirrorPolicyCount = kMirrorPolicyEnd };

typedef struct MirrorPolicy {
    Boolean structure;
    Boolean finder_complements;
    Boolean content;
    Boolean foreground_cycle;
} MirrorPolicy;

void now_mirror_policy_get(MirrorPolicy *out);
Boolean now_mirror_policy_enabled(MirrorPolicyDomain domain);
OSErr now_mirror_policy_set(MirrorPolicyDomain domain, Boolean enabled);
const char *now_mirror_policy_name(MirrorPolicyDomain domain);

#endif /* NOW_MIRROR_POLICY_H */
