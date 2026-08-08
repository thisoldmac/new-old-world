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
    check(target, kNowQDTargetRawA5, "raw a5 is an explicit refusal");
    check_str(now_qdtrace_target_route_name(target), "", "no raw a5 route");

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
    check(now_qdtrace_pick_target(1, 0, 0, 1, 0), kNowQDTargetRawA5,
          "a5 remains an explicit refusal beside front false");

    check(now_qdtrace_process_is_eligible(0), 1,
          "ordinary application is eligible");
    check(now_qdtrace_process_is_eligible(1), 0,
          "Finder is permanently ineligible");

    check(now_qdtrace_target_may_redraw(kNowQDTargetSerial, 1), 1,
          "self selected by serial may redraw");
    check(now_qdtrace_target_may_redraw(kNowQDTargetFront, 1), 1,
          "self selected as front may redraw");
    check(now_qdtrace_target_may_redraw(kNowQDTargetSerial, 0), 0,
          "foreign serial never redraws");
    check(now_qdtrace_target_may_redraw(kNowQDTargetRawA5, 1), 0,
          "raw A5 never proves redraw ownership");

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    puts("ok");
    return 0;
}
