#include "prefs.h"

#include <string.h>

#include "contract.h"
#include "product_identity.h"

#define kPrefsMagic 'NOWp'

typedef struct {
    OSType magic;
    short format;
    unsigned short port;
    char host[64];
} PrefsRecordV1;

typedef struct {
    OSType magic;
    short format;
    unsigned short port;
    char host[64];
    short window_count;
    NowWindowState windows[kNowMaxSavedWindows];
} PrefsRecordV2;

static OSErr prefs_spec(FSSpec *spec)
{
    short vref;
    long dirid;
    OSErr err;

    err = FindFolder(kOnSystemDisk, kPreferencesFolderType,
                     kCreateFolder, &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    return FSMakeFSSpec(vref, dirid,
                        (ConstStr255Param)"\pNew Old World Prefs", spec);
}

void now_prefs_load(NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV2);
    PrefsRecordV2 record;
    OSErr err;
    int i;

    memset(prefs, 0, sizeof *prefs);
    strcpy(prefs->host, "10.0.2.2");
    prefs->port = kNowDefaultHostPort;
    prefs->window_count = -1;

    err = prefs_spec(&spec);
    if (err != noErr && err != fnfErr) {
        return;
    }
    if (FSpOpenDF(&spec, fsRdPerm, &ref) != noErr) {
        return;
    }
    memset(&record, 0, sizeof record);
    err = FSRead(ref, &count, &record);
    FSClose(ref);
    if ((err != noErr && err != eofErr)
        || record.magic != kPrefsMagic || record.port == 0) {
        return;
    }
    if (record.format == 1 && count >= (long)sizeof(PrefsRecordV1)) {
        record.host[sizeof record.host - 1] = '\0';
        strcpy(prefs->host, record.host);
        prefs->port = record.port;
        return;                       /* window_count stays -1: first run */
    }
    if (record.format != 2 || count < (long)sizeof(PrefsRecordV2)) {
        return;
    }
    record.host[sizeof record.host - 1] = '\0';
    strcpy(prefs->host, record.host);
    prefs->port = record.port;
    if (record.window_count >= 0
        && record.window_count <= kNowMaxSavedWindows) {
        prefs->window_count = record.window_count;
        for (i = 0; i < record.window_count; ++i) {
            prefs->windows[i] = record.windows[i];
        }
    }
}

OSErr now_prefs_save(const NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV2);
    PrefsRecordV2 record;
    OSErr err;
    int i;

    memset(&record, 0, sizeof record);
    record.magic = kPrefsMagic;
    record.format = 2;
    record.port = prefs->port;
    strncpy(record.host, prefs->host, sizeof record.host - 1);
    record.window_count = prefs->window_count < 0 ? 0 : prefs->window_count;
    for (i = 0; i < record.window_count && i < kNowMaxSavedWindows; ++i) {
        record.windows[i] = prefs->windows[i];
    }

    err = prefs_spec(&spec);
    if (err != noErr && err != fnfErr) {
        return err;
    }
    err = FSpCreate(&spec, PRODUCT_CREATOR_CODE, 'pref', smSystemScript);
    if (err != noErr && err != dupFNErr) {
        return err;
    }
    err = FSpOpenDF(&spec, fsRdWrPerm, &ref);
    if (err != noErr) {
        return err;
    }
    err = FSWrite(ref, &count, &record);
    if (err == noErr) {
        SetEOF(ref, sizeof record);
    }
    FSClose(ref);
    return err;
}
