#ifndef NOW_ADB_INJECTION_LOGIC_H
#define NOW_ADB_INJECTION_LOGIC_H

enum {
    kNowADBInjectionIgnored = 0,
    kNowADBInjectionCarrier = 1,
    kNowADBInjectionPhysical = 2
};

typedef struct {
    unsigned classification;
    signed char delta_h;
    signed char delta_v;
    unsigned reached_target;
    unsigned clamped;
} NowADBInjectionResult;

/* Rewrite one standard ADB relative-mouse register-0 packet. Tiny physical
   deltas are an emulator carrier; larger deltas remain untouched so native
   input can revoke Continuity. Button bits are forced released because the
   versioned Cursor Device button path remains their sole authority. */
NowADBInjectionResult now_adb_injection_rewrite(
    unsigned command, unsigned char *packet, unsigned packet_length,
    short current_h, short current_v, short target_h, short target_v);

#endif /* NOW_ADB_INJECTION_LOGIC_H */
