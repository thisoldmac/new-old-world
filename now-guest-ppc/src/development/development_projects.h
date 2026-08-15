#ifndef NOW_DEVELOPMENT_PROJECTS_H
#define NOW_DEVELOPMENT_PROJECTS_H

#include <Carbon.h>

#include "development_projects_rows.h"

/* THE one walk of the human-chosen Projects root.
   There were three: development_runtime.c found a project by id, and
   development_candidate.c had a second find-by-id beside the catalog's
   own paging walk. Three copies of "which subfolders hold a readable
   Project.ckp" is the shape of drift AGENTS.md keeps naming - a rule
   about hidden folders or manifest names fixed in one of them leaves the
   other two disagreeing. Everything that needs the walk calls in here. */

typedef enum {
    kDevProjectsRootUnavailable = 0,  /* no Projects folder chosen yet */
    kDevProjectsFound,
    kDevProjectsAbsent
} DevProjectsLookup;

OSErr dev_projects_folder_id(const FSSpec *spec, long *dir_id);

/* Reads one folder's Project.ckp for its opaque identity and human name.
   `name` may be NULL when only the identity is wanted. */
int dev_projects_identity(const FSSpec *folder, long dir_id,
                          char id[kDevProjectsIDCap],
                          char name[kDevProjectsNameCap]);

/* One page of projects from `cursor` onwards. `next` receives the cursor
   to ask for next, or -1 at the end of the root. */
DevProjectsLookup dev_projects_scan(long cursor, DevProjectRow *rows,
                                    int max_rows, int *emitted, long *next);

DevProjectsLookup dev_projects_find(const char *project_id, FSSpec *folder,
                                    long *dir_id);

#endif
