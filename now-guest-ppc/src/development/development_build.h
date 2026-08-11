#ifndef NOW_DEVELOPMENT_BUILD_H
#define NOW_DEVELOPMENT_BUILD_H

#include "development_contract.h"

enum {
    kDevBuildMaxActions = 32,
    kDevBuildPathCap = 256,
    kDevBuildCommandCap = 768,
    kDevBuildTranscriptCap = 2048
};

typedef enum {
    kDevActionCompile = 1,
    kDevActionRez,
    kDevActionLink,
    kDevActionCopy,
    kDevActionStage,
    kDevActionMetadata
} DevActionKind;

typedef struct DevBuildAction {
    DevActionKind kind;
    char input[kDevBuildPathCap];
    char output[kDevBuildPathCap];
} DevBuildAction;

typedef struct DevBuildPlan {
    DevBuildAction actions[kDevBuildMaxActions];
    int count;
    char configuration[64];
    char product_type[5];
    char product_creator[5];
    char project_root[512];
} DevBuildPlan;

typedef int (*DevBuildSubmit)(const char *job_id, int action_index,
                              const char *command, void *context);

typedef struct DevBuildService {
    DevJob job;
    DevBuildPlan plan;
    int next_action;
    int awaiting_action;
    char transcript[kDevBuildTranscriptCap];
    int transcript_truncated;
} DevBuildService;

int dev_build_plan_add(DevBuildPlan *plan, const char *kind,
                       const char *input, const char *output);
int dev_mpw_render_action(const DevBuildPlan *plan,
                          const DevBuildAction *action,
                          char *out, long cap);
int dev_hfs_parent_path(const char *path, char *out, long cap);
int dev_build_service_begin(DevBuildService *service, const char *job_id,
                            const DevBuildPlan *plan,
                            const DevToolchain *toolchain);
int dev_build_service_tick(DevBuildService *service,
                           DevBuildSubmit submit, void *context);
int dev_build_service_complete(DevBuildService *service,
                               const char *job_id, int action_index,
                               int exit_code, const char *output);
int dev_build_service_cancel(DevBuildService *service);

#endif
