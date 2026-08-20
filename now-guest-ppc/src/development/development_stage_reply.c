#include "development_stage_reply.h"

#include <stdio.h>

#include "json.h"

/* A refusal that does not fit its buffer is not a smaller refusal - it
   is a truncated frame, which is invalid JSON the peer cannot read at
   all. snprintf reports the length it WANTED; when that does not fit,
   emit the shortest shape this reply has instead of a broken one. */
static int fits(long cap, int written)
{
    return written >= 0 && (long)written < cap;
}

static void short_refusal(char *out, long cap, long id, const char *code)
{
    int n = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"\"}}",
        id, code);

    if (!fits(cap, n) && cap > 0) {
        /* Even the code did not fit. An empty string is at least a
           string; a half-written object is not. */
        out[0] = '\0';
    }
}

void dev_stage_refusal_reply(char *out, long cap, long id,
                             const char *code, const char *reason,
                             const char *candidate_id)
{
    char escaped[220];
    char esc_code[80];
    int written;

    if (out == NULL || cap <= 0) {
        return;
    }
    now_json_escape(reason, escaped, sizeof escaped);
    /* The code crosses escaped like every other value here. It is ours
       today, but a value that is escaped on one path and interpolated
       raw on another is one caller away from writing the quote that
       breaks the frame. */
    now_json_escape(code, esc_code, sizeof esc_code);
    if (candidate_id != NULL && candidate_id[0] != '\0') {
        /* The caller-supplied ID is echoed, escaped, so the refusal
           itself is the recovery handle. */
        char cand[100];
        now_json_escape(candidate_id, cand, sizeof cand);
        written = snprintf(out, (size_t)cap,
            "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
            "\"error\":{\"code\":\"%s\",\"message\":\"%s\"},"
            "\"output\":{\"development-stage\":[[\"Candidate\",\"%s\"]]}}",
            id, esc_code, escaped, cand);
        if (!fits(cap, written)) {
            short_refusal(out, cap, id, esc_code);
        }
        return;
    }
    written = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        id, esc_code, escaped);
    if (!fits(cap, written)) {
        short_refusal(out, cap, id, esc_code);
    }
}
