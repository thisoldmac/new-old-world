#include <stdio.h>
#include <string.h>

#include "update_activation.h"
#include "update_model.h"

static NowPrefs stored;
static char resident_build[65];
static OSErr save_result;
static int save_count;

void now_prefs_load(NowPrefs *prefs)
{
    *prefs = stored;
}

OSErr now_prefs_save(const NowPrefs *prefs)
{
    ++save_count;
    if (save_result == noErr) stored = *prefs;
    return save_result;
}

void now_update_current_identity(NowUpdateComponent component,
                                 char *version, long version_cap,
                                 char *build, long build_cap)
{
    (void)component;
    if (version_cap > 0) version[0] = '\0';
    if (build_cap > 0) {
        strncpy(build, resident_build, (size_t)build_cap - 1);
        build[build_cap - 1] = '\0';
    }
}

static int fail(const char *message)
{
    fprintf(stderr, "%s\n", message);
    return 1;
}

static void reset(void)
{
    memset(&stored, 0, sizeof stored);
    memset(resident_build, 0, sizeof resident_build);
    save_result = noErr;
    save_count = 0;
}

int main(void)
{
    NowPrefs prefs;
    char build[65];

    memset(build, 'a', 64);
    build[64] = '\0';
    reset();
    prefs = stored;
    if (now_update_activation_reconcile(NULL)
        || now_update_activation_reconcile(&prefs) || save_count != 0)
        return fail("empty or null receipt changed preferences");

    strcpy(prefs.pending_extension_build, build);
    memset(resident_build, 'b', 40);
    resident_build[40] = '\0';
    if (!now_update_activation_reconcile(&prefs) || save_count != 0)
        return fail("different resident cleared pending activation");

    memcpy(resident_build, build, 40);
    if (now_update_activation_reconcile(&prefs) || save_count != 1
        || prefs.pending_extension_build[0] != '\0')
        return fail("matching resident did not clear and save receipt");

    reset();
    if (now_update_activation_record("short") != paramErr || save_count != 0)
        return fail("malformed activation build was saved");
    if (now_update_activation_record(build) != noErr || save_count != 1
        || strcmp(stored.pending_extension_build, build) != 0)
        return fail("valid activation receipt was not saved");
    if (now_update_activation_clear() != noErr || save_count != 2
        || stored.pending_extension_build[0] != '\0')
        return fail("activation receipt was not cleared");

    reset();
    save_result = -1;
    if (now_update_activation_record(build) == noErr || save_count != 1
        || stored.pending_extension_build[0] != '\0')
        return fail("failed preference save reported durable receipt");
    return 0;
}
