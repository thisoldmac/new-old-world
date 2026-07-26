/*
 * wire68.h - the NOW protocol client for NOW-68K.
 *
 * Speaks a SUBSET of contract revision 1 over net.h: dial, hello handshake,
 * 30 s ping keepalive, frame read/write, the launch/quit commands, and
 * process.list. It does not implement capture, files, streams, the process
 * drive verbs or the software listing; the contract's answer to an
 * unimplemented message is an error reply, not silence, so the host fails
 * fast rather than waiting out a watchdog.
 *
 * This is deliberately NOT a port of the PowerPC guest's wire.c. That file is
 * 4638 lines because the whole command surface lives inside it; only about
 * 600 lines of it are transport-shaped, and its Open Transport vocabulary
 * (kOTNoDataErr, kOTFlowErr, T_DISCONNECT) has no MacTCP equivalent worth
 * emulating.
 *
 * REDIAL: a fixed interval the human starts and stops, not capped backoff.
 * The PowerPC guest already supports exactly this (prefs.h retry_secs: "0 =
 * adaptive backoff, else a fixed retry every N seconds", chosen in
 * wire.c::enter_backoff with the note that predictable reconnects beat
 * adaptive politeness on a private LAN). The contract clause that named
 * capped backoff as a mandate has been amended to match what both guests
 * actually do: cadence is guest policy, backoff is the reference default,
 * and the one surviving obligation is a floor of >= 1 s between dial
 * attempts so a misconfigured loop cannot become a connect flood.
 */
#ifndef NOW68K_WIRE68_H
#define NOW68K_WIRE68_H

#include "net.h"

/* THE outbound control payload cap for this guest, stated once, here, for
 * everything that builds a message and for the slot that carries it.
 *
 * It used to be borrowed: the slot took its size from
 * NOW68K_COMMAND_RESULT_CAP, a number that belongs to one message family
 * and was doing double duty as the wire's own limit. That was survivable
 * while command.result was the biggest thing this guest sent. It stopped
 * being survivable with process.listing, which is several times bigger
 * than any reply here has ever been - and the failure mode of getting it
 * wrong is the one that already cost an hour on the 180c (commands68.h):
 * a perfectly good message silently dropped by a slot too small for it.
 *
 * 1024 rather than 512: at 512 a worst-case process.listing page carries
 * two processes (n68_proclist.h's parts add to ~276 bytes for the first
 * and 170 for each after), so the machine's five-or-six-process list
 * costs three round trips. At 1024 it is five in the worst case and the
 * whole list in one page in practice. Rather than 2048 because the cost
 * is per SLOT, not per message: the queue below carries several, and the
 * receive side (NOW68K_CONTROL_BUFFER_CAP, 4 KB) is where the contract's
 * frame ceiling has to be honoured - not here, where we choose what to
 * send. */
#define NOW68K_CONTROL_SEND_CAP 1024

typedef enum {
    kWireIdle = 0,      /* not trying; the human has not started it */
    kWireDialing,       /* net_connect outstanding */
    kWireGreeting,      /* TCP up, hello sent, waiting for the host's hello */
    kWireLive,          /* handshake complete */
    kWireWaiting        /* last attempt failed; redialing at the fixed interval */
} WireState;

/* Once at startup, before any connection work. */
void wire_init(void);

/* Once before the application exits, on EVERY path - including the one where
 * the human never pressed Connect. Sends `bye` if a session is live (the
 * contract requires a graceful exit to announce itself rather than vanish
 * into the peer's keepalive timeout), then routes to net_shutdown so the
 * driver stops owning a pointer into our BSS. An earlier version of this
 * header declared no such verb, which is why nothing could call
 * net_shutdown and every quit leaked the stream. */
void wire_shutdown(void);

/* Sleep ticks for the caller's WaitNextEvent: 0 while a round trip is in
 * flight so it is not paced by the idle sleep, otherwise idle_ticks. The
 * event loop must route its sleep value through here - a hardcoded sleep
 * adds up to a full tick budget of latency to every MacTCP completion, and
 * one round trip crosses the idle path several times. */
long wire_sleep_ticks(long idle_ticks);

/* Target for subsequent dials. Dotted-quad address, already parsed. */
void wire_set_target(unsigned long ip, unsigned short port,
                     unsigned short connect_timeout_secs);

/* Redial cadence in seconds, and whether redialing is on at all. A cadence
 * below the 1 s floor is clamped, not rejected - the UI should not be able to
 * produce a connect flood by accident. */
void wire_set_retry(short enabled, unsigned short interval_secs);

/* The human's start/stop. wire_start begins dialing and keeps wanting a
 * connection until wire_stop; wire_stop tears down and stops redialing. This
 * is the same want-connection primitive the PowerPC guest gates on. */
void wire_start(void);
void wire_stop(void);

/* Every pass of the main event loop. Drives net_idle, the handshake, the
 * keepalive and the redial timer. Must stay cheap when idle. */
void wire_idle(void);

WireState wire_state(void);

