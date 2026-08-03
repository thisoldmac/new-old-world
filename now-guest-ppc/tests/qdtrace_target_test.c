/* Toolbox-free proof of qdtrace start's selector and precedence rules. */
#include "qdtrace_target.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int got, int want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %d, want %d\n", what, got, want);
        failures++;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
        failures++;
    }
}

int main(void)
{
    NowQDTarget target;

    target = now_qdtrace_pick_target(0, 1, 1, 0, 0);
    check(target, kNowQDTargetSerial, "complete serial");
    check_str(now_qdtrace_target_route_name(target), "serial", "serial route");

    target = now_qdtrace_pick_target(0, 0, 0, 1, 1);
    check(target, kNowQDTargetFront, "front true");
    check_str(now_qdtrace_target_route_name(target), "front", "front route");

    target = now_qdtrace_pick_target(1, 0, 0, 0, 0);
    check(target, kNowQDTargetA5, "raw a5 fallback");
    check_str(now_qdtrace_target_route_name(target), "a5", "a5 route");

    check(now_qdtrace_pick_target(0, 0, 0, 0, 0), kNowQDTargetNone,
          "no selector");
    check(now_qdtrace_pick_target(0, 0, 0, 1, 0), kNowQDTargetNone,
          "front false is not a selector");
    check(now_qdtrace_pick_target(0, 1, 0, 0, 0), kNowQDTargetBadSerial,
          "serialHi without serialLo");
    check(now_qdtrace_pick_target(0, 0, 1, 0, 0), kNowQDTargetBadSerial,
          "serialLo without serialHi");
    check(now_qdtrace_pick_target(1, 1, 0, 1, 1), kNowQDTargetBadSerial,
          "half serial remains malformed beside other selectors");
    check(now_qdtrace_pick_target(1, 1, 1, 1, 1), kNowQDTargetSerial,
          "serial wins over front and a5");
    check(now_qdtrace_pick_target(1, 0, 0, 1, 1), kNowQDTargetFront,
          "front wins over a5");
    check(now_qdtrace_pick_target(1, 0, 0, 1, 0), kNowQDTargetA5,
          "a5 remains reachable beside front false");

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    puts("ok");
    return 0;
}
