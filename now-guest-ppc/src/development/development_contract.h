#ifndef NOW_DEVELOPMENT_CONTRACT_H
#define NOW_DEVELOPMENT_CONTRACT_H

enum {
    kDevIdentityCap = 40,
    kDevVersionCap = 32
};

typedef enum {
    kDevToolchainUnqualified = 0,
    kDevToolchainQualified,
    kDevToolchainRefused,
    kDevToolchainUnavailable
} DevToolchainState;

typedef struct DevToolchain {
    char id[kDevIdentityCap];
    char version[kDevVersionCap];
    int toolserver_found;
    int compiler_found;
    DevToolchainState state;
} DevToolchain;

typedef enum {
    kDevJobIdle = 0,
    kDevJobQueued,
    kDevJobRunning,
    kDevJobSucceeded,
    kDevJobFailed,
    kDevJobCancelled
} DevJobState;

typedef struct DevJob {
    char id[kDevIdentityCap];
    DevJobState state;
    int terminal;
    int exit_code;
} DevJob;

int dev_project_path_valid(const char *path);
int dev_action_valid(const char *action, const char *input,
                     const char *output);
DevToolchainState dev_toolchain_qualify(DevToolchain *toolchain);
void dev_job_init(DevJob *job, const char *id);
int dev_job_start(DevJob *job);
int dev_job_cancel(DevJob *job);
int dev_job_finish(DevJob *job, const char *id, int exit_code);

#endif
