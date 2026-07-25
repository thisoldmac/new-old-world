/* Native test for `quit`'s argument grammar. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src proc_quit_args_test.c \
          ../src/proc_quit_args.c -o proc_quit_args_test \
          && ./proc_quit_args_test

   The grammar is the part of `quit` that can be tested away from a
   Process Manager, and it is the part with a trap in it: the name is the
   whole rest of the line, so "--all" AFTER the name is part of the name,
   and a name of 31 characters is the last one that can match a Str31.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "proc_quit_args.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* Parses and requires success. */
static ProcQuitArgs ok_parse(const char *line, const char *what)
{
    ProcQuitArgs a;
    char msg[160];

    msg[0] = '\0';
    if (!now_proc_quit_parse(line, &a, msg, sizeof msg)) {
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
    ProcQuitArgs a;
    char msg[160];

    msg[0] = '\0';
    if (now_proc_quit_parse(line, &a, msg, sizeof msg)) {
        fprintf(stderr, "FAIL: %s (accepted \"%s\")\n", what, line);
        ++g_failures;
        return;
    }
    if (msg[0] == '\0') {
        fprintf(stderr, "FAIL: %s (refused with no reason)\n", what);
        ++g_failures;
    }
}

int main(void)
{
    ProcQuitArgs a;
    char long_name[80];

    /* The ordinary case, and the defaults it must carry. */
    a = ok_parse("SimpleText", "a bare name parses");
    check(strcmp(a.name, "SimpleText") == 0, "name kept verbatim");
    check(a.all == 0, "no --all by default");
    check(a.confirm == 1, "confirmation is the DEFAULT, not an option");
    check(a.wait_secs == kProcQuitWaitDefault, "default wait");

    /* Spaces need no quotes - the reason flags are leading. */
    a = ok_parse("Apple File Security", "a name with spaces parses whole");
    check(strcmp(a.name, "Apple File Security") == 0, "spaces kept");

    a = ok_parse("  NetPresenz   ", "surrounding whitespace is typing");
    check(strcmp(a.name, "NetPresenz") == 0, "name trimmed both ends");

    a = ok_parse("\"Apple File Security\"", "a quoted name is accepted");
    check(strcmp(a.name, "Apple File Security") == 0, "quotes stripped");

    /* Leading flags. */
    a = ok_parse("--all SimpleText", "--all parses");
    check(a.all == 1 && strcmp(a.name, "SimpleText") == 0, "--all + name");

    a = ok_parse("--no-wait SimpleText", "--no-wait parses");
    check(a.confirm == 0, "--no-wait turns confirmation off");

    a = ok_parse("--wait 12 SimpleText", "--wait N parses");
    check(a.wait_secs == 12 && strcmp(a.name, "SimpleText") == 0,
          "--wait value and name");

    a = ok_parse("--all --wait 3 Apple File Security", "flags then name");
    check(a.all == 1 && a.wait_secs == 3
          && strcmp(a.name, "Apple File Security") == 0,
          "both flags and a spaced name");

    /* The ceiling is ours, so it clamps rather than refusing. */
    a = ok_parse("--wait 999 SimpleText", "an over-long wait parses");
    check(a.wait_secs == kProcQuitWaitMax, "wait clamped to the ceiling");

    /* --wait after --no-wait means the person changed their mind. */
    a = ok_parse("--no-wait --wait 4 SimpleText", "--wait un-says --no-wait");
    check(a.confirm == 1 && a.wait_secs == 4, "confirmation restored");

    /* THE TRAP: a flag after the name is part of the name. An
       application really can be called "Disk Copy 4.2"; treating a
       trailing token as a flag would quit the wrong thing. */
    a = ok_parse("SimpleText --all", "a trailing flag is part of the name");
    check(a.all == 0, "trailing --all is NOT a flag");
    check(strcmp(a.name, "SimpleText --all") == 0, "trailing flag kept in name");

    /* Refusals. */
    bad_parse("", "an empty line is refused");
    bad_parse("   ", "whitespace only is refused");
    bad_parse("--all", "a flag with no name is refused");
    bad_parse("--all --no-wait", "flags with no name are refused");
    bad_parse("--wait SimpleText", "--wait without a number is refused");
    bad_parse("--wait 0 SimpleText", "a zero wait is refused");
    bad_parse("--wait -3 SimpleText", "a negative wait is refused");
    bad_parse("--force SimpleText", "an unknown flag is refused");
    bad_parse("-a SimpleText", "an unknown short flag is refused");

    /* A Str31 holds 31 characters. 31 is the last name that can match a
       process; 32 cannot match anything, and comparing a truncation
       would quit a DIFFERENT application than the one named. */
    memset(long_name, 'x', sizeof long_name);
    long_name[31] = '\0';
    a = ok_parse(long_name, "31 characters is accepted");
    check((int)strlen(a.name) == 31, "31 characters kept whole");
    long_name[31] = 'x';                  /* put back what the NUL replaced */
    long_name[32] = '\0';
    bad_parse(long_name, "32 characters is refused, not truncated");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("proc_quit_args: all checks passed\n");
    return EXIT_SUCCESS;
}
