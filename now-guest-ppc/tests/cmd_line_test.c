/* Native test for the console line grammar. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src cmd_line_test.c ../src/cmd_line.c \
          ../src/json.c -o cmd_line_test && ./cmd_line_test

   This is the grammar the host console no longer has. It sends the line a
   human typed and nothing else, so everything a person can express in the
   console is expressed HERE — which makes each of these cases a thing the
   other Mac can no longer do for us:

   - `args` and `line` both arriving. The typed caller must win, or a module
     that names its argument gets whatever the console's grammar makes of it.
   - An ABSENT line against an EMPTY one. gestalt answers differently to
     each, so collapsing them silently changes what a module receives.
   - A whole line as one argument. "launch Adobe Photoshop 5.0" is one name;
     splitting on spaces is the bug this replaces.
   - A flag mistaken for the argument. "census --raw pci" must find pci.
   - Flag-prefix collisions: --no-save must not answer to --no, and --depth
     must not be found inside --depth-max.
*/

#include <stdio.h>
#include <string.h>

#include "cmd_line.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL: %s (got \"%s\", want \"%s\")\n",
                what, got, want);
        ++g_failures;
    }
}

/* --- presence ----------------------------------------------------------- */

static void test_presence(void)
{
    char out[64];

    check(now_cmd_line("{\"type\":\"command.request\",\"id\":1,"
                       "\"name\":\"gestalt\"}", out, sizeof out) == 0,
          "a typed call has no line");
    check_str(out, "", "an absent line leaves an empty string");

    check(now_cmd_line("{\"name\":\"gestalt\",\"line\":\"\"}",
                       out, sizeof out) == 1,
          "an EMPTY line is still a line — a human typed a bare command");
    check_str(out, "", "an empty line reads empty");

    check(now_cmd_line("{\"name\":\"ls\",\"line\":\"Lab:Code\"}",
                       out, sizeof out) == 1, "a line was sent");
    check_str(out, "Lab:Code", "the line reads back verbatim");

    /* "lines" must not answer for "line": tail's typed arg sits next to it
       in the same flat frame, and the scanner is first-occurrence-wins. */
    check(now_cmd_line("{\"name\":\"tail\",\"lines\":40}",
                       out, sizeof out) == 0,
          "\"lines\" is not \"line\"");
}

/* --- the whole line as one argument ------------------------------------- */

static void test_arg_rest(void)
{
    char out[64];

    now_cmd_arg_rest("{\"name\":\"launch\","
                     "\"line\":\"Adobe Photoshop 5.0\"}",
                     "target", out, sizeof out);
    check_str(out, "Adobe Photoshop 5.0",
              "a name with spaces is ONE argument");

    now_cmd_arg_rest("{\"name\":\"quit\",\"line\":\"  --all SimpleText  \"}",
                     "target", out, sizeof out);
    check_str(out, "--all SimpleText",
              "leading flags stay in the target — quit parses them");

    /* The typed caller wins: the Software module names its target. */
    now_cmd_arg_rest("{\"name\":\"launch\",\"args\":{\"target\":\"HD:App\"},"
                     "\"line\":\"something else\"}",
                     "target", out, sizeof out);
    check_str(out, "HD:App", "the typed arg wins over the line");

    now_cmd_arg_rest("{\"name\":\"launch\"}", "target", out, sizeof out);
    check_str(out, "", "no arg and no line is empty, not garbage");

    /* Bounded: a line longer than the caller's buffer is truncated, never
       written past. 8 bytes holds 7 characters. */
    now_cmd_arg_rest("{\"line\":\"abcdefghijkl\"}", "target", out, 8);
    check_str(out, "abcdefg", "the copy respects the caller's cap");
}

/* --- one token from a closed set ---------------------------------------- */

