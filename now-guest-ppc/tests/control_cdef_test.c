/* Native test for the documented CDEF-id table.
 *
 *     cc -Wall -Wextra -Werror -I ../src/scene \
 *        control_cdef_test.c ../src/scene/control_cdef.c \
 *        -o control_cdef_test && ./control_cdef_test
 *
 * The table is the whole of what the CDEF route claims, so the test's
 * main job is to hold the two lines that make the claim honest:
 *
 * 1. A FAMILY IS NOT A KIND. CDEF 0 and CDEF 23 each cover push button,
 *    check box and radio button. Returning "button" for all three would
 *    be the plausible wrong answer this arc forbids - a caller would
 *    press a check box and then read its state as if it were a button's.
 *    Every variant is checked separately.
 *
 * 2. AN UNDOCUMENTED ID SAYS NOTHING, and so does an undocumented
 *    VARIANT of a documented id. Several ids that ARE documented are
 *    deliberately absent too - slider, clock, placard - because this
 *    product has no honest role for them, and a near-enough role would
 *    authorise a near-enough act.
 *
 * The ids themselves are not invented here: `procID = 16 * id + variant`
 * and every constant is in ControlDefinitions.h. The test cites the
 * procID beside each row so a reader can check the arithmetic without
 * the header. */

#include <stdio.h>
#include <string.h>

#include "control_cdef.h"

static int g_failures;

static void is_role(short id, short variant, const char *want,
                    const char *what)
{
    const char *got = now_cdef_role(id, variant);

    if (want == NULL) {
        if (got != NULL) {
            fprintf(stderr, "FAIL: %s - said \"%s\", must say nothing\n",
                    what, got);
            ++g_failures;
        }
        return;
    }
    if (got == NULL || strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL: %s - wanted \"%s\", got \"%s\"\n",
                what, want, got == NULL ? "(nothing)" : got);
        ++g_failures;
    }
}

int main(void)
{
    /* THE TWO BUTTON FAMILIES ATTRIBUTE NOTHING, INCLUDING VARIANT 0.
     *
     * This is the whole of what changed on 2026-08-07 and the reason is
     * a measurement, not a scruple: the variation code cannot be read
     * for a control another process owns. Every button-family control
     * in Memory and Date & Time - check boxes and radio buttons among
     * them - reported `contrlDefProc` 0x00002EC8 with a ZERO high byte,
     * and `GetControlVariant` answered 0 for all 65 while answering
     * correctly for controls the guest itself created.
     *
     * So variant 0 here is not a push button. It is the absence of a
     * variant, wearing the push button's number, and mapping it to
     * "button" named every check box and radio button in OS 9's own
     * control panels a push button at knowledge `derived`.
     *
     * The rows for variants 1 to 7 stay, and they are the guard that
     * matters: a later reader who "restores" the family table will
     * reintroduce exactly the shipped bug, so each variant says NULL by
     * name rather than the loop saying nothing about any of them. */
    is_role(0, 0, NULL, "procID 0 - reads as push button, is unreadable");
    is_role(0, 1, NULL, "procID 1 checkBoxProc - the variant never arrives");
    is_role(0, 2, NULL, "procID 2 radioButProc - the variant never arrives");
    is_role(0, 3, NULL, "procID 3 - no such classic variant");

    is_role(23, 0, NULL, "procID 368 - reads as push button, is unreadable");
    is_role(23, 1, NULL, "procID 369 kControlCheckBoxProc");
    is_role(23, 2, NULL, "procID 370 kControlRadioButtonProc");
    is_role(23, 3, NULL, "procID 371 check box auto-toggle");
    is_role(23, 4, NULL, "procID 372 radio button auto-toggle");
    is_role(23, 5, NULL, "procID 373 - undeclared");
    is_role(23, 6, NULL, "procID 374 push button, left icon");
    is_role(23, 7, NULL, "procID 375 push button, right icon");

    /* The three the product came here for. */
    is_role(1, 0, "scrollbar", "procID 16 scrollBarProc");
    is_role(24, 0, "scrollbar", "procID 384 kControlScrollBarProc");
    is_role(24, 2, "scrollbar", "procID 386 live scrolling");
    is_role(24, 1, NULL, "procID 385 - undeclared");
    is_role(8, 0, "tab", "procID 128 large north tab");
    is_role(8, 7, "tab", "procID 135 small west tab");
    is_role(8, 8, NULL, "procID 136 - past the declared tabs");
    is_role(22, 0, "listBox", "procID 352 kControlListBoxProc");
    is_role(22, 1, "listBox", "procID 353 auto-size list box");
    is_role(22, 2, NULL, "procID 354 - undeclared");

    /* The rest of what is claimed. */
    is_role(2, 1, "button", "procID 33 normal bevel button");
    is_role(4, 0, "triangle", "procID 64 disclosure triangle");
    is_role(5, 0, "progress", "procID 80 progress bar");
    is_role(5, 1, NULL, "procID 81 relevance bar - a different indicator");
    is_role(10, 0, "group", "procID 160 group box, text title");
    is_role(10, 6, "group", "procID 166 secondary, popup title");
    is_role(10, 3, NULL, "procID 163 - undeclared");
    is_role(11, 0, "imageWell", "procID 176 image well");
    is_role(16, 0, "userPane", "procID 256 user pane");
    is_role(17, 0, "edit", "procID 272 edit text");
    is_role(17, 2, "edit", "procID 274 password");
    is_role(18, 0, "static", "procID 288 static text");
    is_role(21, 1, "header", "procID 337 list-view window header");
    is_role(25, 0, "popup", "procID 400 popup button");
    is_role(57, 0, "edit", "procID 912 Unicode edit text");
    is_role(63, 0, "popup", "procID 1008 popupMenuProc");

    /* DOCUMENTED AND DELIBERATELY UNMAPPED. Each of these has a constant
       in ControlDefinitions.h, so a future reader will find the id and
       wonder why it is missing: it is missing because the answer would
       have to be a role this product's vocabulary does not contain, and
       an approximate role is an approximate act. */
    is_role(3, 0, NULL, "procID 48 slider - no role for it");
    is_role(6, 0, NULL, "procID 96 little arrows");
    is_role(7, 0, NULL, "procID 112 chasing arrows");
    is_role(9, 0, NULL, "procID 144 separator line");
    is_role(12, 0, NULL, "procID 192 popup arrow");
    is_role(14, 0, NULL, "procID 224 placard");
    is_role(15, 0, NULL, "procID 240 clock");
    is_role(19, 0, NULL, "procID 304 picture");
    is_role(20, 0, NULL, "procID 320 icon");
    is_role(26, 0, NULL, "procID 416 radio group");
    is_role(27, 0, NULL, "procID 432 scroll text box");

    /* Nonsense in, nothing out. A negative variant in particular: the
       walk reads a byte, but the field it lands in is a short and a
       reader must never be able to index this table with one. */
    is_role(999, 0, NULL, "an id no header declares");
    is_role(-1, 0, NULL, "a negative id");
    is_role(0, -1, NULL, "a negative variant");
    is_role(24, 255, NULL, "a variant past every declared one");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
