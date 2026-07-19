#ifndef NOW_WIRE_H
#define NOW_WIRE_H

#include <Carbon.h>

enum {
    kNowTestOK = 0,
    kNowTestNoCarbonLib = 1,   /* CarbonLib < 1.4: no Networking fragment */
    kNowTestOTInitFailed = 2,
    kNowTestBadAddress = 3,
    kNowTestConnectFailed = 4,
    kNowTestNoReply = 5,
    kNowTestRefused = 6,
    kNowTestProtocolError = 7
};

/* Dials host_ip:port, performs the hello handshake, ends with bye + orderly
   disconnect. Fills status_out (C string, human-facing) either way. Bounded:
   every wait has a TickCount deadline — this must never wedge the guest
   (sync-blocking OT calls on a dead peer are the serial_tx lesson).
   host_ip is a dotted quad; v1 has no DNS on purpose. */
int now_wire_test(const char *host_ip, unsigned short port,
                  char *status_out, long status_cap);

#endif
