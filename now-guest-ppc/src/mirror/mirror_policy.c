#include "mirror_policy.h"

#include <string.h>

#include "prefs.h"

static Boolean g_loaded;
static MirrorPolicy g_policy;

static void read_from_prefs(const NowPrefs *prefs, MirrorPolicy *out)
{
    out->structure = prefs->mirror_structure;
    out->finder_complements = prefs->mirror_finder_complements;
    out->content = prefs->mirror_content;
    out->foreground_cycle = prefs->mirror_foreground_cycle;
}

static void ensure_loaded(void)
{
    NowPrefs prefs;

    if (g_loaded) {
        return;
    }
    now_prefs_load(&prefs);
    read_from_prefs(&prefs, &g_policy);
    g_loaded = true;
}

void now_mirror_policy_get(MirrorPolicy *out)
{
    if (out == NULL) {
        return;
    }
    ensure_loaded();
    *out = g_policy;
}

Boolean now_mirror_policy_enabled(MirrorPolicyDomain domain)
{
    ensure_loaded();
    switch (domain) {
    case kMirrorPolicyStructure: return g_policy.structure;
    case kMirrorPolicyFinderComplements: return g_policy.finder_complements;
    case kMirrorPolicyContent: return g_policy.content;
    case kMirrorPolicyForegroundCycle: return g_policy.foreground_cycle;
    case kMirrorPolicyEnd: break;
    }
    return false;
}

OSErr now_mirror_policy_set(MirrorPolicyDomain domain, Boolean enabled)
{
    NowPrefs prefs;
    OSErr err;

    if ((int)domain < 0 || domain >= kMirrorPolicyEnd) {
        return paramErr;
    }
    now_prefs_load(&prefs);
    switch (domain) {
    case kMirrorPolicyStructure: prefs.mirror_structure = enabled; break;
    case kMirrorPolicyFinderComplements:
        prefs.mirror_finder_complements = enabled;
        break;
    case kMirrorPolicyContent: prefs.mirror_content = enabled; break;
    case kMirrorPolicyForegroundCycle:
        prefs.mirror_foreground_cycle = enabled;
        break;
    case kMirrorPolicyEnd: return paramErr;
    }
    err = now_prefs_save(&prefs);
    if (err == noErr) {
        read_from_prefs(&prefs, &g_policy);
        g_loaded = true;
    }
    return err;
}

const char *now_mirror_policy_name(MirrorPolicyDomain domain)
{
    static const char *names[] = {
        "Observe application structure",
        "Read Finder details",
        "Trace drawing contents",
        "Allow foreground discovery"
    };

    _Static_assert(sizeof names / sizeof names[0] == kMirrorPolicyCount,
                   "every Mirror policy domain needs a control label");
    if ((int)domain < 0 || domain >= kMirrorPolicyEnd) {
        return "";
    }
    return names[(int)domain];
}
