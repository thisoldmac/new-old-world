#include <stdio.h>
#include <stdlib.h>

#include "peek_lease.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

int main(void)
{
    NowPeekLeaseSet set;

    now_peek_leases_init(&set, 7);
    check(now_peek_leases_union(&set, 10) == 0, "reboot starts dark");
    now_peek_leases_claim(&set, kNowPeekOwnerScene,
                          kNowPeekTableCapAnchors, 10, 20);
    now_peek_leases_claim(&set, kNowPeekOwnerAct,
                          kNowPeekTableCapAnchors | kNowPeekTableCapAct,
                          10, 40);
    check(now_peek_leases_union(&set, 10)
              == (kNowPeekTableCapAnchors | kNowPeekTableCapAct),
          "simultaneous owners publish their union");
    now_peek_leases_release(&set, kNowPeekOwnerScene,
                            kNowPeekTableCapAnchors);
    check(now_peek_leases_union(&set, 11)
              == (kNowPeekTableCapAnchors | kNowPeekTableCapAct),
          "one release cannot disarm another owner");
    check(now_peek_leases_union(&set, 41) == 0,
          "an expired owner is removed");

    now_peek_leases_claim(&set, kNowPeekOwnerContent,
                          kNowPeekTableCapContent, 50, 80);
    now_peek_leases_begin_session(&set, 8);
    check(now_peek_leases_union(&set, 50) == 0,
          "session replacement releases old claims");
    now_peek_leases_claim(&set, kNowPeekOwnerProcesses,
                          kNowPeekTableCapAnchors, 51, 90);
    now_peek_leases_disconnect(&set);
    check(now_peek_leases_union(&set, 51) == 0,
          "disconnect releases all claims");
    now_peek_leases_claim(&set, kNowPeekOwnerCount,
                          kNowPeekTableCapAnchors, 52, 90);
    check(now_peek_leases_union(&set, 52) == 0,
          "unknown owner is refused");

    if (failures != 0) {
        return EXIT_FAILURE;
    }
    puts("peek_lease: all checks passed");
    return EXIT_SUCCESS;
}
