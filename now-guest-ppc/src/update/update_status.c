#include "update_status.h"

#include <stdio.h>
#include <string.h>

#include "build_stamp.h"
#include "peek.h"
#include "product_identity.h"
#include "resident_version.h"

void now_update_current_identity(NowUpdateComponent component,
                                 char *version, long version_cap,
                                 char *build, long build_cap)
{
    if (version_cap > 0) version[0] = '\0';
    if (build_cap > 0) build[0] = '\0';
    if (component == kNowUpdateApplication) {
        const char *stamp = now_build_stamp();
        long n = 0;
        snprintf(version, (size_t)version_cap, "%s", PRODUCT_VERSION);
        while (stamp[n] != '\0' && stamp[n] != ' ' && n < build_cap - 1) {
            build[n] = stamp[n];
            ++n;
        }
        if (build_cap > 0) build[n] = '\0';
        return;
    }
    {
        const NowPeekTable *table = now_peek_table();
        NowPeekBuildIdentity identity;
        long pos = 0;
        int i;
        if (table == NULL) return;
        snprintf(version, (size_t)version_cap, "%u.%u",
                 (unsigned)table->ext_major, (unsigned)table->ext_minor);
        if (!now_peek_build_identity(&identity)) return;
        for (i = 0; i < kNowPeekIdentityWordCount && pos < build_cap; ++i) {
            pos += snprintf(build + pos, (size_t)(build_cap - pos),
                            "%08lx", identity.build_fingerprint[i]);
        }
    }
}

int now_update_extension_differs_from_app(char *line, long cap)
{
    const NowPeekTable *table = now_peek_table();
    if (table == NULL) return 0;
    if (table->ext_major == NOW_RESIDENT_VERSION_MAJOR
        && table->ext_minor == NOW_RESIDENT_VERSION_MINOR) return 0;
    snprintf(line, (size_t)cap,
             "Warning: active extension %u.%u; this app expects %d.%d",
             (unsigned)table->ext_major, (unsigned)table->ext_minor,
             NOW_RESIDENT_VERSION_MAJOR, NOW_RESIDENT_VERSION_MINOR);
    return 1;
}
