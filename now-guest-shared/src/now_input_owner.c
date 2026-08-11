#include "now_input_owner.h"

static int gOwner;

int now_input_owner_acquire(int owner)
{
    if (owner == kNowInputOwnerNone)
        return 0;
    if (gOwner != kNowInputOwnerNone && gOwner != owner)
        return 0;
    gOwner = owner;
    return 1;
}

void now_input_owner_release(int owner)
{
    if (gOwner == owner)
        gOwner = kNowInputOwnerNone;
}

int now_input_owner_current(void)
{
    return gOwner;
}

void now_input_owner_reset(void)
{
    gOwner = kNowInputOwnerNone;
}
