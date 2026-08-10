#include "development_contract.h"

#include <string.h>

int dev_project_path_valid(const char *path)
{
    const char *component;
    const char *p;
    long length = 0;

    if (path == NULL || path[0] == '\0' || path[0] == '/' || path[0] == ':') {
        return 0;
    }
    component = path;
    for (p = path; ; ++p) {
        unsigned char ch = (unsigned char)*p;
        if (ch == '\\' || ch == ':' || (ch != '\0' && ch < 0x20)) {
            return 0;
        }
        if (ch == '/' || ch == '\0') {
            long part = p - component;
            if (part == 0 || component[0] == '.') {
                return 0;
            }
            if (ch == '\0') {
                break;
            }
            component = p + 1;
        }
        if (++length > 1024) {
            return 0;
        }
    }
    return 1;
}

int dev_action_valid(const char *action, const char *input,
                     const char *output)
{
    static const char *const allowed[] = {
        "compile", "rez", "link", "copy", "stage", "metadata"
    };
    unsigned long i;
    int known = 0;

    if (action == NULL) {
        return 0;
    }
    for (i = 0; i < sizeof allowed / sizeof allowed[0]; ++i) {
        if (strcmp(action, allowed[i]) == 0) {
            known = 1;
            break;
        }
    }
    return known && dev_project_path_valid(input)
        && dev_project_path_valid(output);
}

DevToolchainState dev_toolchain_qualify(DevToolchain *toolchain)
{
    if (toolchain == NULL) {
        return kDevToolchainUnavailable;
    }
    if (toolchain->id[0] == '\0' || toolchain->version[0] == '\0') {
        toolchain->state = kDevToolchainUnqualified;
    } else if (!toolchain->toolserver_found || !toolchain->compiler_found) {
        toolchain->state = kDevToolchainRefused;
    } else {
        toolchain->state = kDevToolchainQualified;
    }
    return toolchain->state;
}

void dev_job_init(DevJob *job, const char *id)
{
    memset(job, 0, sizeof *job);
    if (id != NULL) {
        strncpy(job->id, id, sizeof job->id - 1);
    }
    job->state = kDevJobQueued;
}

int dev_job_start(DevJob *job)
{
    if (job == NULL || job->terminal || job->state != kDevJobQueued) {
        return 0;
    }
    job->state = kDevJobRunning;
    return 1;
}

int dev_job_cancel(DevJob *job)
{
    if (job == NULL || job->terminal
        || (job->state != kDevJobQueued && job->state != kDevJobRunning)) {
        return 0;
    }
    job->state = kDevJobCancelled;
    job->terminal = 1;
    return 1;
}

int dev_job_finish(DevJob *job, const char *id, int exit_code)
{
    if (job == NULL || id == NULL || job->terminal
        || job->state != kDevJobRunning || strcmp(job->id, id) != 0) {
        return 0;
    }
    job->terminal = 1;
    job->exit_code = exit_code;
    job->state = exit_code == 0 ? kDevJobSucceeded : kDevJobFailed;
    return 1;
}
