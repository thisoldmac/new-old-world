/* The system-version decode both guests send in `hello`.
 *
 * WHY THIS TEST EXISTS. `hello.os` became a KEY on 2026-08-07 — the
 * asset-pack store compares it to decide which machine's art belongs to
 * the guest in front of you — and before that it was a hardcoded literal
 * on both guests ("9" on the PowerPC guest, "7.1" on NOW-68K). Making it
 * real meant decoding gestaltSystemVersion, and the two guests ALREADY
 * decoded it, differently, in two places neither of which was on the
 * wire:
 *
 *   - `commands.c :: bcd_version` read the major version as BCD and
 *     dropped a zero bug-fix digit: 0x0910 -> "9.1".
 *   - `census68.c :: fmt_version` read the same byte as a plain number
 *     and always printed three: 0x0710 -> "7.1.0".
 *
 * Both are right for every System either guest has ever run on. A key
 * built from them would still have been wrong, because "9.1" and "9.1.0"
 * are different strings — and the mismatch would have shown up as a pack
 * that silently failed to match its own machine, which is the least
 * debuggable shape a defect can take.
 *
 * So contract/guest_identity.h is the one decode, and this is the test
 * that stops it drifting back. It is compiled by the host cc, which is
 * the point: neither guest's toolchain is needed to check the thing both
 * guests must agree about.
 *
 * WHAT IT CANNOT CHECK: that the guests actually CALL it rather than
 * keeping their own. That is source-shaped and lives in
 * hello_identity_source_test.py, deliberately as a second test rather
 * than a comment here — the same split as now_act_inflight_test.c.
 */

#include <stdio.h>
#include <string.h>

#include "guest_identity.h"

static int failures;

static void expect(long raw, const char *want)
{
    char got[kNowIdentityVersionCap];

    now_identity_system_version(raw, got, (long)sizeof got);
    if (strcmp(got, want) != 0) {
        printf("FAIL: 0x%04lX -> \"%s\", wanted \"%s\"\n", raw, got, want);
        ++failures;
    }
}

int main(void)
{
    /* The two machines this project actually has. 0x0910 is the stage
       image and the PowerBook 1400c's 9.1.0; 0x0710 is NOW-68K's floor. */
    expect(0x0910, "9.1.0");
    expect(0x0710, "7.1.0");

    /* THE SHAPE, asserted on its own. A zero bug-fix digit is PRINTED.
       The PowerPC guest's old formatter dropped it, so this is the
       assertion that fails if somebody reinstates that behaviour for
       looking tidier — it is what makes two senders' strings comparable,
       which is the entire reason the field is typed. */
    expect(0x0900, "9.0.0");
    expect(0x0800, "8.0.0");

    /* Every bug-fix digit reaches the string. 7.5.5 and 7.6.1 are the
       two Systems where the third component is the whole difference. */
    expect(0x0755, "7.5.5");
    expect(0x0761, "7.6.1");
    expect(0x0605, "6.0.5");

    /* THE BCD BOUNDARY, which is the half the two guests disagreed
       about. A high byte of 0x10 is BCD ten, not sixteen. Nothing runs
       here today; it is asserted because "identical for every input we
       have" was exactly the argument that let the two decodes coexist
       unnoticed, and the first input where they part is a value nobody
       would think to try. */
    expect(0x1000, "10.0.0");
    expect(0x1041, "10.4.1");

    /* GESTALT DID NOT ANSWER. Both guests fetch through a `gest_or(sel,
       0)` that yields 0, so this is a real path and not a defensive
       branch. It must say `unknown` — a fact about what we could
       establish — and must NOT say "0.0.0", which is a plausible wrong
       answer that would key a pack to a System nobody runs. */
    expect(0, "unknown");

    /* A BUFFER TOO SMALL NEVER WRITES A PARTIAL VERSION. This is the
       assertion, and the exact string is not: "9.1" is a prefix that
       PARSES, and a key that parses to the wrong System is worse than
       one that refuses to parse at all. So the rule is stated as the
       rule — whatever comes back is not a version — rather than as a
       spelling somebody would "fix" by loosening it.

       Nine bytes holds "unknown" but not "10.4.1"'s successor sizes;
       five holds neither, and falls all the way to the empty string,
       which is the last answer that still cannot be mistaken for a
       version. Both are unreachable from kNowIdentityVersionCap and are
       checked because unreachable code is where a later edit lands. */
    {
        static const long tinyCaps[] = { 9, 5, 2, 1 };
        unsigned i;

        for (i = 0; i < sizeof tinyCaps / sizeof tinyCaps[0]; ++i) {
            char tiny[kNowIdentityVersionCap];
            long cap = tinyCaps[i];

            memset(tiny, '!', sizeof tiny);
            now_identity_system_version(0x0910, tiny, cap);

            if (strcmp(tiny, "9.1.0") == 0) {
                continue;               /* it fit; fine */
            }
            if (strcmp(tiny, kNowIdentityUnknown) != 0
                && tiny[0] != '\0') {
                printf("FAIL: cap %ld gave \"%s\" — not a whole version, "
                       "not \"%s\", not empty\n",
                       cap, tiny, kNowIdentityUnknown);
                ++failures;
            }
            /* And nothing was written past the capacity it was given. */
            if (cap < (long)sizeof tiny && tiny[cap] != '!') {
                printf("FAIL: cap %ld wrote past its buffer\n", cap);
                ++failures;
            }
        }
    }

    /* Zero capacity writes nothing and does not fall off the end. */
    now_identity_system_version(0x0910, NULL, 0);

    if (failures != 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("guest_identity ok\n");
    return 0;
}
