#ifndef NOW_WIRE_H
#define NOW_WIRE_H

#include <Carbon.h>

/* The persistent connection to the host. The guest holds one TCP connection
   open for its whole run: dial the saved host, hello, then keep it alive with
   a guest-driven ping/pong heartbeat, reconnecting on a capped backoff. All
   of this is serviced NON-BLOCKING from the event loop (conn_service) — no
   call here ever waits, so the app stays responsive and never wedges. */

typedef enum {
    kConnIdle = 0,        /* no host configured / not started */
    kConnConnecting,      /* OTConnect in flight */
    kConnHandshaking,     /* connected socket, awaiting host hello */
    kConnConnected,       /* hello exchanged; heartbeat running */
    kConnBackoff,         /* waiting to redial after a failure */
    kConnNeedsCarbonLib   /* terminal: CarbonLib 1.6 absent */
} ConnPhase;

/* Load the saved target and arm auto-connect. Safe to call once at startup. */
void conn_init(void);

/* Send bye + orderly disconnect and close. Call before quitting. */
void conn_shutdown(void);

/* Pump the state machine. Call every event-loop pass (idle included). */
void conn_service(void);

/* Point the connection at a new host/port and (re)connect immediately.
   host is a dotted quad; v1 has no DNS. */
void conn_set_target(const char *host, unsigned short port);

/* Drop any live connection and stop reconnecting until conn_set_target or
   conn_connect_now is called again. */
void conn_disconnect(void);

/* Force an immediate redial of the current target. */
void conn_connect_now(void);

ConnPhase conn_phase(void);
Boolean conn_is_connected(void);

/* Human-facing one-line status, e.g. "Connected: Maxbook Pro (v0.1.0) - 12 ms"
   or "Reconnecting in 4s (no answer)". */
void conn_status(char *out, long cap);

/* Round-trip time of the last ping/pong in ms, or -1 if none yet. */
long conn_last_rtt_ms(void);

#endif
