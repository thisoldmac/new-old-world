/* What the Files page calls the other machine:
     cc -Wall -Wextra -Werror -I ../src -I ../src/files \
        files_peer_label_test.c ../src/files/files_peer_label.c -o /tmp/t \
        && /tmp/t

   The rule is one line of prose - the host's hostname when it has told
   us one, "Other Mac" when it has not - and it is exactly the kind of
   rule that is read off a running machine only in the state that is
   easiest to reach. Deciding it here means the DISCONNECTED wording is
   proven too, which is the state a person meets first.

   Watched failing (mutation, 2026-08-15): returning the reported name
   unconditionally, which puts an empty heading on a guest that has never
   connected. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "files_peer_label.h"

static void label_is(const char *reported, const char *want)
{
    char out[64];

    now_files_peer_label(reported, out, (long)sizeof out);
    if (strcmp(out, want) != 0) {
        printf("peer label: wanted \"%s\", got \"%s\"\n", want, out);
        assert(0);
    }
}

int main(void)
{
    char out[96];

    /* A name it told us. */
    label_is("Maxbook Pro", "Maxbook Pro");

    /* No name yet: never blank, never "the host". */
    label_is("", "Other Mac");
    label_is(NULL, "Other Mac");
    label_is("   ", "Other Mac");

    /* Leading whitespace is not part of a machine's name. */
    label_is("  Maxbook Pro", "Maxbook Pro");

    /* The two composed strings this page draws, in both states. */
    now_files_their_heading("Maxbook Pro", out, (long)sizeof out);
    assert(strcmp(out, "Their Files - Maxbook Pro") == 0);
    now_files_their_heading("", out, (long)sizeof out);
    assert(strcmp(out, "Their Files - Other Mac") == 0);

    now_files_share_caption("Maxbook Pro", out, (long)sizeof out);
    assert(strcmp(out, "Maxbook Pro can browse everything in here.") == 0);
    now_files_share_caption(NULL, out, (long)sizeof out);
    assert(strcmp(out, "Other Mac can browse everything in here.") == 0);

    /* Nothing this page draws may carry a byte DrawString would render
       as mojibake: MacRoman only, and in practice ASCII. */
    {
        const unsigned char *p;

        now_files_their_heading("Maxbook Pro", out, (long)sizeof out);
        for (p = (const unsigned char *)out; *p != '\0'; ++p) {
            assert(*p < 0x80);
        }
        now_files_share_caption("Maxbook Pro", out, (long)sizeof out);
        for (p = (const unsigned char *)out; *p != '\0'; ++p) {
            assert(*p < 0x80);
        }
    }

    /* A tiny buffer truncates rather than overruns. */
    {
        char tiny[8];

        now_files_peer_label("Maxbook Pro", tiny, (long)sizeof tiny);
        assert(strlen(tiny) == sizeof tiny - 1);
        now_files_their_heading("Maxbook Pro", tiny, (long)sizeof tiny);
        assert(strlen(tiny) == sizeof tiny - 1);
    }

    puts("files_peer_label_test: all passed");
    return 0;
}
