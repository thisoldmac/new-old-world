/* The stage refusal must carry the candidate it minted: without the
   ID in the refusal payload, MCP cannot address stage-status or
   stage-discard and a failed stage leaves unaddressable guest residue
   (open-issues, 2026-08-09 PowerBook attempt). */

#include "development_stage_reply.h"

#include <assert.h>
#include <string.h>

int main(void)
{
    char out[512];

    /* A refusal that knows its candidate names it, beside the error. */
    dev_stage_refusal_reply(out, sizeof out, 7, "candidate-unavailable",
                            "The verified candidate could not be sealed.",
                            "candidate-0123456789abcdef");
    assert(strstr(out, "\"ok\":false") != NULL);
    assert(strstr(out, "\"code\":\"candidate-unavailable\"") != NULL);
    assert(strstr(out,
        "\"output\":{\"development-stage\":"
        "[[\"Candidate\",\"candidate-0123456789abcdef\"]]}") != NULL);
    assert(strstr(out, "could not be sealed") != NULL);

    /* No candidate was ever addressed: no output block, plain error. */
    dev_stage_refusal_reply(out, sizeof out, 8, "candidate-unavailable",
                            "The candidate request is malformed.", "");
    assert(strstr(out, "\"ok\":false") != NULL);
    assert(strstr(out, "output") == NULL);
    assert(strstr(out, "Candidate") == NULL);

    dev_stage_refusal_reply(out, sizeof out, 9, "candidate-unavailable",
                            "The candidate request is malformed.", NULL);
    assert(strstr(out, "output") == NULL);

    /* A caller-supplied ID crosses escaped, never raw. */
    dev_stage_refusal_reply(out, sizeof out, 10, "candidate-unavailable",
                            "The candidate was not found.",
                            "candidate-\"quoted\"");
    assert(strstr(out, "candidate-\\\"quoted\\\"") != NULL);

    return 0;
}
