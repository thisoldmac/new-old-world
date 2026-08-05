/* Native test for `hide`'s argument grammar and its outcome vocabulary.
   Runs on the host:

       cc -Wall -Wextra -Werror -I ../src proc_hide_args_test.c \
          ../src/proc_hide_args.c -o proc_hide_args_test \
          && ./proc_hide_args_test

   Two halves, and the second is the one worth having.

   The GRAMMAR is `quit`'s, with `quit`'s trap: the name is the whole rest
   of the line, so "--show" AFTER the name is part of the name, and hiding
   the wrong application because a trailing token looked like a flag is a
   mutation nobody asked for.

   The VOCABULARY is the half that can lie. `hide` mutates a machine and
   then reads the flag back, and every one of its ten outcomes maps to a
   state word, to an error code or none, and to a visibility answer. If
   `ok` and the error code ever disagree, the reply says both "this failed"
   and "this worked"; if an outcome that OBSERVED NOTHING answers "no" to
   "is it visible", the receiver has claimed an effect it did not see -
   which is the entire reason this verb reads IsProcessVisible at all.
   Neither needs a Macintosh to catch. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "proc_hide_args.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* Parses and requires success. */
static ProcHideArgs ok_parse(const char *line, const char *what)
{
    ProcHideArgs a;
    char msg[160];

    msg[0] = '\0';
    if (!now_proc_hide_parse(line, &a, msg, sizeof msg)) {
        fprintf(stderr, "FAIL: %s (refused: %s)\n", what, msg);
        ++g_failures;
        memset(&a, 0, sizeof a);
    }
    return a;
}

/* Parses and requires refusal with a non-empty reason: a refusal nobody
   can read is the same defect as a silent one. */
static void bad_parse(const char *line, const char *what)
{
    ProcHideArgs a;
    char msg[160];

    msg[0] = '\0';
    if (now_proc_hide_parse(line, &a, msg, sizeof msg)) {
        fprintf(stderr, "FAIL: %s (accepted \"%s\")\n", what, line);
        ++g_failures;
        return;
    }
    if (msg[0] == '\0') {
        fprintf(stderr, "FAIL: %s (refused with no reason)\n", what);
        ++g_failures;
    }
}

static void test_grammar(void)
{
    ProcHideArgs a;
    char long_name[80];

    /* The ordinary case: no flag hides, because the verb is called hide. */
    a = ok_parse("SimpleText", "a bare name parses");
    check(strcmp(a.name, "SimpleText") == 0, "name kept verbatim");
    check(a.action == kProcHideActionHide, "no flag means hide");

    /* Spaces need no quotes - the reason flags are leading. */
    a = ok_parse("Apple File Security", "a name with spaces parses whole");
    check(strcmp(a.name, "Apple File Security") == 0, "spaces kept");

    a = ok_parse("  NetPresenz   ", "surrounding whitespace is typing");
    check(strcmp(a.name, "NetPresenz") == 0, "name trimmed both ends");

    a = ok_parse("\"Apple File Security\"", "a quoted name is accepted");
    check(strcmp(a.name, "Apple File Security") == 0, "quotes stripped");

    /* Leading flags. */
    a = ok_parse("--show SimpleText", "--show parses");
    check(a.action == kProcHideActionShow && strcmp(a.name, "SimpleText") == 0,
          "--show + name");

    a = ok_parse("--status Finder", "--status parses");
    check(a.action == kProcHideActionStatus, "--status selects the read");

    a = ok_parse("--show Apple File Security", "a flag then a spaced name");
    check(a.action == kProcHideActionShow
          && strcmp(a.name, "Apple File Security") == 0,
          "flag consumed, whole name kept");

    /* THE TRAP: a flag after the name is part of the name. An application
       really can be called "Disk Copy 4.2"; reading a trailing token as a
       flag would hide something the person did not name. */
    a = ok_parse("SimpleText --show", "a trailing flag is part of the name");
    check(a.action == kProcHideActionHide, "trailing --show is NOT a flag");
    check(strcmp(a.name, "SimpleText --show") == 0,
          "trailing flag kept in the name");

    /* Refusals. */
    bad_parse("", "an empty line is refused");
    bad_parse("   ", "whitespace only is refused");
    bad_parse("--show", "a flag with no name is refused");
    bad_parse("--status", "--status with no name is refused");
    bad_parse("--hide SimpleText", "an unknown flag is refused");
    bad_parse("-s SimpleText", "an unknown short flag is refused");
    /* Two actions on one line: taking the last would be a mutation the
       person did not ask for, so it refuses rather than picks. */
    bad_parse("--show --status Finder", "two actions are refused");
    bad_parse("--status --show Finder", "two actions are refused either way");
    bad_parse("--show --show Finder", "a repeated action is refused");

    /* A Str31 holds 31 characters. 31 is the last name that can match a
       process; 32 cannot match anything, and comparing a truncation would
       hide a DIFFERENT application than the one named. */
    memset(long_name, 'x', sizeof long_name);
    long_name[31] = '\0';
    a = ok_parse(long_name, "31 characters is accepted");
    check((int)strlen(a.name) == 31, "31 characters kept whole");
    long_name[31] = 'x';                  /* put back what the NUL replaced */
    long_name[32] = '\0';
    bad_parse(long_name, "32 characters is refused, not truncated");
}

