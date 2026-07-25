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

#endif /* NOW68K_WIRE68_H */
