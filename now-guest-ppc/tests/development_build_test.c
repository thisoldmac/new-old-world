#include "development_build.h"

#include <assert.h>
#include <string.h>

typedef struct Submitted {
    int count;
    char job[kDevIdentityCap];
    int index;
    char command[kDevBuildCommandCap];
} Submitted;

static int submit(const char *job, int index, const char *command, void *ctx)
{
    Submitted *seen = (Submitted *)ctx;
    seen->count++;
    strcpy(seen->job, job);
    seen->index = index;
    strcpy(seen->command, command);
    return 1;
}

int main(void)
{
    DevBuildPlan plan;
    DevBuildService service;
    DevToolchain toolchain;
    Submitted seen;
    memset(&plan, 0, sizeof plan);
    strcpy(plan.configuration, "debug");
    strcpy(plan.product_type, "APPL");
    strcpy(plan.product_creator, "MMTR");
    memset(&toolchain, 0, sizeof toolchain);
    memset(&seen, 0, sizeof seen);
    strcpy(toolchain.id, "mpw-1-2");
    strcpy(toolchain.version, "structural-1");
    toolchain.state = kDevToolchainQualified;

    assert(dev_build_plan_add(&plan, "compile", "Sources/Main.c",
                              "Objects/Main.o"));
    assert(dev_build_plan_add(&plan, "link", "Objects/Main.o",
                              "Build/Memory Meter"));
    assert(!dev_build_plan_add(&plan, "shell", "Delete -y :", "Build/X"));
    assert(!dev_build_plan_add(&plan, "compile", "../Main.c", "Build/X"));
    assert(!dev_build_plan_add(&plan, "compile", "Sources/Bad\".c",
                               "Build/X"));

    assert(dev_build_service_begin(&service, "job-one", &plan, &toolchain));
    assert(dev_build_service_tick(&service, submit, &seen));
    assert(seen.count == 1 && seen.index == 0);
    assert(strcmp(seen.command,
        "MrC \"Sources:Main.c\" -o \"Objects:Main.o\" -proto strict -w 2 -sym on -opt off") == 0);
    assert(dev_build_service_complete(&service, "job-one", 0, 0,
                                      "compiled\r"));
    assert(dev_build_service_tick(&service, submit, &seen));
    assert(strstr(seen.command, "PPCLink") == seen.command);
    assert(strstr(seen.command, "StdCRuntime.o") != NULL);
    assert(strstr(seen.command, "-t 'APPL' -c 'MMTR' -mf") != NULL);

    assert(dev_build_service_cancel(&service));
    assert(service.job.state == kDevJobCancelled);
    assert(!dev_build_service_complete(&service, "job-one", 1, 0,
                                       "late output"));

    memset(&seen, 0, sizeof seen);
    assert(dev_build_service_begin(&service, "job-two", &plan, &toolchain));
    assert(dev_build_service_tick(&service, submit, &seen));
    assert(dev_build_service_complete(&service, "job-two", 0, 0, "one\r"));
    assert(dev_build_service_tick(&service, submit, &seen));
    assert(dev_build_service_complete(&service, "job-two", 1, 0, "two\r"));
    assert(dev_build_service_tick(&service, submit, &seen));
    assert(service.job.state == kDevJobSucceeded);
    assert(strcmp(service.transcript, "one\rtwo\r") == 0);
    assert(!dev_build_service_complete(&service, "job-one", 0, 0, "late"));
    return 0;
}
