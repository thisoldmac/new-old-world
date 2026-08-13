#include "update_install.h"

#include <Files.h>
#include <Folders.h>
#include <Processes.h>

#include <stdio.h>
#include <string.h>

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

static OSErr move_to_directory(FSSpec *spec, long directory)
{
    CMovePBRec pb;
    Str63 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.ioNamePtr = name;
    pb.ioVRefNum = spec->vRefNum;
    pb.ioDirID = spec->parID;
    pb.ioNewName = NULL;
    pb.ioNewDirID = directory;
    return PBCatMoveSync(&pb);
}

/* The running application keeps executing after its file is moved. Keeping
   that old file in the Trash makes rollback visible and recoverable, while
   leaving the canonical pathname free for the verified replacement. */
static int move_old_to_trash(FSSpec *spec, Str63 original_name,
                             long *original_dir, char *reason, long cap)
{
    short trash_vref;
    long trash_dir;
    char base[40];
    char candidate[40];
    Str255 pname;
    FSSpec probe;
    OSErr err;
    int suffix;

    *original_dir = spec->parID;
    memcpy(original_name, spec->name, spec->name[0] + 1);
    err = FindFolder(spec->vRefNum, kTrashFolderType, kCreateFolder,
                     &trash_vref, &trash_dir);
    if (err != noErr || trash_vref != spec->vRefNum) {
        snprintf(reason, (size_t)cap,
                 "could not locate this volume's Trash (%d)",
                 (int)(err != noErr ? err : paramErr));
        return 0;
    }
    memcpy(base, spec->name + 1, spec->name[0]);
    base[spec->name[0]] = '\0';
    for (suffix = 1; suffix < 100; ++suffix) {
        if (suffix == 1) {
            snprintf(candidate, sizeof candidate, "%.27s old", base);
        } else {
            snprintf(candidate, sizeof candidate, "%.24s old %d",
                     base, suffix);
        }
        CopyCStringToPascal(candidate, pname);
        if (FSMakeFSSpec(spec->vRefNum, *original_dir, pname, &probe) != noErr
            && FSMakeFSSpec(spec->vRefNum, trash_dir, pname, &probe) != noErr) {
            break;
        }
    }
    if (suffix >= 100) {
        snprintf(reason, (size_t)cap,
                 "could not choose a recoverable name in the Trash");
        return 0;
    }
    err = FSpRename(spec, pname);
    if (err != noErr) {
        snprintf(reason, (size_t)cap,
                 "could not prepare the old item for the Trash (%d)",
                 (int)err);
        return 0;
    }
    memcpy(spec->name, pname, pname[0] + 1);
    err = move_to_directory(spec, trash_dir);
    if (err == noErr) {
        spec->parID = trash_dir;
        return 1;
    }
    if (FSpRename(spec, original_name) == noErr) {
        memcpy(spec->name, original_name, original_name[0] + 1);
        snprintf(reason, (size_t)cap,
                 "could not move the old item to the Trash (%d); it was "
                 "restored in place", (int)err);
    } else {
        snprintf(reason, (size_t)cap,
                 "could not move the old item to the Trash (%d); it remains "
                 "beside the update under a recovery name", (int)err);
    }
    return 0;
}

static int restore_from_trash(FSSpec *old, long original_dir,
                              const Str63 original_name)
{
    if (move_to_directory(old, original_dir) != noErr) return 0;
    old->parID = original_dir;
    if (FSpRename(old, original_name) != noErr) return 0;
    memcpy(old->name, original_name, original_name[0] + 1);
    return 1;
}

static int replace_to_trash(const FSSpec *staged, FSSpec *current,
                            const char *kind, char *reason, long cap)
{
    FSSpec replacement = *staged;
    FSSpec old = *current;
    Str63 original_name;
    long original_dir;
    OSErr err;

    if (!move_old_to_trash(&old, original_name, &original_dir,
                           reason, cap)) return 0;
    err = FSpRename(&replacement, original_name);
    if (err == noErr) return 1;

    if (restore_from_trash(&old, original_dir, original_name)) {
        snprintf(reason, (size_t)cap,
                 "could not put the replacement in place (%d); the old %s "
                 "was restored", (int)err, kind);
    } else {
        snprintf(reason, (size_t)cap,
                 "could not put the replacement in place (%d), and the old "
                 "%s remains in the Trash under a recovery name",
                 (int)err, kind);
    }
    return 0;
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
        return replace_to_trash(staged, &current, "application",
                                reason, cap);
    }

    if (!finder_identity(staged, 'INIT', 'NOWx')) {
        snprintf(reason, (size_t)cap,
                 "the downloaded file is not a NOW Extension");
        return 0;
    }
    if (find_extension(staged, &current)) {
        return replace_to_trash(staged, &current, "NOW Extension",
                                reason, cap);
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
