#include "development_project.h"

#include <stdio.h>
#include <string.h>

static int token_valid(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;
    if (*p == '\0') return 0;
    for (; *p != '\0'; ++p) {
        if (!( (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')
            || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')) return 0;
    }
    return 1;
}

static int project_id_valid(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;
    int count = 0;
    for (; *p != '\0'; ++p, ++count) {
        if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) {
            return 0;
        }
    }
    return count == 32;
}

static int version_valid(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;
    if (*p == '\0') return 0;
    for (; *p != '\0'; ++p) {
        if (!( (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')
            || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_'
            || *p == '.')) return 0;
    }
    return 1;
}

static int copy_value(char *dst, long cap, const char *value)
{
    size_t length = strlen(value);
    if (length == 0 || length >= (size_t)cap) return 0;
    memcpy(dst, value, length + 1);
    return 1;
}

static int fourcc_valid(const char *value)
{
    const unsigned char *p = (const unsigned char *)value;
    int count = 0;
    for (; *p != '\0'; ++p, ++count) {
        if (*p < 0x20 || *p > 0x7e || *p == '\'' || *p == '"') return 0;
    }
    return count == 4;
}

static int fail(char *reason, long cap, const char *message)
{
    if (reason != NULL && cap > 0) {
        snprintf(reason, (size_t)cap, "%s", message);
    }
    return 0;
}

static int parse_action(DevBuildPlan *plan, char *value)
{
    char *first = strchr(value, '|');
    char *second;
    if (first == NULL) return 0;
    *first++ = '\0';
    second = strchr(first, '|');
    if (second == NULL || strchr(second + 1, '|') != NULL) return 0;
    *second++ = '\0';
    return dev_build_plan_add(plan, value, first, second);
}

int dev_project_parse(const char *text, DevProject *project,
                      char *reason, long reason_cap)
{
    const char *cursor;
    int line_number = 0;
    if (text == NULL || project == NULL) return fail(
        reason, reason_cap, "project is missing");
    memset(project, 0, sizeof *project);
    cursor = text;
    while (*cursor != '\0') {
        const char *end = cursor;
        char line[1025];
        size_t length;
        char *equals;
        char *key;
        char *value;
        while (*end != '\0' && *end != '\r' && *end != '\n') ++end;
        length = (size_t)(end - cursor);
        if (length >= sizeof line) return fail(
            reason, reason_cap, "project line is too long");
        memcpy(line, cursor, length);
        line[length] = '\0';
        if (*end == '\r' && end[1] == '\n') cursor = end + 2;
        else cursor = *end == '\0' ? end : end + 1;
        line_number++;
        if (line_number == 1) {
            if (strcmp(line, "CKPROJECT 1") != 0) return fail(
                reason, reason_cap, "unsupported project header");
            continue;
        }
        if (line[0] == '\0') continue;
        equals = strchr(line, '=');
        if (equals == NULL || equals == line || equals[1] == '\0') {
            return fail(reason, reason_cap, "invalid project record");
        }
        *equals = '\0'; key = line; value = equals + 1;
        if (strcmp(key, "id") == 0) {
            if (project->id[0] != '\0' || !project_id_valid(value)
                || !copy_value(project->id, sizeof project->id, value)) {
                return fail(reason, reason_cap, "invalid project id");
            }
        } else if (strcmp(key, "name") == 0) {
            if (project->name[0] != '\0'
                || !copy_value(project->name, sizeof project->name, value)) {
                return fail(reason, reason_cap, "invalid project name");
            }
        } else if (strcmp(key, "target") == 0) {
            if (project->target[0] != '\0' || !token_valid(value)
                || !copy_value(project->target, sizeof project->target, value)) {
                return fail(reason, reason_cap, "invalid project target");
            }
        } else if (strcmp(key, "configuration") == 0) {
            if (project->configuration[0] != '\0' || !token_valid(value)
                || !copy_value(project->configuration,
                               sizeof project->configuration, value)) {
                return fail(reason, reason_cap, "invalid configuration");
            }
        } else if (strcmp(key, "toolchain") == 0) {
            char *at = strchr(value, '@');
            if (project->toolchain_id[0] != '\0' || at == NULL
                || strchr(at + 1, '@') != NULL) return fail(
                    reason, reason_cap, "invalid toolchain pin");
            *at++ = '\0';
            if (!token_valid(value) || !version_valid(at)
                || !copy_value(project->toolchain_id,
                               sizeof project->toolchain_id, value)
                || !copy_value(project->toolchain_version,
                               sizeof project->toolchain_version, at)) {
                return fail(reason, reason_cap, "invalid toolchain pin");
            }
        } else if (strcmp(key, "product") == 0) {
            if (project->product[0] != '\0'
                || !dev_project_path_valid(value)
                || !copy_value(project->product,
                               sizeof project->product, value)) return fail(
                    reason, reason_cap, "invalid product path");
        } else if (strcmp(key, "type") == 0) {
            if (project->product_type[0] != '\0' || !fourcc_valid(value)
                || !copy_value(project->product_type,
                               sizeof project->product_type, value)) {
                return fail(reason, reason_cap, "invalid product type");
            }
        } else if (strcmp(key, "creator") == 0) {
            if (project->product_creator[0] != '\0' || !fourcc_valid(value)
                || !copy_value(project->product_creator,
                               sizeof project->product_creator, value)) {
                return fail(reason, reason_cap, "invalid product creator");
            }
        } else if (strcmp(key, "file") == 0) {
            if (project->file_count >= kDevProjectMaxFiles
                || !dev_project_path_valid(value)
                || strcmp(value, "Build") == 0
                || strncmp(value, "Build/", 6) == 0
                || !copy_value(project->files[project->file_count],
                               kDevBuildPathCap, value)) return fail(
                    reason, reason_cap, "invalid source path");
            project->file_count++;
        } else if (strcmp(key, "build-action") == 0) {
            if (!parse_action(&project->build, value)) return fail(
                reason, reason_cap, "invalid build action");
        }
        /* Unknown optional records are deliberately ignored. */
    }
    if (line_number == 0 || project->id[0] == '\0'
        || project->name[0] == '\0' || project->target[0] == '\0'
        || project->configuration[0] == '\0'
        || project->toolchain_id[0] == '\0'
        || project->product[0] == '\0' || project->product_type[0] == '\0'
        || project->product_creator[0] == '\0'
        || project->file_count == 0) {
        return fail(reason, reason_cap, "project is missing required records");
    }
    snprintf(project->build.configuration,
             sizeof project->build.configuration, "%s",
             project->configuration);
    memcpy(project->build.product_type, project->product_type, 5);
    memcpy(project->build.product_creator, project->product_creator, 5);
    return 1;
}
