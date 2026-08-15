#include "development_projects.h"

#include <stdio.h>
#include <string.h>

#include "development_project.h"
#include "prefs.h"

enum {
    kProjectsMaxIndex = 256,          /* the walk's own bound, as before */
    kProjectsManifestCap = 131072
};

OSErr dev_projects_folder_id(const FSSpec *spec, long *dir_id)
{
    CInfoPBRec pb;
    Str255 name;
    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, spec->name[0] + 1);
    pb.dirInfo.ioNamePtr = name;
    pb.dirInfo.ioVRefNum = spec->vRefNum;
    pb.dirInfo.ioDrDirID = spec->parID;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr
        || (pb.dirInfo.ioFlAttrib & ioDirMask) == 0) return dirNFErr;
    *dir_id = pb.dirInfo.ioDrDirID;
    return noErr;
}

int dev_projects_identity(const FSSpec *folder, long dir_id,
                          char id[kDevProjectsIDCap],
                          char name[kDevProjectsNameCap])
{
    FSSpec manifest;
    short ref = -1;
    long eof, count;
    char *text;
    DevProject *project;
    char reason[120];
    OSErr err = FSMakeFSSpec(folder->vRefNum, dir_id,
        (ConstStr255Param)"\pProject.ckp", &manifest);
    if (err != noErr || FSpOpenDF(&manifest, fsRdPerm, &ref) != noErr) return 0;
    err = GetEOF(ref, &eof);
    if (err != noErr || eof <= 0 || eof >= kProjectsManifestCap) {
        FSClose(ref); return 0;
    }
    text = (char *)NewPtr(eof + 1);
    if (text == NULL) { FSClose(ref); return 0; }
    /* DevProject is far too large for this stack frame on the guest, and
       the walk allocates one per folder it inspects. */
    project = (DevProject *)NewPtr(sizeof *project);
    if (project == NULL) {
        DisposePtr((Ptr)text); FSClose(ref); return 0;
    }
    count = eof;
    err = FSRead(ref, &count, text);
    FSClose(ref);
    if (err == eofErr && count == eof) err = noErr;
    text[eof] = '\0';
    if (err != noErr || !dev_project_parse(text, project,
                                           reason, sizeof reason)) {
        DisposePtr((Ptr)project); DisposePtr((Ptr)text); return 0;
    }
    DisposePtr((Ptr)text);
    /* A manifest id is 32 hex characters and the parser's field is wider
       than that; take exactly what fits rather than letting a malformed
       manifest decide how much of this buffer to use. */
    snprintf(id, kDevProjectsIDCap, "%.32s", project->id);
    if (name != NULL) snprintf(name, kDevProjectsNameCap, "%s", project->name);
    DisposePtr((Ptr)project);
    return 1;
}

DevProjectsLookup dev_projects_scan(long cursor, DevProjectRow *rows,
                                    int max_rows, int *emitted, long *next)
{
    NowPrefs prefs;
    short index;
    int count = 0;
    if (emitted != NULL) *emitted = 0;
    if (next != NULL) *next = -1;
    if (rows == NULL || max_rows <= 0 || cursor < 0
        || cursor > kProjectsMaxIndex) return kDevProjectsRootUnavailable;
    now_prefs_load(&prefs);
    if (prefs.projects_vref == 0 || prefs.projects_dir == 0) {
        return kDevProjectsRootUnavailable;
    }
    for (index = (short)(cursor + 1);
         index <= kProjectsMaxIndex && count < max_rows; ++index) {
        CInfoPBRec pb;
        Str255 name;
        FSSpec folder;
        long dir_id;
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = prefs.projects_vref;
        pb.dirInfo.ioDrDirID = prefs.projects_dir;
        pb.dirInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            index = (short)(kProjectsMaxIndex + 1);
            break;
        }
        /* A leading period is the classic convention for a folder the
           Finder does not show; the candidate staging area uses it. */
        if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0 || name[1] == '.') continue;
        folder.vRefNum = prefs.projects_vref;
        folder.parID = prefs.projects_dir;
        memcpy(folder.name, name, name[0] + 1);
        if (dev_projects_folder_id(&folder, &dir_id) != noErr) continue;
        memset(&rows[count], 0, sizeof rows[count]);
        if (!dev_projects_identity(&folder, dir_id, rows[count].id,
                                   rows[count].name)) continue;
        count++;
    }
    if (emitted != NULL) *emitted = count;
    if (next != NULL) {
        *next = index <= kProjectsMaxIndex ? (long)(index - 1) : -1;
    }
    return count > 0 ? kDevProjectsFound : kDevProjectsAbsent;
}

DevProjectsLookup dev_projects_find(const char *project_id, FSSpec *folder,
                                    long *dir_id)
{
    NowPrefs prefs;
    short index;
    if (project_id == NULL || project_id[0] == '\0' || folder == NULL
        || dir_id == NULL) return kDevProjectsAbsent;
    now_prefs_load(&prefs);
    if (prefs.projects_vref == 0 || prefs.projects_dir == 0) {
        return kDevProjectsRootUnavailable;
    }
    for (index = 1; index <= kProjectsMaxIndex; ++index) {
        CInfoPBRec pb;
        Str255 name;
        char found[kDevProjectsIDCap];
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = prefs.projects_vref;
        pb.dirInfo.ioDrDirID = prefs.projects_dir;
        pb.dirInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) break;
        if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0 || name[1] == '.') continue;
        folder->vRefNum = prefs.projects_vref;
        folder->parID = prefs.projects_dir;
        memcpy(folder->name, name, name[0] + 1);
        if (dev_projects_folder_id(folder, dir_id) == noErr
            && dev_projects_identity(folder, *dir_id, found, NULL)
            && strcmp(found, project_id) == 0) return kDevProjectsFound;
    }
    return kDevProjectsAbsent;
}
