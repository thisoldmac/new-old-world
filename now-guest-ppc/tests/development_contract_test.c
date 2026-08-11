#include "development_contract.h"

#include <assert.h>
#include <string.h>

int main(void)
{
    DevJob job;
    DevToolchain toolchain;

    assert(dev_project_path_valid("Sources/Main.c"));
    assert(dev_project_path_valid("Build/Memory Meter"));
    assert(!dev_project_path_valid("../Outside.c"));
    assert(!dev_project_path_valid("Sources/.private/Main.c"));
    assert(!dev_project_path_valid("Sources//Main.c"));
    assert(!dev_project_path_valid("/System Folder/Finder"));
    assert(!dev_project_path_valid("Sources:Main.c"));

    assert(dev_action_valid("compile", "Sources/Main.c", "Objects/Main.o"));
    assert(dev_action_valid("rez", "Resources/App.r", "Objects/App.rsrc"));
    assert(dev_action_valid("link", "Objects/Main.o", "Build/App"));
    assert(!dev_action_valid("shell", "Delete -y :", "Build/App"));
    assert(!dev_action_valid("compile", "../Main.c", "Objects/Main.o"));

    memset(&toolchain, 0, sizeof toolchain);
    strcpy(toolchain.id, "toolchain-01234567");
    strcpy(toolchain.version, "3.6");
    toolchain.toolserver_found = 1;
    toolchain.compiler_found = 1;
    assert(dev_toolchain_qualify(&toolchain) == kDevToolchainQualified);
    toolchain.compiler_found = 0;
    assert(dev_toolchain_qualify(&toolchain) == kDevToolchainRefused);

    dev_job_init(&job, "job-01234567");
    assert(dev_job_start(&job));
    assert(dev_job_cancel(&job));
    assert(job.state == kDevJobCancelled);
    assert(!dev_job_finish(&job, "job-01234567", 0));
    assert(!dev_job_finish(&job, "job-other", 0));

    dev_job_init(&job, "job-89abcdef");
    assert(dev_job_start(&job));
    assert(dev_job_finish(&job, "job-89abcdef", 0));
    assert(job.state == kDevJobSucceeded);
    assert(!dev_job_finish(&job, "job-89abcdef", 1));
    return 0;
}
