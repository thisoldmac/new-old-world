#ifndef NOW_NET_PROBE_H
#define NOW_NET_PROBE_H

#include "net_facts.h"

/* The Open Transport half. Everything it learns lands in a NetFacts;
   everything about what those facts MEAN lives in net_facts.c, where a
   host test can reach it. */

/* What NOW already knows about its own connection, passed in rather than
   read here: the wire owns these counters and this module is a reader of
   them, not a second source. A page whose resting state is a real
   measurement beats one that is empty until a probe runs. */
typedef struct NetLinkSample {
    Boolean connected;
    char peer[kNetNameMax];
    unsigned long port;
    unsigned long up_secs;
    long rtt_ms;          /* -1 when no ping has completed */
    long rcv_window;      /* 0 when OT kept its default */
    long rcv_peak;
    long quiet_secs;      /* -1 when nothing has arrived */
} NetLinkSample;

/* Fill `out` from Open Transport plus the caller's link sample. Always
   writes a complete NetFacts, including on a Mac with no Open Transport
   at all — absence is reported, never left as whatever was in the
   struct. `link` may be NULL, which reads as "not connected".

   Costs: two documented calls and a bounded port walk. No allocation, no
   endpoint is opened, nothing is sent. Safe to call from an idle handler,
   though the module calls it on demand because a person asked. */
void now_net_probe(const NetLinkSample *link, NetFacts *out);

#endif /* NOW_NET_PROBE_H */
