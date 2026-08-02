#ifndef NOW_WIRE_H
#define NOW_WIRE_H

#include <Carbon.h>

#include "agent_access.h"
#include "fileshare.h"

/* The persistent connection to the host. The guest holds one TCP connection
   open for its whole run: dial the saved host, hello, then keep it alive with
   a guest-driven ping/pong heartbeat, reconnecting on a cadence this guest
   chooses (the contract's reference backoff, or a fixed interval from the
   Connection page; either way never faster than the 1s floor). All
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

/* A read-only picture of the connection for UI that composes its own
   words - the Workshop's Connection page and sidebar glance. Filling it
   copies and does arithmetic only: no allocation, no servicing, and no
   reaching into wire internals from window code. */
typedef struct {
    ConnPhase phase;
    char host[64];                /* the dialed or configured target */
    unsigned short port;
    char peer_name[64];           /* from hello; empty before one */
    char peer_version[32];
    char last_fail[96];           /* empty when nothing has failed */
    long retry_in_secs;           /* backoff: seconds to redial; else -1 */
    long connected_secs;          /* connected: since hello; else -1 */
    long quiet_secs;              /* since last inbound bytes; -1 if none */
    short contract_revision;
    Boolean transfer_active;      /* anything on the bulk path right now */
} ConnSnapshot;

void conn_snapshot(ConnSnapshot *out);

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
long conn_rcv_peak(void);
long conn_service_passes(void);

/* Round-trip time of the last ping/pong in ms, or -1 if none yet. */
long conn_last_rtt_ms(void);

/* --- guest-initiated screenshot push ----------------------------------- */

/* Tells the host this machine's agent-access answer changed (agent.access),
   because hello stated it once and a tier changed since then would
   otherwise not reach the host until the link was rebuilt — leaving it
   enforcing a permission the person had already withdrawn.

   Call it AFTER the new tier is stored, never instead of storing it: this
   reports the fact, it does not carry it. Does nothing when no link is up,
   where the next hello is what says it. Call it through
   now_agent_access_set_tier rather than directly — that is the one place
   the tier changes, and so the one place that owes the host a word. */
void now_wire_announce_agent_access(void);

/* What THIS connection has been told about agent access, which is not the
   same question as what the tier is: they part company when a send did not
   happen (no link up, or a full control queue). False means this link has
   been told nothing, and `out` is untouched.

   The page shows the difference rather than assuming it away — and asks
   here rather than inferring it from watching the link come up, which is
   what it used to do. */
Boolean now_wire_agent_access_told(AgentAccessTier *out);

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

/* --- pulling a file from the other machine -------------------------------
   Asks for one file and writes it into the downloads folder (prefs, or
   the Desktop) as the bytes arrive - never held whole in memory. The
   outcome arrives through the get-note hook. */
typedef void (*ConnGetNote)(const char *line);
void conn_set_get_note(ConnGetNote fn);

int now_wire_get_host(const char *path, const char *name,
                      char *err, long cap);

/* Which half of a pull is in flight. Asked and receiving-nothing-yet are
   different facts about the same machine, and one boolean could not tell
   them apart: a sender that has neither given a size nor delivered a
   byte looked exactly like a question nobody answered, so the pane had
   to infer from the counts and was late into Receiving by design. The
   wire knows; it says so. */
typedef enum {
    kWireGetNone = 0,
    kWireGetAsked,                    /* file.get is out, no answer yet */
    kWireGetReceiving                 /* file.begin seen; bytes landing */
} WireGetPhase;

/* True while a pull is in flight, so a window can show a bar. Every
   out-parameter is optional. */
Boolean now_wire_get_active(long *received, long *expected,
                            WireGetPhase *phase);

/* Stop the pull in flight: file.cancel to the other Mac (best effort),
   then abandon the receive here. 0 when a transfer was stopped, -1 with
   a reason in `err` when there was nothing to stop. A pull is never
   resumable, so the partial is deleted and nothing is left under the
   real name. Registered as the Files pane's canceller (files_pull.h).*/
int now_wire_get_cancel(char *err, long cap);

/* One-line progress reports for push transfers ("Sent to host (312 ms)").
   The Screenshots panel registers itself here; a NULL fn unhooks. */
typedef void (*ConnShotNote)(const char *line);
void conn_set_shot_note(ConnShotNote fn);

/* The same, for files the guest sends. A separate hook because it is a
   separate window: a file's progress reported into the Screenshots
   panel is indistinguishable from no report at all. */
typedef void (*ConnFileNote)(const char *line);
void conn_set_file_note(ConnFileNote fn);

/* --- asking about the other machine's cloud -----------------------------
   The cloud.* family: the modern machine's own iCloud, asked service
   by service. One direction by definition — this machine has no cloud
   to serve — and one question of each kind at a time; a second
   replaces the first, the browse rule.

   Replies arrive RAW through one hook and the iCloud page's store
   parses them (cloud_model.h): wire code correlates ids and nothing
   else, so the parsing half stays testable under the host cc. On an
   error the hook's `reply` is a plain MacRoman reason instead of a
   frame — kinds keep the two readings apart. */
