/* Native test for the command documentation table. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src cmd_help_test.c ../src/cmd_help.c \
          -o cmd_help_test && ./cmd_help_test

   The table is what the wire's `help` command answers, and the host console
   has no command list of its own — so a hole in this table is a hole in the
   only discovery surface there is. What can go wrong away from a Toolbox:

   - A wire row with no usage or summary: `help` renders a blank line and the
     command becomes undiscoverable while still working.
   - A console-local verb marked wire=1: the other side is offered a command
     this Mac answers "unknown-command".
   - A duplicate name: now_command_doc returns the first, and the second's
     documentation is unreachable.

   Whether the wire rows MATCH the dispatch table is checked on the other
   side, in host/Tests/HostTests/CommandRegistryTests.swift, which reads the
   contract, this table and commands.c together — three halves, one test.
*/

#include <stdio.h>
#include <string.h>

#include "cmd_help.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void test_every_row_is_documented(void)
{
    int i;

    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        const NowCommandDoc *d = &kNowCommandDocs[i];

        check(d->name[0] != '\0', "a row has an empty name");
        check(d->summary != NULL && d->summary[0] != '\0', d->name);
        check(d->usage != NULL && d->usage[0] != '\0', d->name);
        /* The usage line must start with the command, or "help launch"
           shows a usage for something else - the kind of copy-paste slip a
           table of near-identical rows invites. */
        check(strncmp(d->usage, d->name, strlen(d->name)) == 0, d->usage);
    }
    check(i > 10, "the table is suspiciously short");
}

static void test_names_are_unique(void)
{
    int i, j;

    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        for (j = i + 1; kNowCommandDocs[j].name != NULL; ++j) {
            check(strcmp(kNowCommandDocs[i].name,
                         kNowCommandDocs[j].name) != 0,
                  kNowCommandDocs[i].name);
        }
    }
}

static void test_lookup(void)
{
    const NowCommandDoc *d = now_command_doc("quit");

    check(d != NULL, "quit has no doc");
    check(d != NULL && d->wire == 1, "quit must be a wire command");
    check(now_command_doc("put") != NULL, "put has no doc");
    check(now_command_doc("put") != NULL
          && now_command_doc("put")->wire == 0,
          "put is console-local and must not be offered on the wire");
    check(now_command_doc("nonesuch") == NULL, "unknown name returned a doc");
    check(now_command_doc(NULL) == NULL, "NULL name returned a doc");
    check(now_command_doc_count() > 10, "count is wrong");
}

/* help must document itself, or the one command a bare console can always
   reach is the one command with no help. */
static void test_help_documents_itself(void)
{
    const NowCommandDoc *d = now_command_doc("help");

    check(d != NULL && d->wire == 1, "help must be a wire command");
}

int main(void)
{
    test_every_row_is_documented();
    test_names_are_unique();
    test_lookup();
    test_help_documents_itself();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("cmd_help_test: ok (%d commands documented)\n",
           now_command_doc_count());
    return 0;
}
