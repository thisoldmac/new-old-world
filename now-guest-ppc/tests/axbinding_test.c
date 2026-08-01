/* Native test for the ported process-lifetime binding cache.

       cc -Wall -Wextra -Werror -I ../src/axwalk axbinding_test.c \
          ../src/axwalk/axbinding.c -o axbinding_test && ./axbinding_test

   The case that matters is the one that cannot be arranged on a real
   machine on demand: a PSN reused by a NEW process that happens to land
   on the same partition. A cache keyed on the number alone would say
   "yes, I know this one" and hand back a binding for an application
   that is gone. */

#include <stdio.h>
#include <string.h>

#include "axbinding.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

int main(void)
{
    NowAxBindingCache cache;
    unsigned long i;

    memset(&cache, 0, sizeof cache);

    check(!now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x2000, 0x1100,
                                  0x2FFF),
          "an empty cache knows nothing");

    now_ax_binding_record(&cache, 0, 7, 0x1000, 0x2000, 0x1100, 0x2FFF);
    check(now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x2000, 0x1100,
                                 0x2FFF),
          "the exact tuple matches");

    /* One field at a time. Each of these is a real way a recycled PSN
       differs from the process the binding was made against. */
    check(!now_ax_binding_matches(&cache, 0, 7, 0x9000, 0x2000, 0x1100,
                                  0x2FFF), "a moved partition does not");
    check(!now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x3000, 0x1100,
                                  0x2FFF), "a resized partition does not");
    check(!now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x2000, 0x1104,
                                  0x2FFF), "a different A5 does not");
    check(!now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x2000, 0x1100,
                                  0x2FFE), "a different stack base does not");
    check(!now_ax_binding_matches(&cache, 0, 8, 0x1000, 0x2000, 0x1100,
                                  0x2FFF), "a different PSN does not");

    /* A PSN of 0/0 is the empty-slot marker, not a process. */
    now_ax_binding_record(&cache, 0, 0, 1, 1, 1, 1);
    check(!now_ax_binding_matches(&cache, 0, 0, 1, 1, 1, 1),
          "a zero PSN is never recorded and never matches");

    /* Re-recording the same PSN REPLACES rather than accumulates, so a
       process whose partition moved leaves no ghost behind. */
    now_ax_binding_record(&cache, 0, 7, 0x5000, 0x2000, 0x5100, 0x6FFF);
    check(now_ax_binding_matches(&cache, 0, 7, 0x5000, 0x2000, 0x5100,
                                 0x6FFF), "the new binding is there");
    check(!now_ax_binding_matches(&cache, 0, 7, 0x1000, 0x2000, 0x1100,
                                  0x2FFF), "and the old one is gone");

    /* Filling and overflowing: the cache evicts rather than refusing,
       and a re-record of a still-present PSN never evicts anything. */
    memset(&cache, 0, sizeof cache);
    for (i = 1; i <= kNowAxBindingMax; i++) {
        now_ax_binding_record(&cache, 0, i, i << 12, 0x1000, i << 12,
                              (i << 12) + 8);
    }
    for (i = 1; i <= kNowAxBindingMax; i++) {
        check(now_ax_binding_matches(&cache, 0, i, i << 12, 0x1000, i << 12,
                                     (i << 12) + 8),
              "every recorded binding survives a full cache");
    }
    now_ax_binding_record(&cache, 0, 99, 0x99000, 0x1000, 0x99000, 0x99008);
    check(now_ax_binding_matches(&cache, 0, 99, 0x99000, 0x1000, 0x99000,
                                 0x99008), "the overflowing entry is stored");
    check(!now_ax_binding_matches(&cache, 0, 1, 1UL << 12, 0x1000,
                                  1UL << 12, (1UL << 12) + 8),
          "and the oldest was evicted, not the newest refused");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axbinding_test: ok\n");
    return 0;
}