static void test_arg_word(void)
{
    char out[32];

    now_cmd_arg_word("{\"name\":\"census\",\"line\":\"pci\"}",
                     "probe", out, sizeof out);
    check_str(out, "pci", "the probe is the first word");

    now_cmd_arg_word("{\"name\":\"census\",\"line\":\"--raw pci\"}",
                     "probe", out, sizeof out);
    check_str(out, "pci", "a flag is skipped, not mistaken for the probe");

    now_cmd_arg_word("{\"name\":\"census\",\"line\":\"\"}",
                     "probe", out, sizeof out);
    check_str(out, "", "an empty line names no probe");

    now_cmd_arg_word("{\"name\":\"census\",\"line\":\"--only\"}",
                     "probe", out, sizeof out);
    check_str(out, "", "a line of nothing but flags names no probe");

    now_cmd_arg_word("{\"name\":\"sw\",\"args\":{\"domain\":\"apps\"},"
                     "\"line\":\"extensions\"}",
                     "domain", out, sizeof out);
    check_str(out, "apps", "the typed arg wins over the line");

    now_cmd_arg_word("{\"name\":\"sw\",\"line\":\"extensions cdevs\"}",
                     "domain", out, sizeof out);
    check_str(out, "extensions", "only the first word is taken");
}

/* --- flags -------------------------------------------------------------- */

static void test_flags(void)
{
    char out[16];

    check(now_cmd_line_word("--full", "--full") == 1, "the only word");
    check(now_cmd_line_word("--depth 8 --no-save", "--no-save") == 1,
          "a trailing flag");
    check(now_cmd_line_word("--no-save-really", "--no-save") == 0,
          "a longer flag must not answer for a shorter one");
    check(now_cmd_line_word("", "--full") == 0, "an empty line has no flags");
    check(now_cmd_line_word("   ", "--full") == 0, "spaces only");

    check(now_cmd_line_flag_value("--depth 8", "--depth", out, sizeof out) == 1,
          "the value follows the flag");
    check_str(out, "8", "--depth 8");

    check(now_cmd_line_flag_value("--bands 4 --depth 16", "--depth",
                                  out, sizeof out) == 1, "a later flag");
    check_str(out, "16", "--depth 16");

    check(now_cmd_line_flag_value("--depth", "--depth", out, sizeof out) == 0,
          "a flag that ends the line has no value");
    check_str(out, "", "and leaves nothing behind");

    check(now_cmd_line_flag_value("--depth-max 8", "--depth",
                                  out, sizeof out) == 0,
          "--depth must not be found inside --depth-max");
}

/* --- a bare count ------------------------------------------------------- */

static void test_int(void)
{
    long n = 0;

    check(now_cmd_line_int("40", &n) == 1 && n == 40, "tail 40");
    check(now_cmd_line_int("", &n) == 0, "no integer");
    check(now_cmd_line_int("--all", &n) == 0, "no integer among flags");
    n = 0;
    check(now_cmd_line_int("abc 12 34", &n) == 1 && n == 12,
          "the FIRST integer wins");
}

/* --- gestalt's argument is itself a flag -------------------------------- */

static void test_first_word(void)
{
    char out[16];

    now_cmd_first_word("--cpu", out, sizeof out);
    check_str(out, "--cpu", "a flag is a first word too");
    now_cmd_first_word("  --memory extra", out, sizeof out);
    check_str(out, "--memory", "leading space skipped, rest dropped");
    now_cmd_first_word("", out, sizeof out);
    check_str(out, "", "nothing in, nothing out");
    now_cmd_first_word(NULL, out, sizeof out);
    check_str(out, "", "NULL is not a crash");
}

/* An HFS name arrives as UTF-8 and must reach the File Manager as MacRoman:
   the line is read with now_json_find_text for the same reason every path
   arg is. "café" is 0x63 0x61 0x66 0xC3 0xA9 on the wire and 0x8E for the
   é here. */
static void test_line_is_text_decoded(void)
{
    char out[32];

    now_cmd_arg_rest("{\"name\":\"ls\",\"line\":\"caf\\u00E9:Notes\"}",
                     "path", out, sizeof out);
    check((unsigned char)out[3] == 0x8E,
          "an escaped é must decode to MacRoman, not stay as \\u00E9");
    check_str(out + 4, ":Notes", "and the rest of the path survives");
}

int main(void)
{
    test_presence();
    test_arg_rest();
    test_arg_word();
    test_flags();
    test_int();
    test_first_word();
    test_line_is_text_decoded();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("cmd_line_test: ok\n");
    return 0;
}
