#include "development_stage_reply.h"

#include <stdio.h>

#include "json.h"

void dev_stage_refusal_reply(char *out, long cap, long id,
                             const char *code, const char *reason,
                             const char *candidate_id)
{
    char escaped[220];

    now_json_escape(reason, escaped, sizeof escaped);
    if (candidate_id != NULL && candidate_id[0] != '\0') {
        /* The caller-supplied ID is echoed, escaped, so the refusal
           itself is the recovery handle. */
        char cand[100];
        now_json_escape(candidate_id, cand, sizeof cand);
        snprintf(out, (size_t)cap,
            "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
            "\"error\":{\"code\":\"%s\",\"message\":\"%s\"},"
            "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"]]}}",
            id, code, escaped, cand);
        return;
    }
    snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        id, code, escaped);
}
