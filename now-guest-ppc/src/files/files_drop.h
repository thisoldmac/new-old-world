#ifndef NOW_FILES_DROP_H
#define NOW_FILES_DROP_H

#include "fileshare.h"

typedef enum {
    kNowMirrorFileNone = 0,
    kNowMirrorFileDesktop,
    kNowMirrorFileFinderWindow,
    kNowMirrorFileFinderFolder,
    kNowMirrorFileApplicationProcess,
    kNowMirrorFileApplicationCreator
} NowMirrorFileTargetKind;

/* A closed semantic identity from Mirror. `path` is an exact absolute HFS
   folder path only for Finder source/destination kinds; the desktop is
   resolved through FindFolder, and applications are addressed by PSN or
   creator. */
typedef struct {
    NowMirrorFileTargetKind kind;
    char path[224];
    char name[64];
    ProcessSerialNumber psn;
    OSType creator;
} NowMirrorFileTarget;

int now_files_mirror_stage(const NowMirrorFileTarget *source,
                           FileContainer container, FileStage *stage);

int now_files_mirror_receive_begin(
    const NowMirrorFileTarget *target, const char *name,
    FileContainer container, long bytes, OSType file_type, OSType creator,
    unsigned long modified, Boolean overwrite, FileReceive *rx);

/* Delivers a settled file to an application target. Finder and desktop
   targets are already complete when the same-folder rename succeeds. */
OSErr now_files_mirror_deliver(const NowMirrorFileTarget *target,
                               const FSSpec *file);

#endif /* NOW_FILES_DROP_H */
