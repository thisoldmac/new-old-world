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

typedef struct {
    PrefsRecordV6 v6;                 /* format = 7 */
    char share_vol[32];
    long share_dir;
} PrefsRecordV7;

typedef struct {
    PrefsRecordV7 v7;                 /* format = 8 */
    short share_boot;
    char dl_vol[32];
    long dl_dir;
} PrefsRecordV8;

typedef struct {
    PrefsRecordV8 v8;                 /* format = 9 */
    short console_invert;
    short auto_connect;
    short workshop_module;
    Rect workshop_rect;
} PrefsRecordV9;

/* Preferences are per COPY of the app, not per creator. Running two
   guests at once is a real workflow — one for each host, on different
   ports — and a shared file would have them overwrite each other's port
   and share root. The canonical copy keeps the original file name so
   nothing already saved is orphaned; any other copy gets its own,
   named after itself. */
static OSErr prefs_spec(FSSpec *spec)
{
    ProcessSerialNumber self;
    ProcessInfoRec info;
    Str31 app_name;
    Str255 file_name;
    short vref;
    long dirid;
    OSErr err;

    err = FindFolder(kOnSystemDisk, kPreferencesFolderType,
                     kCreateFolder, &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    BlockMoveData("\pNew Old World Prefs", file_name, 21);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = app_name;
    app_name[0] = 0;
    if (GetCurrentProcess(&self) == noErr
        && GetProcessInformation(&self, &info) == noErr
        && app_name[0] > 0
        && !EqualString(app_name, (ConstStr255Param)"\pnow-guest",
                        false, false)) {
        long room = 31 - file_name[0] - 3;

        if (app_name[0] < room) {
            room = app_name[0];
        }
        if (room > 0) {
            file_name[file_name[0] + 1] = ' ';
            file_name[file_name[0] + 2] = '(';
            BlockMoveData(app_name + 1, file_name + file_name[0] + 3,
                          room);
            file_name[file_name[0] + 3 + room] = ')';
            file_name[0] = (unsigned char)(file_name[0] + room + 3);
        }
    }
    return FSMakeFSSpec(vref, dirid, file_name, spec);
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
    prefs->console_invert = false;
    /* Dialing on launch is the established behavior; the checkbox on the
       Connection page is how it is turned off. */
    prefs->auto_connect = true;
    prefs->workshop_module = 1;       /* Screenshots */
    SetRect(&prefs->workshop_rect, 0, 0, 0, 0);
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
    long count = sizeof(PrefsRecordV9);
    PrefsRecordV9 v9;
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
    memset(&v9, 0, sizeof v9);
    err = FSRead(ref, &count, &v9);
    FSClose(ref);
    record = v9.v8.v7.v6.v5.v4.v3;
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
        && v9.v8.v7.v6.v5.v4.retry_secs >= 0 && v9.v8.v7.v6.v5.v4.retry_secs <= 300) {
        prefs->retry_secs = v9.v8.v7.v6.v5.v4.retry_secs;
    }
    if (record.format >= 5 && count >= (long)sizeof(PrefsRecordV5)) {
        prefs->predictive = v9.v8.v7.v6.v5.predictive != 0;
        prefs->interlace = v9.v8.v7.v6.v5.interlace != 0;
    }
    if (record.format >= 6 && count >= (long)sizeof(PrefsRecordV6)) {
        v9.v8.v7.v6.share_root[sizeof v9.v8.v7.v6.share_root - 1] = '\0';
        strcpy(prefs->share_root, v9.v8.v7.v6.share_root);
    }
    if (record.format >= 7 && count >= (long)sizeof(PrefsRecordV7)) {
        v9.v8.v7.share_vol[sizeof v9.v8.v7.share_vol - 1] = '\0';
        strcpy(prefs->share_vol, v9.v8.v7.share_vol);
        prefs->share_dir = v9.v8.v7.share_dir;
    }
    if (record.format >= 8 && count >= (long)sizeof(PrefsRecordV8)) {
        prefs->share_boot = v9.v8.share_boot != 0;
        v9.v8.dl_vol[sizeof v9.v8.dl_vol - 1] = '\0';
        strcpy(prefs->dl_vol, v9.v8.dl_vol);
        prefs->dl_dir = v9.v8.dl_dir;
    }
    if (record.format >= 9 && count >= (long)sizeof(PrefsRecordV9)) {
        prefs->console_invert = v9.console_invert != 0;
        prefs->auto_connect = v9.auto_connect != 0;
        if (v9.workshop_module >= 1 && v9.workshop_module <= 4) {
            prefs->workshop_module = v9.workshop_module;
        }
        prefs->workshop_rect = v9.workshop_rect;
    } else if (prefs->console_open) {
        /* Seed from the old window session: someone who kept the Console
           open wants the Console page, not Screenshots. */
        prefs->workshop_module = 3;
    }
}

OSErr now_prefs_save(const NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV9);
    PrefsRecordV9 v9;
    PrefsRecordV3 record;
    OSErr err;

    memset(&record, 0, sizeof record);
    record.magic = kPrefsMagic;
    record.format = 9;
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
    memset(&v9, 0, sizeof v9);
    v9.v8.v7.v6.v5.v4.v3 = record;
    v9.v8.v7.v6.v5.v4.retry_secs = prefs->retry_secs;
    v9.v8.v7.v6.v5.predictive = prefs->predictive ? 1 : 0;
    v9.v8.v7.v6.v5.interlace = prefs->interlace ? 1 : 0;
    strncpy(v9.v8.v7.v6.share_root, prefs->share_root,
            sizeof v9.v8.v7.v6.share_root - 1);
    strncpy(v9.v8.v7.share_vol, prefs->share_vol,
            sizeof v9.v8.v7.share_vol - 1);
    v9.v8.v7.share_dir = prefs->share_dir;
    v9.v8.share_boot = prefs->share_boot ? 1 : 0;
    strncpy(v9.v8.dl_vol, prefs->dl_vol, sizeof v9.v8.dl_vol - 1);
    v9.v8.dl_dir = prefs->dl_dir;
    v9.console_invert = prefs->console_invert ? 1 : 0;
    v9.auto_connect = prefs->auto_connect ? 1 : 0;
    v9.workshop_module = prefs->workshop_module;
    v9.workshop_rect = prefs->workshop_rect;
    err = FSWrite(ref, &count, &v9);
    if (err == noErr) {
        SetEOF(ref, count);           /* what we wrote, not an older record */
    }
    FSClose(ref);
    return err;
}