/* Every outcome the composition can return, so a new one added without a
   row in the three mapping functions is caught here rather than shipping
   as the fallback. */
static const NowProcHideOutcome kEveryOutcome[] = {
    kProcHideHidden, kProcHideShown, kProcHideReadHidden,
    kProcHideReadVisible, kProcHideUnconfirmed, kProcHideNotRunning,
    kProcHideAmbiguous, kProcHideRefused, kProcHideUnavailable,
    kProcHideBadArgs
};
enum { kOutcomeCount = (int)(sizeof kEveryOutcome / sizeof kEveryOutcome[0]) };

static void test_vocabulary(void)
{
    int i, j;

    for (i = 0; i < kOutcomeCount; ++i) {
        NowProcHideOutcome o = kEveryOutcome[i];
        const char *state = now_proc_hide_state(o);
        const char *vis = now_proc_hide_visible_word(o);

        check(state != NULL && state[0] != '\0', "an outcome has no state");
        check(vis != NULL && vis[0] != '\0', "an outcome has no visibility");
        check(strcmp(vis, "yes") == 0 || strcmp(vis, "no") == 0
              || strcmp(vis, "unknown") == 0,
              "visibility is one of yes / no / unknown");
        /* A state word nobody can distinguish is a state word that says
           nothing, and the reply carries it as the whole outcome. */
        for (j = i + 1; j < kOutcomeCount; ++j) {
            check(strcmp(state, now_proc_hide_state(kEveryOutcome[j])) != 0,
                  "two outcomes share one state word");
        }
    }

    /* ok is exactly "the receiver watched the machine in this state". Four
       outcomes, and they are the four that read the flag back. */
    check(now_proc_hide_error(kProcHideHidden) == NULL, "hidden is ok");
    check(now_proc_hide_error(kProcHideShown) == NULL, "shown is ok");
    check(now_proc_hide_error(kProcHideReadHidden) == NULL, "is-hidden is ok");
    check(now_proc_hide_error(kProcHideReadVisible) == NULL,
          "is-visible is ok");

    /* not-running is ok:FALSE, following `front` and not `quit`. quit's
       "nothing by that name" is the state it was asked to produce; this
       verb cannot produce anything from a process that is not there. */
    check(now_proc_hide_error(kProcHideNotRunning) != NULL,
          "not-running must NOT be ok");
    check(now_proc_hide_error(kProcHideUnconfirmed) != NULL,
          "unconfirmed must NOT be ok");
    check(now_proc_hide_error(kProcHideAmbiguous) != NULL,
          "ambiguous must NOT be ok");
    check(now_proc_hide_error(kProcHideRefused) != NULL,
          "refused must NOT be ok");
    check(now_proc_hide_error(kProcHideUnavailable) != NULL,
          "unavailable must NOT be ok");
    check(now_proc_hide_error(kProcHideBadArgs) != NULL,
          "bad-args must NOT be ok");

    /* Every failing outcome carries a DISTINCT code, or a caller cannot
       tell "your CarbonLib is too old" from "that application is not
       running" - the two that most need telling apart, because one is a
       fact about the machine and the other about the request. */
    for (i = 0; i < kOutcomeCount; ++i) {
        const char *a = now_proc_hide_error(kEveryOutcome[i]);

        if (a == NULL) {
            continue;
        }
        for (j = i + 1; j < kOutcomeCount; ++j) {
            const char *b = now_proc_hide_error(kEveryOutcome[j]);

            check(b == NULL || strcmp(a, b) != 0,
                  "two failing outcomes share one error code");
        }
    }

    /* THE ONE THAT MATTERS. An accepted call whose flag did not move
       observed NOTHING, so it must not answer the visibility it asked
       for. "not seen visible" is not "hidden", and a caller that reads it
       as one has been told an effect happened that did not. */
    check(strcmp(now_proc_hide_visible_word(kProcHideUnconfirmed),
                 "unknown") == 0,
          "an unconfirmed hide must not claim the state it asked for");
    check(strcmp(now_proc_hide_visible_word(kProcHideRefused),
                 "unknown") == 0, "a refused hide observed nothing");
    check(strcmp(now_proc_hide_visible_word(kProcHideUnavailable),
                 "unknown") == 0, "an unavailable call observed nothing");
    check(strcmp(now_proc_hide_visible_word(kProcHideNotRunning),
                 "unknown") == 0,
          "a process that is not running has no visibility");

    /* And the four that did observe say what they saw. */
    check(strcmp(now_proc_hide_visible_word(kProcHideHidden), "no") == 0,
          "a confirmed hide reads not visible");
    check(strcmp(now_proc_hide_visible_word(kProcHideReadHidden), "no") == 0,
          "--status on a hidden process reads not visible");
    check(strcmp(now_proc_hide_visible_word(kProcHideShown), "yes") == 0,
          "a confirmed show reads visible");
    check(strcmp(now_proc_hide_visible_word(kProcHideReadVisible), "yes") == 0,
          "--status on a visible process reads visible");
}

int main(void)
{
    test_grammar();
    test_vocabulary();

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("proc_hide_args: all checks passed\n");
    return EXIT_SUCCESS;
}
