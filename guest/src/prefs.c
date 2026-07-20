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
} PrefsRecordV1;                      /* v2 appended window data; both read
                                         only for host/port now */

typedef struct {
    OSType magic;
    short format;                     /* 3 */
    unsigned short port;
    char host[64];
    short shot_depth;
    short shot_pack;
    short chunk_kb;
    short pace_ms;
    short panel_open;
    short console_open;
    Rect panel_rect;
    Rect console_rect;
} PrefsRecordV3;

typedef struct {
    PrefsRecordV3 v3;                 /* format = 4 */
    short retry_secs;
} PrefsRecordV4;

typedef struct {
    PrefsRecordV4 v4;                 /* format = 5 */
    short predictive;
    short interlace;
} PrefsRecordV5;

typedef struct {
    PrefsRecordV5 v5;                 /* format = 6 */
    char share_root[128];
} PrefsRecordV6;

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

static void set_defaults(NowPrefs *prefs)
{
    memset(prefs, 0, sizeof *prefs);
    strcpy(prefs->host, "10.0.2.2");
    prefs->port = kNowDefaultHostPort;
    prefs->shot_depth = 8;
    prefs->shot_pack = true;
    prefs->chunk_kb = 8;
    prefs->pace_ms = 0;
    prefs->panel_open = true;
    prefs->console_open = false;
    SetRect(&prefs->panel_rect, 0, 0, 0, 0);
    SetRect(&prefs->console_rect, 0, 0, 0, 0);
}

static Boolean valid_depth(short depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

void now_prefs_load(NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV6);
    PrefsRecordV6 v6;
    PrefsRecordV3 record;
    OSErr err;

    set_defaults(prefs);
    err = prefs_spec(&spec);
    if (err != noErr && err != fnfErr) {
        return;
    }
    if (FSpOpenDF(&spec, fsRdPerm, &ref) != noErr) {
        return;
    }
    memset(&v6, 0, sizeof v6);
    err = FSRead(ref, &count, &v6);
    FSClose(ref);
    record = v6.v5.v4.v3;
    if ((err != noErr && err != eofErr)
        || record.magic != kPrefsMagic || record.port == 0) {
        return;
    }
    record.host[sizeof record.host - 1] = '\0';
    strcpy(prefs->host, record.host);
    prefs->port = record.port;
    if (record.format < 3
        || count < (long)sizeof(PrefsRecordV3)) {
        return;                       /* v1/v2: connection only, rest default */
    }
    if (valid_depth(record.shot_depth)) {
        prefs->shot_depth = record.shot_depth;
    }
    prefs->shot_pack = record.shot_pack != 0;
    if (record.chunk_kb >= 1 && record.chunk_kb <= 32) {
        prefs->chunk_kb = record.chunk_kb;
    }
    if (record.pace_ms >= 0 && record.pace_ms <= 100) {
        prefs->pace_ms = record.pace_ms;
    }
    prefs->panel_open = record.panel_open != 0;
    prefs->console_open = record.console_open != 0;
    prefs->panel_rect = record.panel_rect;
    prefs->console_rect = record.console_rect;
    if (record.format >= 4 && count >= (long)sizeof(PrefsRecordV4)
        && v6.v5.v4.retry_secs >= 0 && v6.v5.v4.retry_secs <= 300) {
        prefs->retry_secs = v6.v5.v4.retry_secs;
    }
    if (record.format >= 5 && count >= (long)sizeof(PrefsRecordV5)) {
        prefs->predictive = v6.v5.predictive != 0;
        prefs->interlace = v6.v5.interlace != 0;
    }
    if (record.format >= 6 && count >= (long)sizeof(PrefsRecordV6)) {
        v6.share_root[sizeof v6.share_root - 1] = '\0';
        strcpy(prefs->share_root, v6.share_root);
    }
}

OSErr now_prefs_save(const NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV6);
    PrefsRecordV6 v6;
    PrefsRecordV3 record;
    OSErr err;

    memset(&record, 0, sizeof record);
    record.magic = kPrefsMagic;
    record.format = 6;
    record.port = prefs->port;
    strncpy(record.host, prefs->host, sizeof record.host - 1);
    record.shot_depth = prefs->shot_depth;
    record.shot_pack = prefs->shot_pack ? 1 : 0;
    record.chunk_kb = prefs->chunk_kb;
    record.pace_ms = prefs->pace_ms;
    record.panel_open = prefs->panel_open ? 1 : 0;
    record.console_open = prefs->console_open ? 1 : 0;
    record.panel_rect = prefs->panel_rect;
    record.console_rect = prefs->console_rect;

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
    memset(&v6, 0, sizeof v6);
    v6.v5.v4.v3 = record;
    v6.v5.v4.retry_secs = prefs->retry_secs;
    v6.v5.predictive = prefs->predictive ? 1 : 0;
    v6.v5.interlace = prefs->interlace ? 1 : 0;
    strncpy(v6.share_root, prefs->share_root, sizeof v6.share_root - 1);
    err = FSWrite(ref, &count, &v6);
    if (err == noErr) {
        SetEOF(ref, count);           /* what we wrote, not an older record */
    }
    FSClose(ref);
    return err;
}
