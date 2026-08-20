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

    /* No candidate was ever addressed: no output block, plain error.
       The frame must also be WHOLE - "output" is equally absent from a
       reply that ran out of buffer before it got there, and this
       assertion passed on one for as long as nothing checked the end. */
    dev_stage_refusal_reply(out, sizeof out, 8, "candidate-unavailable",
                            "The candidate request is malformed.", "");
    assert(strstr(out, "\"ok\":false") != NULL);
    assert(strstr(out, "output") == NULL);
    assert(strstr(out, "Candidate") == NULL);
    assert(out[strlen(out) - 1] == '}');
    assert(strstr(out, "malformed.\"}}") != NULL);

    dev_stage_refusal_reply(out, sizeof out, 9, "candidate-unavailable",
                            "The candidate request is malformed.", NULL);
    assert(strstr(out, "output") == NULL);

    /* A caller-supplied ID crosses escaped, never raw. */
    dev_stage_refusal_reply(out, sizeof out, 10, "candidate-unavailable",
                            "The candidate was not found.",
                            "candidate-\"quoted\"");
    assert(strstr(out, "candidate-\\\"quoted\\\"") != NULL);

    /* So does the CODE. It is ours today and a quote in it would end
       the error object early - the frame parses as something else
       entirely rather than failing loudly. */
    dev_stage_refusal_reply(out, sizeof out, 11, "bad\"code",
                            "Refused.", "");
    assert(strstr(out, "bad\\\"code") != NULL);
    assert(strstr(out, "\"bad\"code\"") == NULL);

    /* A cap too small for the whole reply emits the short shape, not
       half an object. A truncated frame is not a smaller refusal: it is
       one the host cannot parse at all, and it is what an unchecked
       snprintf leaves behind. */
    {
        char small[120];
        long i;

        for (i = 0; i < (long)sizeof small; ++i) {
            small[i] = 'X';           /* nothing is trusted to be written */
        }
        dev_stage_refusal_reply(small, sizeof small, 12,
                                "candidate-unavailable",
                                "The verified candidate could not be "
                                "sealed, and here is a great deal more "
                                "about why not.",
                                "candidate-0123456789abcdef");
        assert(strlen(small) < sizeof small);
        assert(strstr(small, "\"id\":12") != NULL);
        assert(strstr(small, "\"code\":\"candidate-unavailable\"") != NULL);
        assert(small[strlen(small) - 1] == '}');
        assert(strstr(small, "\"message\":\"\"}}") != NULL);
    }

    /* Smaller than even the short shape: an empty string rather than a
       fragment, because a caller reading this buffer must never find
       the beginning of a frame that has no end. */
    {
        char tiny[16];

        dev_stage_refusal_reply(tiny, sizeof tiny, 13, "refused", "no", "");
        assert(tiny[0] == '\0');
    }

    return 0;
}
