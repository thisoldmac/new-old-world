/*
 * net.h - the MacTCP transport seam for NOW-68K.
 *
 * Open Transport cannot link on Retro68 68K (it is layered on ASLM), so this
 * is MacTCP via the .IPP driver, and there is no second backend to abstract
 * over. The seam exists to keep every Device Manager detail out of the wire
 * layer, not to leave room for a swap.
 *
 * TWO RULES ARE STRUCTURAL HERE, not advisory:
 *
 * 1. STRICTLY ONE OPERATION IN FLIGHT. A standing TCPRcv with a concurrent
 *    TCPSend deadlocks: the send queues behind the blocked receive and never
 *    completes (measured on q800/OS 8.1 - connect, 15 s of silence, timeout,
 *    reconnect loop; finding mactcp-concurrent-rcv-send-deadlock). That is
 *    why this interface is NOT a socket. The caller never issues a send or a
 *    receive; it queues outbound bytes and drains inbound ones, and this
 *    module alone decides which operation is outstanding. A caller cannot
 *    violate the rule because the interface gives it no way to.
 *
 * 2. NO CODE OF OURS RUNS AT INTERRUPT TIME. Every call is issued async with
 *    ioCompletion = NULL and polled from the main loop, so there is no ASR
 *    and no A5 hazard, and the Toolbox and the log are always safe to touch.
 *    Do not introduce a completion routine to "speed this up" without
 *    re-reading the deadlock above.
 *
 *    THIS IS NOT THE SAME AS "VIRTUAL MEMORY CANNOT BITE US" - an earlier
 *    version of this header claimed that and was wrong. The Device Manager
 *    writes ioResult into the parameter block at interrupt time whether or
 *    not a completion routine exists, and the .IPP driver copies inbound
 *    bytes into rcvBuff from its own interrupt-level receive path. Our
 *    parameter block and all three buffers are ordinary application BSS.
 *    Under System 7.1 VM - which a 4 MB machine's owner will absolutely turn
 *    on - a page-out of any of them followed by an interrupt-time touch is a
 *    bus error, not a slowdown.
 *
 *    Today we are only safe because VM is OFF on the test machine. That is a
 *    standing precondition, not a property of this design. Supporting VM
 *    means HoldMemory over the parameter block and every buffer for as long
 *    as an operation can be outstanding (checked via gestaltVMAttr), and
 *    nothing in this tree does that yet - not the harness, not the chat
 *    client, not the PowerPC guest. Fix it here first if it ever matters.
 */
#ifndef NOW68K_NET_H
#define NOW68K_NET_H

#include <stddef.h>

typedef enum {
    kNetIdle = 0,       /* no stream, not trying */
    kNetConnecting,     /* TCPActiveOpen outstanding */
    kNetConnected,      /* usable */
    kNetFailed          /* last attempt failed; see net_last_error */
} NetState;

/* Opens the .IPP driver and creates the stream. Call once at startup.
 * Returns 0 on success, else a MacTCP/Device Manager error. */
short net_init(void);

/* Releases the stream and closes down. Safe to call when never opened.
 *
 * THIS MUST BE CALLED BEFORE THE APPLICATION EXITS, on every path, including
 * the one where the human never pressed Connect. The stream's rcvBuff is our
 * own BSS: if the app quits without TCPRelease, the .IPP driver goes on
 * owning a pointer into memory the Process Manager has handed to something
 * else, and the next stray segment writes into another application. The
 * leaked stream out of MacTCP's small fixed pool is the lesser half. */
void net_shutdown(void);

/* Begin a dial. Dotted-quad only - there is no DNS here, MacTCP name
 * resolution is a separate subsystem this client does not take on.
 * timeout_secs becomes the ULP timeout with abort action, so a dead host
 * fails in bounded time instead of hanging the connect forever.
 * Returns 0 if the attempt started; the outcome arrives via net_idle. */
short net_connect(unsigned long ip, unsigned short port,
                  unsigned short timeout_secs);

/* Begin an ORDERLY close: the staged outbound bytes are sent, then TCPClose.
 * This exists because the contract requires a graceful exit to send `bye`
 * before closing, and an abortive TCPAbort discards whatever is staged in
 * MacTCP's send buffer - so a `bye` queued and then aborted is a `bye` the
 * host never sees. Queue the farewell, call this, and keep calling net_idle
 * until the state leaves kNetConnected or the caller's patience runs out.
 * Falls back to an abort if the close does not complete in bounded time. */
void net_close(void);

/* Tear down whatever is outstanding and return to kNetIdle, abortively. This
 * is the single failure funnel: every error path routes here, because
 * MacTCP's stream and buffer pools are small and fixed and one leaked stream
 * per failed connect exhausts them quickly (-23009 insufficientResources).
 *
 * An async call may still be queued in the driver when this runs. Abort,
 * then POLL for the outstanding operation to complete, and only then
 * release: MacTCP finishes aborted calls at interrupt time via a deferred
 * task, and a completion that lands after the parameter block has been
 * reused stamps its result over the next connect's. */
void net_disconnect(void);

/* Run the state machine. Call every pass of the main event loop. Cheap when
 * idle. Collapses several transitions per call rather than one per
 * WaitNextEvent wake: one round trip is recv-done -> send -> send-done ->
 * re-post recv, and without the loop each arrow waits for its own wake. */
void net_idle(void);

NetState net_state(void);

/* Copy up to len bytes into the outbound staging buffer. Returns the number
 * accepted, which may be less than len (or zero) when the buffer is full -
 * the caller must handle a short accept rather than assume it all went. */
long net_queue_send(const void *buf, long len);

/* Drain up to cap received bytes. Returns the count, 0 when nothing has
 * arrived. Never blocks. */
long net_take(void *buf, long cap);

/* True while outbound bytes are staged or a send is outstanding - the event
 * loop uses this to stay hot instead of sleeping mid-transfer. */
short net_is_sending(void);

/* Sleep ticks to pass to WaitNextEvent: 0 while the connection is active so
 * a round trip is not paced by the idle sleep, otherwise the caller's value. */
long net_sleep_ticks(long idle_ticks);

/* Last failure, as a short ASCII string safe to draw and to log. Never NULL. */
const char *net_last_error(void);

#endif /* NOW68K_NET_H */
