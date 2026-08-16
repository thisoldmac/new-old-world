/* The collapse of the four retired Mirror gates into one master consent.
 *
 * Toolbox-free on purpose: this rule is applied in three places that
 * cannot see each other — the preferences migration on this Mac, the four
 * compatibility fields on the wire, and the host's decode of a guest that
 * predates `enabled` — and the failure it exists to prevent is a consent
 * that WIDENS. Every case below is really one question asked sixteen
 * ways: does anything short of all four say yes?
 */

#include <stdio.h>

#include "mirror_consent.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("  FAIL %s\n", what);
        ++failures;
    }
}

static void test_only_all_four_consents(void)
{
    int bits;
    int consenting = 0;

    for (bits = 0; bits < 16; ++bits) {
        int s = (bits & 1) != 0;
        int f = (bits & 2) != 0;
        int c = (bits & 4) != 0;
        int g = (bits & 8) != 0;
        int got = now_mirror_consent_from_gates(s, f, c, g);

        if (got) ++consenting;
        check(got == (bits == 15),
              "consent exactly when all four gates were on");
    }
    /* Stated as a count as well as a per-case assertion: an implementation
       that answered yes to everything would satisfy neither, but one that
       answered yes to fifteen of sixteen while the loop above short-
       circuited would satisfy only this. */
    check(consenting == 1, "exactly one of the sixteen combinations grants");
}

static void test_non_zero_is_on(void)
{
    /* The stored values are shorts, not booleans: a record written by a
       build that put 2 in a slot must not read as refusal. */
    check(now_mirror_consent_from_gates(2, 7, -1, 99) == 1,
          "any non-zero gate value counts as on");
    check(now_mirror_consent_from_gates(1, 1, 1, 0) == 0,
          "a single zero refuses whatever the others hold");
}

static void test_round_trip_is_the_same_answer(void)
{
    int on = now_mirror_consent_to_gates(1);
    int off = now_mirror_consent_to_gates(0);

    check(on == 1 && off == 0, "the compatibility value IS the master");
    /* The property both halves depend on: a file or message written by a
       current build and read by an older one, then collapsed again by a
       current one, means what it started as. Without it, saving on this
       build and reopening on the previous one would silently withdraw
       consent — which is exactly the surprise the AND rule exists to
       prevent, arriving by the other door. */
    check(now_mirror_consent_from_gates(on, on, on, on) == 1,
          "consent survives a round trip through the retired gates");
    check(now_mirror_consent_from_gates(off, off, off, off) == 0,
          "refusal survives a round trip through the retired gates");
}

int main(void)
{
    printf("mirror_consent_test\n");
    test_only_all_four_consents();
    test_non_zero_is_on();
    test_round_trip_is_the_same_answer();
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("  ok\n");
    return 0;
}
