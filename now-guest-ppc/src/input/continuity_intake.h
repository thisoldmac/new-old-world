#ifndef NOW_CONTINUITY_INTAKE_H
#define NOW_CONTINUITY_INTAKE_H

#include <MacTypes.h>

#include "continuity_udp.h"
#include "peek_table.h"

enum {
    kNowContinuityArmUnsupported = 0,
    kNowContinuityArmOK = 1,
    kNowContinuityArmTransportUnavailable = 2
};

typedef struct {
    long id;                 /* 0 for an unsolicited resident exit */
    NowPeekU32 epoch;
    NowPeekU32 state;
    NowPeekU32 accepted_hz;
    NowPeekU32 exit_reason;
    NowPeekU32 accepted_packets;
    NowPeekU32 stale_packets;
    NowPeekU32 malformed_packets;
    NowPeekU32 applied_position_seq;
    NowPeekU32 applied_button_generation;
} NowContinuityReport;

int now_continuity_arm(long id, unsigned short port,
                       unsigned long nonce_hi, unsigned long nonce_lo,
                       unsigned long epoch, unsigned long requested_hz,
                       unsigned long lease_ticks, int fast_pump,
                       unsigned long tracking_options);
int now_continuity_disarm(long id, unsigned long epoch);
void now_continuity_disconnect(void);
void now_continuity_shutdown(void);
int now_continuity_take_report(NowContinuityReport *out);
unsigned short now_continuity_udp_port(void);
int now_continuity_wants_fast_pump(void);
const char *now_continuity_state_name(unsigned long state);
const char *now_continuity_reason_name(unsigned long reason);

#endif
