#include <stdio.h>
#include "now_input_owner.h"

#define CHECK(value) do { if (!(value)) { \
    printf("FAIL line %d\n", __LINE__); return 1; } } while (0)

int main(void)
{
    now_input_owner_reset();
    CHECK(now_input_owner_acquire(kNowInputOwnerDrag));
    CHECK(now_input_owner_acquire(kNowInputOwnerDrag));
    CHECK(!now_input_owner_acquire(kNowInputOwnerContinuity));
    CHECK(now_input_owner_current() == kNowInputOwnerDrag);
    now_input_owner_release(kNowInputOwnerContinuity);
    CHECK(now_input_owner_current() == kNowInputOwnerDrag);
    now_input_owner_release(kNowInputOwnerDrag);
    CHECK(now_input_owner_acquire(kNowInputOwnerContinuity));
    now_input_owner_release(kNowInputOwnerContinuity);
    CHECK(now_input_owner_current() == kNowInputOwnerNone);
    puts("now_input_owner_test: ok");
    return 0;
}