/* Short ASCII status line for the panel - the human-facing summary of
 * whatever just happened. Never NULL. */
const char *wire_status(void);

/* Round-trip of the last answered ping, in milliseconds, or -1 if none has
 * been answered on this connection. */
long wire_last_rtt_ms(void);

/* Counters for the health readout. Cheap reads of our own bookkeeping - no
 * Toolbox calls, nothing that costs anything on the idle path. */
typedef struct {
    long frames_in;
    long frames_out;
    long bytes_in;
    long bytes_out;
    long pings_sent;
    long dials;             /* dial attempts this session */
    long last_fail_ticks;   /* TickCount of the last failure, 0 if none */

    /* Frames the guest built and could not send. Not a curiosity: every
     * one of these is a request the host is still waiting on, which is a
     * contract violation, and until this counter existed the only trace
     * was a log line on a machine nobody is looking at. wire_status()
     * carries the count too, so it is visible in the panel without
     * anyone opening the log. Never reset except by wire_init(). */
    long sends_dropped;
} WireStats;

void wire_stats(WireStats *out);

/* ---- an incoming file, for the console -------------------------------
 *
 * Receiving a push is a MESSAGE FAMILY, not a command, so no command
 * table reaches it and nothing would have compared the two faces
 * (docs/command-parity.md - this is precisely the shape process.list
 * drifted in). This is the wire face's own state, read out for the
 * console face to render: one implementation, two renderers.
 *
 * Everything here is a cheap copy of bookkeeping this module already
 * keeps - no Toolbox call, safe on the idle path. */
typedef struct {
    int  active;              /* a transfer is in flight right now */
    long id;                  /* the offer id */
    char name[64];
    long bytes;               /* what the sender offered */
    long received;
    long chunks;              /* runs taken off the wire */
    long writes;              /* File Manager writes made */
    unsigned long crc;        /* running CRC-32 */

    /* The last transfer that ENDED, kept after it is over: "what
     * happened to the last one" is the question a person actually has,
     * and it becomes unanswerable the moment the transfer completes if
     * nothing remembers. */
    int  had_one;
    int  last_ok;
    long last_bytes;
    char last_name[64];
    char last_code[16];       /* the contract's own word; "" when ok */
    short last_error;         /* the OSErr behind an io-error, or 0 */
} N68PutStatus;

void now68k_wire_put_status(N68PutStatus *out);

/* Where an incoming file lands, as a folder name a person can go and
 * look in. Empty when it cannot be resolved. */
void now68k_wire_put_where(char *out, long cap);

/* ---- an outgoing file ------------------------------------------------
 *
 * The other direction, same shape. Sending is ALSO a message family
 * rather than a command on the wire, so the same parity hazard applies
 * and the same answer is used: one implementation here, two renderers
 * above it.
 */

/* Starts sending `leaf` - a file in the application's own folder, which
 * is the only place this guest has (n68_putfile.h explains why it has no
 * share root) - to the host.
 *
 * Returns 1 when the offer is on its way. On 0, `why` carries a sentence
 * for a person and nothing was started. Refuses when there is no live
 * connection, when a transfer is already in flight (the contract's one-
 * at-a-time rule, and the answer a second request gets), when the file
 * cannot be opened, or when its name cannot go on a wire.
 *
 * The transfer proceeds from wire_idle() afterwards; its outcome shows
 * up in now68k_wire_send_status(). */
int now68k_wire_send_file(const char *leaf, char *why, long why_cap);

/* ---- ending one early ------------------------------------------------
 *
 * Abandons whatever transfer is in flight, in EITHER direction: the
 * receive half discards its staging file and answers file.done
 * cancelled, the send half stops producing and says file.end ok:false.
 * Either way the lane is free when this returns.
 *
 * Returns 1 if there was something to stop, 0 if the machine was
 * already quiet - which is a refusal for a caller to report, not an
 * error. `what` takes a short phrase naming what was stopped, for
 * rendering; pass NULL and 0 if nobody is going to read it.
 *
 * THE SAME BODY serves the wire's file.cancel. It is published here
 * because a capability reachable only over the wire is half a feature
 * (docs/command-parity.md), and this is the one where that bites
 * hardest: the person who most needs to end a transfer is standing at
 * a machine whose host has stopped answering, and the wire is the face
 * they do not have. */
int now68k_wire_cancel_transfer(char *what, long cap);

/* What the console's face on the send half reads. A cheap copy of
 * bookkeeping this module already keeps, like N68PutStatus above. */
typedef struct {
    int  active;              /* a send is in flight right now */
    int  offered;             /* waiting for the host to answer the offer */
    long id;
    char name[64];
    long bytes;               /* what we offered */
    long sent;                /* framed so far */

    int  had_one;
    int  last_ok;
    long last_bytes;
    char last_name[64];
    char last_code[16];       /* the contract's own word; "" when ok */
} N68SendStatus;

void now68k_wire_send_status(N68SendStatus *out);

#endif /* NOW68K_WIRE68_H */
