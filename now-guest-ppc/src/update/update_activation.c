#include "update_activation.h"

#include <string.h>

#include "prefs.h"
#include "update_model.h"
#include "update_status.h"

Boolean now_update_activation_reconcile(NowPrefs *prefs)
{
    char version[24];
    char active_build[65];

    if (prefs == NULL || prefs->pending_extension_build[0] == '\0') {
        return 0;
    }
    now_update_current_identity(kNowUpdateExtension,
                                version, sizeof version,
                                active_build, sizeof active_build);
    if (now_update_extension_pending_activation(
            prefs->pending_extension_build, active_build)) {
        return 1;
    }

    prefs->pending_extension_build[0] = '\0';
    (void)now_prefs_save(prefs);
    return 0;
}

OSErr now_update_activation_record(const char *build)
{
    NowPrefs prefs;

    if (build == NULL || strlen(build) != 64) return paramErr;
    now_prefs_load(&prefs);
    strcpy(prefs.pending_extension_build, build);
    return now_prefs_save(&prefs);
}

OSErr now_update_activation_clear(void)
{
    NowPrefs prefs;

    now_prefs_load(&prefs);
    prefs.pending_extension_build[0] = '\0';
    return now_prefs_save(&prefs);
}
