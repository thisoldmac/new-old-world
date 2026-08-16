/* The Files page's status line, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/files \
        files_status_test.c ../src/files/files_status.c -o /tmp/t && /tmp/t

   The defect this replaces was not a layout problem. Four concerns wrote
   one buffer, so the last writer won and every earlier one was gone -
   including the ones a person had not read yet. The properties below are
   the ones that make that impossible, and the first is the one worth
   watching fail: a channel clearing must UNCOVER what was underneath,
   which a shared buffer cannot do because the news underneath was
   already overwritten.

   Watched failing (mutations, 2026-08-15): clearing every other channel
   on a write - the old shape, last writer wins - which loses the browse
   line the moment the share line clears; and dropping the
   same-words-are-not-news rule, which lets the link line the page
   rewrites every idle pass step over a complaint. Both aborted on an
   assertion after building and running. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "files_status.h"

static void line_is(const FilesStatus *s, const char *want)
{
    char out[kFilesStatusMax];

    now_files_status_text(s, out, (long)sizeof out);
    if (strcmp(out, want) != 0) {
        printf("status: wanted \"%s\", got \"%s\"\n", want, out);
        assert(0);
    }
}

int main(void)
{
    FilesStatus s;

    now_files_status_reset(&s);

    /* Nothing to say. */
    line_is(&s, "Ready.");
    assert(now_files_status_source(&s) == kFilesStatusChannelCount);

    /* The link is the reason the page is empty, and says so until
       something more specific happens. */
    now_files_status_set(&s, kFilesStatusLink, "Not connected.");
    line_is(&s, "Not connected.");

    /* A complaint outranks the link. */
    now_files_status_set(&s, kFilesStatusBrowse, "That folder is gone.");
    line_is(&s, "That folder is gone.");

    /* Two complaints: the newer one shows, because it answers whatever
       the person just did. */
    now_files_status_set(&s, kFilesStatusShare, "Not shared: read-only.");
    line_is(&s, "Not shared: read-only.");

    /* THE PROPERTY. Clearing the newer complaint uncovers the older one
       - it was never destroyed - rather than falling to "Ready." and
       telling a person everything is fine. */
    now_files_status_set(&s, kFilesStatusShare, "");
    line_is(&s, "That folder is gone.");
    assert(now_files_status_source(&s) == kFilesStatusBrowse);

    /* A file moving outranks every complaint, because it is the only
       channel about right now and it changes on its own. */
    now_files_status_set(&s, kFilesStatusTransfer,
                         "Report.cwk - 340K of 1.2MB (28%)");
    line_is(&s, "Report.cwk - 340K of 1.2MB (28%)");
    assert(now_files_status_source(&s) == kFilesStatusTransfer);

    /* And when it finishes, the unread complaint is still there. */
    now_files_status_set(&s, kFilesStatusTransfer, "");
    line_is(&s, "That folder is gone.");

    /* A channel repeating itself is not news: it must not step over a
       sibling that has something newer to say. The Files page writes the
       link line on every idle pass, so this is the difference between a
       browse error a person can read and one that flickers. */
    now_files_status_set(&s, kFilesStatusShare, "Sending Report.cwk...");
    now_files_status_set(&s, kFilesStatusBrowse, "That folder is gone.");
    line_is(&s, "Sending Report.cwk...");

    /* Clearing something already clear changes nothing. */
    now_files_status_set(&s, kFilesStatusTransfer, NULL);
    line_is(&s, "Sending Report.cwk...");

    /* Everything quiet again, in any order, is the idle line. */
    now_files_status_set(&s, kFilesStatusShare, "");
    now_files_status_set(&s, kFilesStatusBrowse, "");
    now_files_status_set(&s, kFilesStatusLink, "");
    line_is(&s, "Ready.");

    /* A line longer than the channel truncates rather than running off
       the end of it. */
    {
        char big[kFilesStatusMax * 2];
        char out[kFilesStatusMax];

        memset(big, 'x', sizeof big - 1);
        big[sizeof big - 1] = '\0';
        now_files_status_set(&s, kFilesStatusBrowse, big);
        now_files_status_text(&s, out, (long)sizeof out);
        assert(strlen(out) == kFilesStatusMax - 1);
    }

    /* A NULL store answers rather than crashing: the page asks for a
       line every pass, including before it has been created. */
    {
        char out[kFilesStatusMax];

        now_files_status_text(NULL, out, (long)sizeof out);
        assert(strcmp(out, "Ready.") == 0);
        assert(now_files_status_source(NULL) == kFilesStatusChannelCount);
    }

    puts("files_status_test: all passed");
    return 0;
}
