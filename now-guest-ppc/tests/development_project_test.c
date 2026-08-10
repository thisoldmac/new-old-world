#include "development_project.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static const char minimal[] =
    "CKPROJECT 1\r"
    "id=0123456789abcdef0123456789abcdef\r"
    "name=Memory Meter\r"
    "target=application\r"
    "configuration=debug\r"
    "toolchain=mpw-golden@3.6\r"
    "product=Build/Memory Meter\r"
    "type=APPL\r"
    "creator=MMTR\r"
    "file=Sources/Main.c\r";

int main(void)
{
    DevProject project;
    char reason[128];
    char with_action[2048];
    assert(dev_project_parse(minimal, &project, reason, sizeof reason));
    assert(strcmp(project.id,
                  "0123456789abcdef0123456789abcdef") == 0);
    assert(strcmp(project.toolchain_id, "mpw-golden") == 0);
    assert(strcmp(project.toolchain_version, "3.6") == 0);
    assert(strcmp(project.product, "Build/Memory Meter") == 0);
    assert(strcmp(project.product_type, "APPL") == 0);
    assert(strcmp(project.product_creator, "MMTR") == 0);
    assert(project.file_count == 1);

    snprintf(with_action, sizeof with_action, "%s%s", minimal,
             "build-action=compile|Sources/Main.c|Objects/Main.o\r");
    assert(dev_project_parse(with_action, &project, reason, sizeof reason));
    assert(project.build.count == 1);
    assert(project.build.actions[0].kind == kDevActionCompile);

    assert(!dev_project_parse(
        "CKPROJECT 1\nid=project-name\nname=X\ntarget=app\n"
        "configuration=debug\ntoolchain=mpw@1\nproduct=Build/X\n"
        "file=Sources/Main.c\n", &project, reason, sizeof reason));
    assert(strstr(reason, "project id") != NULL);

    assert(!dev_project_parse(
        "CKPROJECT 1\nid=0123456789abcdef0123456789abcdef\nname=X\ntarget=app\nconfiguration=debug\n"
        "toolchain=mpw@1\nproduct=../Outside\nfile=Sources/Main.c\n",
        &project, reason, sizeof reason));
    assert(strstr(reason, "product path") != NULL);
    assert(!dev_project_parse(
        "CKPROJECT 2\nid=0123456789abcdef0123456789abcdef\nname=X\ntarget=app\nconfiguration=debug\n"
        "toolchain=mpw@1\nproduct=Build/X\nfile=Sources/Main.c\n",
        &project, reason, sizeof reason));
    assert(!dev_project_parse(
        "CKPROJECT 1\nid=0123456789abcdef0123456789abcdef\nname=X\ntarget=app\nconfiguration=debug\n"
        "toolchain=mpw@1\nproduct=Build/Hello World Emulator Forks\n"
        "type=APPL\ncreator=TEST\nfile=Sources/Main.c\n"
        "build-action=link|Build/Main.o|Build/Hello World Emulator Forks\n",
        &project, reason, sizeof reason));
    assert(strstr(reason, ".xcoff") != NULL);
    return 0;
}
