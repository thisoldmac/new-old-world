#include "mirror_policy.h"

#include <string.h>

#include "prefs.h"

static Boolean g_loaded;
static MirrorPolicy g_policy;

static void ensure_loaded(void)
{
    NowPrefs prefs;

    if (g_loaded) {
        return;
    }
    now_prefs_load(&prefs);
    g_policy.enabled = prefs.mirror_enabled;
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

Boolean now_mirror_policy_enabled(void)
{
    ensure_loaded();
    return g_policy.enabled;
}

OSErr now_mirror_policy_set(Boolean enabled)
{
    NowPrefs prefs;
    OSErr err;

    now_prefs_load(&prefs);
    prefs.mirror_enabled = enabled;
    err = now_prefs_save(&prefs);
    if (err == noErr) {
        g_policy.enabled = enabled;
        g_loaded = true;
    }
    return err;
}

const char *now_mirror_policy_name(void)
{
    /* Names the MACHINE, not the feature: the host's page already says
       "Mirror" everywhere, and what this switch decides is whether this
       particular Mac is available to it. */
    return "Allow this Mac to be mirrored";
}
