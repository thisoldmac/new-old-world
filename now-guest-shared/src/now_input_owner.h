#ifndef NOW_INPUT_OWNER_H
#define NOW_INPUT_OWNER_H

enum {
    kNowInputOwnerNone = 0,
    kNowInputOwnerDrag = 1,
    kNowInputOwnerContinuity = 2
};

int now_input_owner_acquire(int owner);
void now_input_owner_release(int owner);
int now_input_owner_current(void);
void now_input_owner_reset(void);

#endif
