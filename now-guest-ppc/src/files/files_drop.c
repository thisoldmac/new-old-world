#include "files_drop.h"

#include "../processes/proc_roster.h"

#include <string.h>

static int desktop_folder(short *vref, long *dir)
{
    return FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                      vref, dir) == noErr ? kFilesOK : kFilesNotFound;
}

static int absolute_folder(const char *path, short *vref, long *dir)
{
    FSSpec spec;
    CInfoPBRec pb;
    Str255 ppath;
    Str255 name;

    if (path == NULL || path[0] == '\0' || strlen(path) > 255) {
        return kFilesBadPath;
    }
    CopyCStringToPascal(path, ppath);
    if (FSMakeFSSpec(0, 0, ppath, &spec) != noErr) {
        return kFilesNotFound;
    }
    memset(&pb, 0, sizeof pb);
    memcpy(name, spec.name, spec.name[0] + 1);
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = spec.vRefNum;
    pb.dirInfo.ioDrDirID = spec.parID;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr
        || (pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
        return kFilesNotAFolder;
    }
    *vref = spec.vRefNum;
    *dir = pb.dirInfo.ioDrDirID;
    return kFilesOK;
}

static int item_spec(short vref, long dir, const char *name, FSSpec *spec)
{
    Str255 pname;

    if (name == NULL || name[0] == '\0' || strlen(name) > 31
        || strchr(name, ':') != NULL) {
        return kFilesBadPath;
    }
    CopyCStringToPascal(name, pname);
    return FSMakeFSSpec(vref, dir, pname, spec) == noErr
        ? kFilesOK : kFilesNotFound;
}

int now_files_mirror_stage(const NowMirrorFileTarget *source,
                           FileContainer container, FileStage *stage)
{
    short vref;
    long dir;
    FSSpec spec;
    int rc;

    if (source == NULL) return kFilesBadPath;
    switch (source->kind) {
    case kNowMirrorFileDesktop:
        rc = desktop_folder(&vref, &dir);
        break;
    case kNowMirrorFileFinderWindow:
        rc = absolute_folder(source->path, &vref, &dir);
        break;
    default:
        rc = kFilesBadPath;
        break;
    }
    if (rc == kFilesOK) rc = item_spec(vref, dir, source->name, &spec);
    if (rc != kFilesOK) {
        memset(stage, 0, sizeof *stage);
        return rc;
    }
    return now_files_stage_spec(&spec, container, stage);
}

int now_files_mirror_receive_begin(
    const NowMirrorFileTarget *target, const char *name,
    FileContainer container, long bytes, OSType file_type, OSType creator,
    unsigned long modified, Boolean overwrite, FileReceive *rx)
{
    short vref;
    long dir;
    int rc;

    if (target == NULL) return kFilesBadPath;
    switch (target->kind) {
    case kNowMirrorFileDesktop:
        rc = desktop_folder(&vref, &dir);
        break;
    case kNowMirrorFileFinderFolder:
        rc = absolute_folder(target->path, &vref, &dir);
        break;
    case kNowMirrorFileApplicationProcess:
    case kNowMirrorFileApplicationCreator:
        rc = now_files_downloads(&vref, &dir);
        break;
    default:
        rc = kFilesBadPath;
        break;
    }
    if (rc != kFilesOK) return rc;
    return now_files_receive_begin_at(
        vref, dir, name, container, bytes, file_type, creator, modified,
        overwrite, NULL, 0, rx);
}

static Boolean process_is(const ProcessSerialNumber *psn, const char *name)
{
    NowProcRosterRow row;
    Str255 expected;

    if (!now_proc_roster_read(psn, &row)) return false;
    if (name == NULL || name[0] == '\0') return true;
    CopyCStringToPascal(name, expected);
    return EqualString(row.pname, expected, false, true);
}

OSErr now_files_mirror_deliver(const NowMirrorFileTarget *target,
                               const FSSpec *file)
{
    AEAddressDesc address = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    AEDescList documents = { typeNull, NULL };
    AliasHandle alias = NULL;
    OSErr err;

    if (target == NULL || file == NULL) return paramErr;
    if (target->kind != kNowMirrorFileApplicationProcess
        && target->kind != kNowMirrorFileApplicationCreator) {
        return noErr;
    }
    if (target->kind == kNowMirrorFileApplicationProcess) {
        if (!process_is(&target->psn, target->name)) return procNotFound;
        err = AECreateDesc(typeProcessSerialNumber, &target->psn,
                           sizeof target->psn, &address);
    } else {
        if (target->creator == 0) return paramErr;
        err = AECreateDesc(typeApplSignature, &target->creator,
                           sizeof target->creator, &address);
    }
    if (err == noErr) {
        err = AECreateAppleEvent(kCoreEventClass, kAEOpenDocuments, &address,
                                 kAutoGenerateReturnID, kAnyTransactionID,
                                 &event);
    }
    if (err == noErr) err = AECreateList(NULL, 0, false, &documents);
    if (err == noErr) err = NewAlias(NULL, file, &alias);
    if (err == noErr && alias != NULL) {
        HLock((Handle)alias);
        err = AEPutPtr(&documents, 1, typeAlias, *(Handle)alias,
                       GetHandleSize((Handle)alias));
        HUnlock((Handle)alias);
    }
    if (err == noErr) {
        err = AEPutParamDesc(&event, keyDirectObject, &documents);
    }
    if (err == noErr) {
        err = AESend(&event, &reply, kAENoReply | kAECanInteract,
                     kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    }
    if (alias != NULL) DisposeHandle((Handle)alias);
    AEDisposeDesc(&documents);
    AEDisposeDesc(&event);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&address);
    return err;
}
