#ifndef NOW_WIRE_H
#define NOW_WIRE_H

#include <Carbon.h>

#include "fileshare.h"

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

/* conn_service() for nested Toolbox loops (see pump.h). Guarded against
   reentry, so a pumped callback cannot re-enter servicing mid-service. */
void now_wire_pump(void);

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

/* True while a transfer, stream, offer, or queued control frame needs the
   event loop to spin fast. The main loop drops its WaitNextEvent sleep to
   0 then - a ~100 ms idle sleep would starve the band/send pumps. */
Boolean conn_wants_fast_pump(void);

/* Human-facing one-line status, e.g. "Connected: Maxbook Pro (v0.1.0) - 12 ms"
   or "Reconnecting in 4s (no answer)". */
void conn_status(char *out, long cap);

/* What to call the machine on the other end, for anything a human
   reads. It is the name that machine sent in its hello; before a
   connection there is no name to use, so it degrades to a plain
   description rather than protocol vocabulary. Never "the host" —
   guest and host are words for the code, not for the person using it.
   Truncates to cap, so button titles can ask for a short one. */
void conn_peer_label(char *out, long cap);

/* The TCP receive window Open Transport granted, or 0 if it kept its
   default. Small windows throttle inbound files to one segment per
   delayed ACK, so this is worth being able to see. */
long conn_rcv_window(void);

/* Round-trip time of the last ping/pong in ms, or -1 if none yet. */
long conn_last_rtt_ms(void);

/* --- guest-initiated screenshot push ----------------------------------- */

/* Captures at the panel's depth and offers it to the host (capture.offer).
   Returns 0 once the offer is on the wire; -1 with a reason in err if the
   guest cannot offer right now. The outcome — accepted and sent, refused,
   or timed out — arrives later through the shot-note hook. */
int now_wire_offer_shot(char *err, long cap);

/* Offers a file to the host: offer, then the bytes if it says yes.
   0 = under way (the panel narrates the rest), -1 = err says why. */
int now_wire_send_file(const FSSpec *spec, char *err, long cap);

/* A send the host refused because something is already there. Wire
   code cannot ask a person (pump.h: a modal opened from a network
   callback nests inside whatever loop is already running), so it holds
   the staged bytes and raises this; the event loop asks and answers.
   Until it does, the send has no deadline — a question waits. */
Boolean now_wire_send_pending_replace(char *name, long cap);
void now_wire_send_resolve_replace(Boolean replace);

/* --- browsing the other machine's share ---------------------------------
   Asking the same file.list the guest already answers. A listing is
   control-plane, so this works mid-transfer; only the answer is one at
   a time, and asking again replaces the question.

   The hook is called exactly once per request: with entries on success,
   or with error set and count 0 on a refusal or a silence. Names arrive
   DECODED to MacRoman - they are drawn and used as file names, and
   neither can hold anything else. */
typedef void (*ConnListing)(const char *path, const FileEntry *entries,
                            int count, Boolean more, long cursor,
                            const char *root, const char *error);
void conn_set_listing(ConnListing fn);

/* 0 once the question is on the wire; -1 with a reason in err. */
int now_wire_list_host(const char *path, long cursor, char *err, long cap);

/* One-line progress reports for push transfers ("Sent to host (312 ms)").
   The Screenshots panel registers itself here; a NULL fn unhooks. */
typedef void (*ConnShotNote)(const char *line);
void conn_set_shot_note(ConnShotNote fn);

/* The same, for files the guest sends. A separate hook because it is a
   separate window: a file's progress reported into the Screenshots
   panel is indistinguishable from no report at all. */
typedef void (*ConnFileNote)(const char *line);
void conn_set_file_note(ConnFileNote fn);

/* Where a file the guest is sending has got to, so the panel can show a
   moving bar rather than a line that sits still for a minute. Returns
   false when nothing is being sent. */
typedef enum {
    kSendNothing = 0,
    kSendOffering,                    /* waiting for the host to answer */
    kSendSending                      /* bytes on the wire */
} SendPhase;
SendPhase now_wire_send_state(long *sent, long *total,
                              char *name, long name_cap);

/* Asks the host to open a live-stream bracket at the panel's depth. The
   bracket stays host-owned: the host answers stream.start (streaming
   begins) or declines; either lands via the shot-note hook. */
int now_wire_stream_request(char *err, long cap);

/* True while a stream bracket is open (either origin). */
Boolean now_wire_stream_active(void);

/* Ends the guest's current stream cleanly (stream.stopped, no reason). */
void now_wire_stream_stop(void);

#endif
