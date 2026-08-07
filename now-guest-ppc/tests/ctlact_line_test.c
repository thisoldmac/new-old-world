/* Native test for ctlact's console grammar.
 *
 *     cc -Wall -Wextra -Werror -I ../src/act \
 *        ctlact_line_test.c ../src/act/ctlact_line.c \
 *        -o ctlact_line_test && ./ctlact_line_test
 *
 * The verb had a help row, a usage string, and no grammar: a person who
 * typed exactly what `help ctlact` printed was told the command requires
 * an element. `CommandParityTests` cannot see that - the verb is present
 * on both faces and merely broken on one - so this is the gate.
 *
 * The one property worth more than the parsing is the HALF POINT. A line
 * with an h and no v must be refused by name. Falling back to "no point"
 * would press the centre of the control while the person watched their
 * own coordinates go by in the reply, and every row would say
 * dispatched. */

#include <stdio.h>
#include <string.h>

#include "ctlact_line.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static const char *kRef = "now-element-0123456789abcdef";

int main(void)
{
    char element[64];
    char json[256];
    long part, h, v;
    int  has_point, half;

    /* The two-argument form: a part code and no point. */
    check(now_ctlact_parse_line("now-element-0123456789abcdef 21", element,
                                (long)sizeof element, &part, &has_point,
                                &h, &v, &half) == 1, "two arguments parse");
    check(strcmp(element, kRef) == 0, "the element is the first word");
    check(part == 21, "the part is the second word");
    check(has_point == 0, "two arguments name no point");

    /* The four-argument form. */
    check(now_ctlact_parse_line("  now-element-0123456789abcdef  0  140 "
                                " 322 ", element, (long)sizeof element,
                                &part, &has_point, &h, &v, &half) == 1,
          "four arguments parse, whatever the spacing");
    check(part == 0, "part 0 is a request, not a missing argument");
    check(has_point == 1 && h == 140 && v == 322, "the point is h then v");

    /* NEGATIVES ARE REAL COORDINATES on a multi-monitor desktop, and a
       menu bar's own rows sit above zero on the second screen. */
    check(now_ctlact_parse_line("now-element-0123456789abcdef 10 -5 -20",
                                element, (long)sizeof element, &part,
                                &has_point, &h, &v, &half) == 1,
          "a negative point parses");
    check(h == -5 && v == -20, "a negative point keeps its sign");

    /* THE HALF POINT, named rather than swallowed. */
    check(now_ctlact_parse_line("now-element-0123456789abcdef 10 140",
                                element, (long)sizeof element, &part,
                                &has_point, &h, &v, &half) == 0,
          "an h with no v is refused");
    check(half == 1, "and it is refused AS a half point");

    /* Malformed and missing. */
    check(now_ctlact_parse_line("now-element-0123456789abcdef", element,
                                (long)sizeof element, &part, &has_point,
                                &h, &v, &half) == 0, "no part is refused");
    check(now_ctlact_parse_line("now-element-0123456789abcdef 21abc",
                                element, (long)sizeof element, &part,
                                &has_point, &h, &v, &half) == 0,
          "a part that is a number with a tail is refused whole");
    check(half == 0, "and that is not a half point");
    check(now_ctlact_parse_line("", element, (long)sizeof element, &part,
                                &has_point, &h, &v, &half) == 0,
          "an empty line is refused");
    check(now_ctlact_parse_line("  ", element, (long)sizeof element, &part,
                                &has_point, &h, &v, &half) == 0,
          "a blank line is refused");

    /* The rebuild: one implementation behind both faces means the line
       becomes the SAME args a typed caller sends. */
    check(now_ctlact_line_request(kRef, 21, 0, 0, 0, json,
                                  (long)sizeof json) == 1,
          "a pointless request rebuilds");
    check(strstr(json, "\"part\":21") != NULL, "and carries the part");
    check(strstr(json, "\"h\":") == NULL,
          "and does NOT invent a point it was not given");
    check(now_ctlact_line_request(kRef, 0, 1, 140, 322, json,
                                  (long)sizeof json) == 1,
          "a pointed request rebuilds");
    check(strstr(json, "\"h\":140") != NULL
          && strstr(json, "\"v\":322") != NULL, "and carries both numbers");
    check(now_ctlact_line_request(kRef, 0, 1, 140, 322, json, 20) == 0,
          "a buffer too small refuses rather than truncating");
    check(json[0] == '\0', "and leaves nothing half-written");
    check(now_ctlact_line_request("has\"a quote", 10, 0, 0, 0, json,
                                  (long)sizeof json) == 0,
          "a reference that is not one this Mac minted is refused");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
