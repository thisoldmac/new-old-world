#include "development_projects_rows.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static DevProjectRow project(const char *id, const char *name)
{
    DevProjectRow row;
    memset(&row, 0, sizeof row);
    snprintf(row.id, sizeof row.id, "%s", id);
    snprintf(row.name, sizeof row.name, "%s", name);
    return row;
}

int main(void)
{
    DevProjectRow rows[3];
    char out[2048];
    char record[160];
    long length;

    rows[0] = project("0123456789abcdef0123456789abcdef", "Memory Meter");
    rows[1] = project("fedcba9876543210fedcba9876543210", "Disk \"Doctor\"");
    rows[2] = project("00112233445566778899aabbccddeeff", "Pipe|Name");

    /* Identity first: the host splits from the LEFT, so a name carrying a
       pipe must not be able to move the identity. */
    assert(dev_projects_record(record, sizeof record, &rows[2]));
    assert(strcmp(record,
        "00112233445566778899aabbccddeeff|Pipe|Name") == 0);
    assert(strncmp(record, rows[2].id, 32) == 0 && record[32] == '|');
    assert(!dev_projects_record(record, 8, &rows[0]));

    length = dev_projects_reply(out, sizeof out, 7, rows, 3, 24,
                                "0123456789abcdef0123456789abcdef");
    assert(length > 0 && (long)strlen(out) == length);
    assert(strncmp(out,
        "{\"type\":\"command.result\",\"id\":7,\"ok\":true,"
        "\"output\":{\"development-project\":[", 74) == 0);
    assert(strstr(out,
        "[\"Project\",\"0123456789abcdef0123456789abcdef|Memory Meter\"]")
        != NULL);
    /* A quote in a project's name is JSON, not decoration. */
    assert(strstr(out,
        "[\"Project\",\"fedcba9876543210fedcba9876543210|Disk "
        "\\\"Doctor\\\"\"]") != NULL);
    assert(strstr(out,
        "[\"Active\",\"0123456789abcdef0123456789abcdef\"]") != NULL);
    assert(strstr(out, "[\"Next\",\"24\"]]}}") != NULL);

    /* No projects and no active one: still a well-formed answer, and the
       end-of-root cursor. An empty list is an answer, not a refusal. */
    length = dev_projects_reply(out, sizeof out, 9, rows, 0, -1, NULL);
    assert(length > 0);
    assert(strstr(out, "\"development-project\":[[\"Next\",\"-1\"]]}}")
        != NULL);

    /* Active with no rows still separates itself correctly from Next. */
    length = dev_projects_reply(out, sizeof out, 9, rows, 0, -1,
                                "00112233445566778899aabbccddeeff");
    assert(length > 0);
    assert(strstr(out,
        "[[\"Active\",\"00112233445566778899aabbccddeeff\"],"
        "[\"Next\",\"-1\"]]}}") != NULL);

    /* A cap the answer cannot fit is refused rather than truncated: half a
       JSON object on the wire is worse than a missing page. Measured at
       the exact boundary, and one byte either side of it, because a cap
       chosen by eye is caught by whichever length check runs FIRST - and
       the one that matters is the last append, which has no later check
       behind it to notice the overrun. */
    length = dev_projects_reply(out, sizeof out, 7, rows, 1, 24, NULL);
    assert(length > 0);
    assert(dev_projects_reply(out, length + 1, 7, rows, 1, 24, NULL)
           == length);
    assert(dev_projects_reply(out, length, 7, rows, 1, 24, NULL) == 0);
    assert(out[0] == '\0');
    assert(dev_projects_reply(out, 90, 7, rows, 3, 24, NULL) == 0);
    assert(dev_projects_reply(out, 0, 7, rows, 3, 24, NULL) == 0);
    return 0;
}
