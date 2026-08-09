/*
 * ot.h - Open Transport transport layer for the harness (asynchronous).
 *
 * A notifier-driven TCP server: OT events (accept, receive, flow control,
 * disconnect) are handled at deferred-task time, INDEPENDENT of the cooperative
 * WaitNextEvent loop - so the harness serves the wire without being the
 * frontmost app. Verb handling stays on the main loop, because the Toolbox is
 * not safe at deferred-task time. Full design: docs/09-async-transport.md.
 *
 * One connection at a time (a pre-opened listener + worker endpoint, reused).
 */
#ifndef TIMBOTTU_OT_H
#define TIMBOTTU_OT_H

#include <stddef.h>
#include <OpenTransport.h>
#include <OpenTptInternet.h>

#include "ot_sched.h"

typedef OTSchedConfig OTConfig;

/* Handle one complete request line into out[0..cap); returns the response length
 * or <= 0 to send nothing. Runs on the MAIN loop, so it may call the Toolbox.
 * (verb_handle has exactly this shape.) */
typedef int (*OTReqHandler)(const char *line, size_t len, char *out, size_t cap);

/* Optional main-loop log sink for transport events. NEVER called from the
 * notifier (logging is not deferred-task-safe); ot_idle drains a trace to it. */
typedef void (*OTLogProc)(const char *msg);

typedef struct {
    unsigned long rcv_calls;
    unsigned long rcv_bytes;
    unsigned long rcv_high_water;
    unsigned long snd_calls;
    unsigned long snd_bytes;
    unsigned long snd_flow_events;
    unsigned long snd_contributions;
    unsigned long pace_arms;
    unsigned long pace_fires;
    unsigned long pace_deferred;
    unsigned long lines_drained;
    unsigned long lines_dispatched;
    unsigned long dispatch_ticks;
    unsigned long sleep_hot;
    unsigned long sleep_cold;
} OTStats;

OSStatus ot_startup(void);
void     ot_shutdown(void);

/* Apply a resolved transport policy before ot_serve(). NULL or disabled keeps
 * the legacy OT path. MacTCP builds do not compile or call this API. */
void ot_configure(const OTConfig *config);

/* Open the listener + worker endpoints, bind (sync) on `port`, then switch to
 * async and start listening. `handler` processes request lines on the main loop.
 * Returns noErr, or an OT error (nothing left open on failure). */
OSStatus ot_serve(InetPort port, OTReqHandler handler, OTLogProc log);

/* Main-loop pump (call every loop iteration): drains the transport-event trace
 * to the log, and if a full request line is ready, runs the handler and starts
 * sending the response. Never blocks. */
void ot_idle(void);

/* True while a response is still being sent - lets the caller defer shutdown
 * until the last reply is fully out. */
Boolean ot_is_sending(void);

/* Recommended WaitNextEvent sleep for the next loop iteration: 0 while the wire
 * is hot (request in flight, bytes buffered, or activity within the last
 * ~second), else `idleTicks` (the caller's good-citizen default). This is the
 * adaptive poll: a transfer's round-trips stop paying the idle sleep, but a
 * quiet harness - even one holding an open connection - yields normally. */
long ot_sleep_ticks(long idleTicks);

/* Copy cumulative aggregates. Host-side unsigned subtraction makes snapshots
 * composable and wrap-safe. */
void ot_stats_snapshot(OTStats *stats);

/* True while the listener is open (i.e. between ot_serve and ot_teardown). The
 * UI's Connect/Disconnect button reads this to render its state. */
Boolean ot_is_serving(void);

/* Close the endpoints and release the notifier UPP. */
void ot_teardown(void);

#endif /* TIMBOTTU_OT_H */
