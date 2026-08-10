#include "update_install.h"

#include <Files.h>
#include <Folders.h>
#include <Processes.h>

#include <stdio.h>
#include <string.h>

static NowUpdateQuitRequest g_quit_request;
static FSSpec g_relaunch_spec;
static Boolean g_relaunch;

void now_update_set_quit_request(NowUpdateQuitRequest request)
{
    g_quit_request = request;
}

static int current_application(FSSpec *out)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;

    if (GetCurrentProcess(&psn) != noErr) return 0;
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processAppSpec = out;
    return GetProcessInformation(&psn, &info) == noErr;
}

int now_update_destination(NowUpdateComponent component,
                           short *vref, long *dir, const char **leaf,
                           char *reason, long cap)
{
    FSSpec current;
    OSErr err;

    if (component == kNowUpdateApplication) {
        if (!current_application(&current)) {
            snprintf(reason, (size_t)cap,
                     "could not locate the running application");
            return 0;
        }
        *vref = current.vRefNum;
        *dir = current.parID;
        *leaf = "New Old World Update";
        return 1;
    }
    err = FindFolder(kOnSystemDisk, kExtensionFolderType, kCreateFolder,
                     vref, dir);
    if (err != noErr) {
        snprintf(reason, (size_t)cap,
                 "could not locate the Extensions folder (%d)", (int)err);
        return 0;
    }
    *leaf = "NOW Extension Update";
    return 1;
}

static int finder_identity(const FSSpec *spec, OSType type, OSType creator)
{
    CInfoPBRec pb;
    Str63 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;
    return PBGetCatInfoSync(&pb) == noErr
        && pb.hFileInfo.ioFlFndrInfo.fdType == type
        && pb.hFileInfo.ioFlFndrInfo.fdCreator == creator;
}

static int find_extension(const FSSpec *excluding, FSSpec *out)
{
    CInfoPBRec pb;
    Str63 name;
    short index;

    for (index = 1;; ++index) {
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = excluding->vRefNum;
        pb.hFileInfo.ioDirID = excluding->parID;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) break;
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0
            || pb.hFileInfo.ioFlFndrInfo.fdType != 'INIT'
            || pb.hFileInfo.ioFlFndrInfo.fdCreator != 'NOWx') continue;
        out->vRefNum = excluding->vRefNum;
        out->parID = excluding->parID;
        memcpy(out->name, name, name[0] + 1);
        if (EqualString(out->name, excluding->name, false, true)) continue;
        return 1;
    }
    return 0;
}

static void make_inert(const FSSpec *spec)
{
    CInfoPBRec pb;
    Str63 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    if (PBGetCatInfoSync(&pb) != noErr) return;
    pb.hFileInfo.ioFlFndrInfo.fdType = 'BINA';
    pb.hFileInfo.ioDirID = spec->parID;
    PBSetCatInfoSync(&pb);
}

int now_update_install(NowUpdateComponent component, const FSSpec *staged,
                       char *reason, long cap)
{
    FSSpec current;
    OSErr err;

    if (component == kNowUpdateApplication) {
        if (!finder_identity(staged, 'APPL', 'NOWo')) {
            snprintf(reason, (size_t)cap,
                     "the downloaded file is not a New Old World app");
            return 0;
        }
        if (!current_application(&current)) {
            snprintf(reason, (size_t)cap,
                     "could not locate the running application");
            return 0;
        }
        err = FSpExchangeFiles(staged, &current);
        if (err != noErr) {
            snprintf(reason, (size_t)cap,
                     "could not exchange the application (%d)", (int)err);
            return 0;
        }
        g_relaunch_spec = current;
        g_relaunch = true;
        if (g_quit_request != NULL) g_quit_request();
        return 1;
    }

    if (!finder_identity(staged, 'INIT', 'NOWx')) {
        snprintf(reason, (size_t)cap,
                 "the downloaded file is not a NOW Extension");
        return 0;
    }
    if (find_extension(staged, &current)) {
        err = FSpExchangeFiles(staged, &current);
        if (err == noErr) make_inert(staged); /* keep rollback, never load it */
    } else {
        Str255 canonical;
        CopyCStringToPascal("NOW Extension", canonical);
        err = FSpRename(staged, canonical);
    }
    if (err != noErr) {
        snprintf(reason, (size_t)cap,
                 "could not replace the NOW Extension (%d)", (int)err);
        return 0;
    }
    return 1;
}

OSErr now_update_relaunch(void)
{
    LaunchParamBlockRec launch;

    if (!g_relaunch) return noErr;
    memset(&launch, 0, sizeof launch);
    launch.launchBlockID = extendedBlock;
    launch.launchEPBLength = extendedBlockLen;
    launch.launchFileFlags = 0;
    launch.launchControlFlags = launchContinue | launchNoFileFlags;
    launch.launchAppSpec = &g_relaunch_spec;
    return LaunchApplication(&launch);
}
