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
   side, in now-host/Tests/HostTests/CommandRegistryTests.swift, which reads the
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

/* Every detail line is indented two spaces and fits the console.
 *
 * Both properties were broken and neither was visible from the source: two
 * arrays wrote their lines flush-left, so those commands' help rendered
 * against the margin while the other 59 hung under a two-space indent, and
 * nothing said the console is 80 columns wide. console_model.c appends a
 * detail line verbatim, so what is written here is what a person reads.
 */
static void test_detail_lines_are_indented_and_fit(void)
{
    int i, j;

    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        const NowCommandDoc *d = &kNowCommandDocs[i];

        if (d->detail == NULL) {
            continue;
        }
        for (j = 0; d->detail[j] != NULL; ++j) {
            const char *line = d->detail[j];

            /* An empty line is a paragraph break and carries no indent;
               mirror, mirrorlog and cycle all use them, and they are the
               reason this loop tests emptiness before indentation. */
            if (line[0] == '\0') {
                continue;
            }
            check(line[0] == ' ' && line[1] == ' ', d->name);
            check(strlen(line) <= 72, d->name);
        }
    }
}

/* Nothing drawn may carry a byte outside ASCII.
 *
 * docs/guest-ui-start-here.md: a UTF-8 literal renders as mojibake through
 * DrawString, and this table reaches DrawString on this Mac's own console.
 * It carried a U+2014 em dash until 2026-08-20. MacRoman byte values are
 * the supported way to draw a non-ASCII glyph; a source character is not.
 */
static void test_no_high_bytes_reach_the_screen(void)
{
    int i, j;

    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        const NowCommandDoc *d = &kNowCommandDocs[i];
        const char *p;

        for (p = d->summary; *p != '\0'; ++p) {
            check((unsigned char)*p < 0x80, d->name);
        }
        for (p = d->usage; *p != '\0'; ++p) {
            check((unsigned char)*p < 0x80, d->name);
        }
        if (d->detail == NULL) {
            continue;
        }
        for (j = 0; d->detail[j] != NULL; ++j) {
            for (p = d->detail[j]; *p != '\0'; ++p) {
                check((unsigned char)*p < 0x80, d->name);
            }
        }
    }
}

int main(void)
{
    test_every_row_is_documented();
    test_names_are_unique();
    test_lookup();
    test_help_documents_itself();
    test_detail_lines_are_indented_and_fit();
    test_no_high_bytes_reach_the_screen();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("cmd_help_test: ok (%d commands documented)\n",
           now_command_doc_count());
    return 0;
}
