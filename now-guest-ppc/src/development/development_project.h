#ifndef NOW_DEVELOPMENT_PROJECT_H
#define NOW_DEVELOPMENT_PROJECT_H

#include "development_build.h"

enum {
    kDevProjectIDCap = 40,
    kDevProjectNameCap = 65,
    kDevProjectTokenCap = 64,
    kDevProjectMaxFiles = 64
};

typedef struct DevProject {
    char id[kDevProjectIDCap];
    char name[kDevProjectNameCap];
    char target[kDevProjectTokenCap];
    char configuration[kDevProjectTokenCap];
    char toolchain_id[kDevIdentityCap];
    char toolchain_version[kDevVersionCap];
    char product[kDevBuildPathCap];
    char files[kDevProjectMaxFiles][kDevBuildPathCap];
    int file_count;
    DevBuildPlan build;
} DevProject;

int dev_project_parse(const char *text, DevProject *project,
                      char *reason, long reason_cap);

#endif
