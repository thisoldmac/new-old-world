/* Native test for the Files pane's pull presentation. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src/files files_pull_test.c \
          ../src/files/files_pull.c -o files_pull_test && ./files_pull_test

   Three things are worth testing away from a Macintosh, and they are the
   three that would otherwise be discovered by a person watching a real
   transfer over MacTCP take four minutes:

     - Stop is armed exactly when stopping is a thing that can happen,
       and NOT when the pane could only pretend. A button that reports
       its own absence is worse than no button.
     - The percentage survives a big file. `received * 100` overflows a
       32-bit long at 21.5 MB, which is an ordinary size to drag off a
       Mac, and the visible symptom would be a percentage that goes
       negative two thirds of the way through a download.
     - Every live phase says something, and says which file. "Getting..."
       with no name and no number is the pane telling a person that
       something is happening to something.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "files_pull.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void check_has(const char *line, const char *needle, const char *what)
{
    if (strstr(line, needle) == NULL) {
        fprintf(stderr, "FAIL: %s (line was \"%s\", wanted \"%s\")\n",
                what, line, needle);
        ++g_failures;
    }
}

static void check_lacks(const char *line, const char *needle, const char *what)
{
    if (strstr(line, needle) != NULL) {
        fprintf(stderr, "FAIL: %s (line was \"%s\")\n", what, line);
        ++g_failures;
    }
}

static int g_cancel_calls;
static int g_cancel_result;

static int fake_cancel(char *err, long cap)
{
    ++g_cancel_calls;
    if (g_cancel_result != 0 && err != NULL && cap > 0) {
        snprintf(err, (size_t)cap, "nothing to stop");
    }
    return g_cancel_result;
}

/* Most of what follows is about arithmetic and wording, where the phase
   is a receiving pull and nothing else. Those cases go through here; the
   cases that are ABOUT the phase call now_pull_observe directly, with
   the receiving flag spelled out. */
static void observe_rx(PullView *v, Boolean active, long received,
                       long expected)
{
    now_pull_observe(v, active, active, received, expected);
}

