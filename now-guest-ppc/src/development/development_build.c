#include "development_build.h"

#include <stdio.h>
#include <string.h>

static DevActionKind action_kind(const char *name)
{
    if (strcmp(name, "compile") == 0) return kDevActionCompile;
    if (strcmp(name, "rez") == 0) return kDevActionRez;
    if (strcmp(name, "link") == 0) return kDevActionLink;
    if (strcmp(name, "copy") == 0) return kDevActionCopy;
    if (strcmp(name, "stage") == 0) return kDevActionStage;
    if (strcmp(name, "metadata") == 0) return kDevActionMetadata;
    return 0;
}

static int mpw_operand_valid(const char *value)
{
    const unsigned char *p;
    if (!dev_project_path_valid(value)) return 0;
    for (p = (const unsigned char *)value; *p != '\0'; ++p) {
        if (*p == '"' || *p == '\r' || *p == '\n') return 0;
    }
    return 1;
}

int dev_build_plan_add(DevBuildPlan *plan, const char *kind,
                       const char *input, const char *output)
{
    DevBuildAction *action;
    DevActionKind parsed;
    if (plan == NULL || plan->count < 0
        || plan->count >= kDevBuildMaxActions
        || !dev_action_valid(kind, input, output)
        || !mpw_operand_valid(input) || !mpw_operand_valid(output)) return 0;
    if (strlen(input) >= kDevBuildPathCap
        || strlen(output) >= kDevBuildPathCap) return 0;
    parsed = action_kind(kind);
    if (parsed == 0) return 0;
    action = &plan->actions[plan->count++];
    memset(action, 0, sizeof *action);
    action->kind = parsed;
    strcpy(action->input, input);
    strcpy(action->output, output);
    return 1;
}

static int hfs_path(const char *path, char *out, long cap)
{
    long pos = 0;
    const unsigned char *p;
    if (!dev_project_path_valid(path) || cap < 2) return 0;
    for (p = (const unsigned char *)path; *p != '\0'; ++p) {
        if (*p == '"' || *p == '\r' || *p == '\n' || pos + 1 >= cap) {
            return 0;
        }
        out[pos++] = *p == '/' ? ':' : (char)*p;
    }
    out[pos] = '\0';
    return 1;
}

int dev_mpw_render_action(const DevBuildPlan *plan,
                          const DevBuildAction *action,
                          char *out, long cap)
{
    char input[kDevBuildPathCap];
    char output[kDevBuildPathCap];
    const char *symbols;
    const char *optimization;
    int written;
    if (plan == NULL || action == NULL || out == NULL || cap <= 0
        || !hfs_path(action->input, input, sizeof input)
        || !hfs_path(action->output, output, sizeof output)) return 0;
    symbols = strcmp(plan->configuration, "debug") == 0 ? "on" : "off";
    optimization = strcmp(plan->configuration, "debug") == 0
        ? "off" : "speed";
    switch (action->kind) {
    case kDevActionCompile:
        written = snprintf(out, (size_t)cap,
            "MrC \"%s\" -o \"%s\" -proto strict -w 2 -sym %s -opt %s",
            input, output, symbols, optimization);
        break;
    case kDevActionRez:
        written = snprintf(out, (size_t)cap,
            "Rez \"%s\" -o \"%s\" -a -t '%s' -c '%s'",
            input, output, plan->product_type, plan->product_creator);
        break;
    case kDevActionLink:
        written = snprintf(out, (size_t)cap,
            "PPCLink -warn -sym %s -main __cplusstart -o \"%s\" \"%s\" "
            "\"{SharedLibraries}\"InterfaceLib "
            "\"{SharedLibraries}\"StdCLib "
            "\"{SharedLibraries}\"MathLib "
            "\"{PPCLibraries}\"StdCRuntime.o "
            "\"{PPCLibraries}\"PPCCRuntime.o "
            "\"{PPCLibraries}\"MrCPlusLib.o -t '%s' -c '%s' -mf",
            symbols, output, input, plan->product_type,
            plan->product_creator);
        break;
    case kDevActionCopy:
    case kDevActionStage:
        written = snprintf(out, (size_t)cap,
                           "Duplicate -o \"%s\" \"%s\"", output, input);
        break;
    case kDevActionMetadata:
        written = snprintf(out, (size_t)cap,
            "SetFile -t '%s' -c '%s' \"%s\"",
            plan->product_type, plan->product_creator, input);
        break;
    default: return 0;
    }
    return written > 0 && written < cap;
}

static void append_transcript(DevBuildService *service, const char *text)
{
    size_t used;
    size_t room;
    size_t wanted;
    if (text == NULL || text[0] == '\0') return;
    used = strlen(service->transcript);
    room = sizeof service->transcript - used - 1;
    wanted = strlen(text);
    if (wanted > room) {
        wanted = room;
        service->transcript_truncated = 1;
    }
    memcpy(service->transcript + used, text, wanted);
    service->transcript[used + wanted] = '\0';
}

int dev_build_service_begin(DevBuildService *service, const char *job_id,
                            const DevBuildPlan *plan,
                            const DevToolchain *toolchain)
{
    if (service == NULL || job_id == NULL || plan == NULL
        || plan->count <= 0 || plan->count > kDevBuildMaxActions
        || toolchain == NULL || toolchain->state != kDevToolchainQualified) {
        return 0;
    }
    memset(service, 0, sizeof *service);
    service->plan = *plan;
    service->awaiting_action = -1;
    dev_job_init(&service->job, job_id);
    return dev_job_start(&service->job);
}

int dev_build_service_tick(DevBuildService *service,
                           DevBuildSubmit submit, void *context)
{
    char command[kDevBuildCommandCap];
    int index;
    if (service == NULL || submit == NULL
        || service->job.state != kDevJobRunning
        || service->awaiting_action >= 0) return 0;
    if (service->next_action >= service->plan.count) {
        return dev_job_finish(&service->job, service->job.id, 0);
    }
    index = service->next_action;
    if (!dev_mpw_render_action(&service->plan,
                               &service->plan.actions[index],
                               command, sizeof command)
        || !submit(service->job.id, index, command, context)) {
        return dev_job_finish(&service->job, service->job.id, 1);
    }
    service->awaiting_action = index;
    return 1;
}

int dev_build_service_complete(DevBuildService *service,
                               const char *job_id, int action_index,
                               int exit_code, const char *output)
{
    if (service == NULL || job_id == NULL || service->job.terminal
        || strcmp(service->job.id, job_id) != 0
        || action_index != service->awaiting_action) return 0;
    append_transcript(service, output);
    service->awaiting_action = -1;
    if (exit_code != 0) {
        return dev_job_finish(&service->job, job_id, exit_code);
    }
    service->next_action++;
    return 1;
}

int dev_build_service_cancel(DevBuildService *service)
{
    if (service == NULL) return 0;
    return dev_job_cancel(&service->job);
}