typedef enum {
    kCloudAnswerReport = 0,           /* reply = the cloud.report frame */
    kCloudAnswerListing,              /* reply = the cloud.listing frame */
    kCloudAnswerCard,                 /* reply = the cloud.card frame */
    kCloudAnswerGetUnderWay,          /* reply = the file.offer frame */
    kCloudAnswerError                 /* reply = a reason, not a frame */
} CloudAnswerKind;
typedef void (*ConnCloudNote)(int kind, const char *reply);
void conn_set_cloud_note(ConnCloudNote fn);

/* Each returns 0 once the question is on the wire; -1 with a reason in
   err. A cloud.get's SUCCESS is not a cloud frame at all but the
   ordinary file.offer that follows into this machine's share; the hook
   reports it under way, and the Files machinery narrates the rest. */
int now_wire_cloud_services(char *err, long cap);
int now_wire_cloud_list(const char *service, long cursor,
                        char *err, long cap);
int now_wire_cloud_detail(const char *service, const char *item,
                          char *err, long cap);
int now_wire_cloud_get(const char *service, const char *item,
                       char *err, long cap);

/* --- talking to the other machine's model -------------------------------
   The chat.* family: the modern machine's model harness, asked one turn
   at a time. One direction by definition — this machine has no model to
   serve — and the conversation lives on the host, per connection, so a
   send carries only the turn just typed.

   A turn's answer STREAMS: many chat.delta frames, transient chat.status
   lines, then exactly one chat.result that never carries text. The
   pending turn therefore survives deltas and is cleared only by its
   result, a 60-second QUIET timeout (re-armed by every delta and
   status — status is the family's keep-alive while the model runs
   tools), or the link going away.

   Replies arrive RAW through one hook; chat_model.h parses. On kinds
   Error and Gap the `reply` is a plain MacRoman reason instead of a
   frame. The setter RETURNS the previous hook: the console verb borrows
   the stream for one turn and restores it, the exec-sink discipline. */
typedef enum {
    kChatAnswerCatalog = 0,           /* reply = the chat.catalog frame */
    kChatAnswerDelta,                 /* reply = the chat.delta frame */
    kChatAnswerStatus,                /* reply = the chat.status frame */
    kChatAnswerResult,                /* reply = the chat.result frame */
    kChatAnswerGap,                   /* reply = a reason; turn continues */
    kChatAnswerError                  /* reply = a reason; turn is over */
} ChatAnswerKind;
typedef void (*ConnChatNote)(int kind, const char *reply);
ConnChatNote conn_set_chat_note(ConnChatNote fn);

/* Each returns 0 once the question is on the wire; -1 with a reason in
   err — including the local refusals that save a round trip: a send
   while a turn streams, or a prompt past the contract's 512-byte cap
   (chat_model.h mirrors it as kChatPromptMax). */
int now_wire_chat_models(char *err, long cap);
int now_wire_chat_send(const char *model, const char *prompt,
                       char *err, long cap);
int now_wire_chat_cancel(char *err, long cap);
int now_wire_chat_reset(char *err, long cap);
Boolean now_wire_chat_turn_active(void);

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

/* The active stream's negotiated minimum frame interval in ms: -1 when
   no stream is running, 0 when the host asked for no floor. Wire
   revision 1 makes this the HOST's number (stream.start); the guest
   only reports it. */
long now_wire_stream_interval_ms(void);

/* Ends the guest's current stream cleanly (stream.stopped, no reason). */
void now_wire_stream_stop(void);

/* --- exec: asking the far end for a line ---------------------------------

   For an interpreter running under exec.request that needs input mid-command
   - a confirmation, a "which one?", a name it cannot guess. Emits `prompt`
   (may be NULL) as exec.output, FLUSHES it so it actually leaves before the
   wait begins, and then pumps the wire until the host answers exec.input.

   Returns 1 with the line in `out`, or 0 - and 0 is an ordinary outcome, not
   an exception. It means one of: nothing is running under exec (a person at
   this Mac's own Console page is never prompted, because they would have no
   way to answer); the host cancelled; or the bounded wait expired. An
   interpreter MUST have an answer for 0 that does not involve asking again.

   THE WEDGE THIS IS SHAPED AROUND. This guest is cooperatively scheduled, so
   an unbounded wait here is a Mac that needs a power cycle - the `sertx`
   failure with a different cause. Hence: the wait is BOUNDED (30 s), it
   PUMPS rather than blocks so the machine stays alive and answerable
   throughout, and exec.cancel breaks it immediately. Untested on metal as of
   2026-07-28; docs/remote-console.md's checklist exercises this path
   deliberately and last. */
int now_exec_read_input(char *out, long cap, const char *prompt);

/* True while the exec this dispatch is running under has been told to
   stop. A verb that pumps for long stretches (chat's streamed turn is
   the one today) polls this so a host's exec.cancel ends the wait
   rather than outliving the exec that asked. False when nothing runs
   under exec — a person typing at this Mac's own console. */
Boolean now_wire_exec_cancelled(void);

#endif