int main(void)
{
    PullView v;
    char line[160];
    int i;

    /* --- arming ---------------------------------------------------------
       No canceller registered is the state the guest ships in until the
       wire grows the primitive. The pane must offer nothing then: the
       whole point of the defect is that a person was left guessing, and
       a button that cannot stop anything is another way to guess. */
    now_pull_set_canceller(NULL);
    now_pull_reset(&v);
    check(!now_pull_can_stop(&v), "idle cannot be stopped");
    now_pull_asked(&v, "Report.cwk");
    check(!now_pull_can_stop(&v),
          "no canceller registered means no Stop is offered");

    now_pull_set_canceller(fake_cancel);
    check(now_pull_have_canceller(), "a registered canceller is reported");
    check(now_pull_can_stop(&v), "a pull that has only been asked can be stopped");

    /* A live pull the wire calls a question is still a question, however
       long it stands there: this is the 30 s a stalled host leaves a
       person in, and it must not read as a transfer that has started. */
    now_pull_observe(&v, 1, 0, 0, 0);
    check(v.phase == kPullAsking,
          "a wire that has only asked stays Asking, whatever the counts");
    check(now_pull_can_stop(&v), "an unanswered question can be abandoned");

    now_pull_observe(&v, 1, 1, 8192, 65536);
    check(v.phase == kPullReceiving, "the wire opening a file moves Asking to Receiving");
    check(now_pull_can_stop(&v), "a receiving pull can be stopped");

    /* The fact one boolean could not carry: a file is open and not one
       byte has landed, which used to be indistinguishable from an
       unanswered question and read as Asking. */
    now_pull_reset(&v);
    now_pull_asked(&v, "Report.cwk");
    now_pull_observe(&v, 1, 1, 0, 0);
    check(v.phase == kPullReceiving,
          "receiving with nothing yet is receiving, not asking");

    now_pull_stopping(&v);
    check(!now_pull_can_stop(&v),
          "a second press has nothing left to stop");
    observe_rx(&v, 1, 12288, 65536);
    check(v.phase == kPullStopping,
          "Stopping survives chunks still in flight");
    observe_rx(&v, 0, 0, 0);
    check(v.phase == kPullIdle, "the wire going quiet ends the pull");
    check(strcmp(v.name, "Report.cwk") == 0,
          "the name outlives the pull, so a closing line can name it");

    /* A pull this pane did not start is still shown and still stoppable:
       one lane, one transfer, and the person at the machine is the one
       who can see it. */
    now_pull_reset(&v);
    now_pull_observe(&v, 1, 0, 0, 0);
    check(v.phase == kPullAsking, "a live pull the wire has only asked reads as asking");
    now_pull_reset(&v);
    now_pull_observe(&v, 1, 1, 4096, 40960);
    check(v.phase == kPullReceiving, "a live pull already receiving reads as receiving");

    /* --- the percentage -------------------------------------------------- */
    now_pull_reset(&v);
    now_pull_asked(&v, "big");
    check(now_pull_percent(&v) == -1, "unknown size has no percentage");
    observe_rx(&v, 1, 0, 1000);
    check(now_pull_percent(&v) == 0, "no bytes yet is 0%");
    observe_rx(&v, 1, 500, 1000);
    check(now_pull_percent(&v) == 50, "half is 50%");
    observe_rx(&v, 1, 1000, 1000);
    check(now_pull_percent(&v) == 100, "all of it is 100%");

    /* 40 MB, two thirds through. received * 100 is 2.7e9 - past LONG_MAX
       on this guest's 32-bit long - and the naive form reports a
       NEGATIVE percentage here. */
    observe_rx(&v, 1, 28000000L, 42000000L);
    check(now_pull_percent(&v) == 66,
          "a 40 MB file does not overflow the percentage");
    observe_rx(&v, 1, 2000000000L, 2000000000L);
    check(now_pull_percent(&v) == 100, "2 GB does not overflow either");
    observe_rx(&v, 1, 3000, 1000);
    check(now_pull_percent(&v) == 100,
          "more bytes than promised clamps rather than printing nonsense");
    observe_rx(&v, 1, 100, 0);
    check(now_pull_percent(&v) == -1,
          "a sender that gave no size never gets a percentage");

    /* --- the lines ------------------------------------------------------- */
    now_pull_reset(&v);
    now_pull_note(&v, line, sizeof line);
    check(line[0] == '\0', "an idle pane says nothing about transfers");

    now_pull_asked(&v, "Chapter 3");
    now_pull_note(&v, line, sizeof line);
    check_has(line, "Chapter 3", "the asking line names the file");
    check_lacks(line, "0 K",
                "asking does not report a zero that never moves");

    observe_rx(&v, 1, 51200, 512000);
    now_pull_note(&v, line, sizeof line);
    check_has(line, "Chapter 3", "the progress line names the file");
    check_has(line, "10%", "the progress line carries the percentage");
    check_has(line, "500 K", "the progress line carries the size");

    observe_rx(&v, 1, 51200, 0);
    now_pull_note(&v, line, sizeof line);
    check_has(line, "50 K", "with no size, the count still moves");
    check_lacks(line, "%", "with no size, no percentage is invented");

    /* 900 bytes is 1 K, not 0 K: a transfer that reports zero looks like
       a transfer that never started. */
    observe_rx(&v, 1, 900, 0);
    now_pull_note(&v, line, sizeof line);
    check_has(line, "1 K", "a sub-K count rounds up rather than reading zero");

    now_pull_stopping(&v);
    now_pull_note(&v, line, sizeof line);
    check_has(line, "Stopping", "the gap between the press and the quiet is said");
    check_has(line, "Chapter 3", "even the stopping line names the file");

    now_pull_stopped_note(&v, line, sizeof line);
    check_has(line, "Chapter 3", "the closing line names the file");
    check_has(line, "nothing was kept",
              "the closing line says what was left behind");

    /* A pull with no name at all still produces a sentence rather than a
       hole where a name should be. */
    now_pull_reset(&v);
    now_pull_asked(&v, NULL);
    now_pull_note(&v, line, sizeof line);
    check(line[0] != '\0', "a nameless pull still says something");
    now_pull_stopped_note(&v, line, sizeof line);
    check(line[0] != '\0', "a nameless pull still closes with something");

    /* Every live phase produces a line. Nothing here is allowed to be
       the state where the pane goes quiet mid-transfer. */
    for (i = kPullAsking; i <= kPullStopping; ++i) {
        now_pull_reset(&v);
        now_pull_asked(&v, "x");
        v.phase = (PullPhase)i;
        now_pull_note(&v, line, sizeof line);
        check(line[0] != '\0', "every live phase says something");
    }

    /* --- the repaint gate ------------------------------------------------ */
    now_pull_reset(&v);
    check(now_pull_step(&v) == 0, "idle is step zero");
    now_pull_asked(&v, "x");
    check(now_pull_step(&v) != 0, "starting a pull changes the step");
    {
        long a, b;

        observe_rx(&v, 1, 100000, 10000000L);
        a = now_pull_step(&v);
        observe_rx(&v, 1, 104000, 10000000L);
        check(now_pull_step(&v) == a,
              "a chunk inside the same percent does not repaint");
        observe_rx(&v, 1, 200000, 10000000L);
        check(now_pull_step(&v) != a, "a whole percent repaints");

        /* Unknown size falls back to 4 K buckets, which is what the pane
           animated from before any of this. */
        observe_rx(&v, 1, 4096, 0);
        b = now_pull_step(&v);
        observe_rx(&v, 1, 5000, 0);
        check(now_pull_step(&v) == b, "under 4 K of movement does not repaint");
        observe_rx(&v, 1, 9000, 0);
        check(now_pull_step(&v) != b, "past 4 K repaints");

        /* A phase change repaints even when the counts stand still. */
        a = now_pull_step(&v);
        now_pull_stopping(&v);
        check(now_pull_step(&v) != a, "pressing Stop repaints");
    }

    /* --- the canceller is called, and its refusal is passed on ----------- */
    {
        char err[64];

        now_pull_set_canceller(fake_cancel);
        g_cancel_calls = 0;
        g_cancel_result = 0;
        err[0] = '\0';
        check(now_pull_cancel(err, sizeof err) == 0 && g_cancel_calls == 1,
              "the registered canceller is the one that runs");
        g_cancel_result = -1;
        err[0] = '\0';
        check(now_pull_cancel(err, sizeof err) == -1 && err[0] != '\0',
              "a refusal arrives with something to show a person");

        /* With none registered the answer is a refusal WITH A REASON,
           not a silent zero. A cancel that reports success and stops
           nothing is the worst outcome available here: the pane would
           say the transfer was stopped while the file kept arriving. */
        now_pull_set_canceller(NULL);
        g_cancel_calls = 0;
        err[0] = '\0';
        check(now_pull_cancel(err, sizeof err) == -1,
              "no canceller is a refusal, never a silent success");
        check(err[0] != '\0', "and the refusal says why");
        check(g_cancel_calls == 0, "nothing was called");
    }
    now_pull_set_canceller(NULL);
    now_pull_reset(&v);
    observe_rx(&v, 1, 1, 2);
    check(!now_pull_can_stop(&v),
          "unregistering takes the button away again");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("files_pull: all checks passed\n");
    return EXIT_SUCCESS;
}
