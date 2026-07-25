/*
 * wire68.c - implementation of wire68.h. See that header for the design
 * rationale (why fixed-interval redial, why this is not a wire.c port).
 *
 * Derived from contract/asyncapi.yaml (connection rules preamble + Hello /
 * Refuse / Ping / Pong / Error schemas), cross-checked against the shipping
 * PPC guest's now/guest/src/wire.c for the two timings the contract states
 * only in prose (ping interval, death threshold) and for one the contract
 * does not state at all (hello timeout - see kWireHelloTimeoutTicks below).
 * Where this file's behaviour differs from wire.c on purpose, the reason is
 * called out at the point of difference rather than left implicit.
 *
 * Everything below goes through net.h only. No MacTCP call, no ASR, no
 * completion routine: wire_idle() is polled from the main loop exactly like
 * net_idle(), and every static buffer here is sized and owned at file scope
 * (no malloc/NewPtr/NewHandle anywhere in this file).
 *
 * STATIC BUDGET (all file-scope, zero-initialized BSS - no allocation):
 *   g_ctrl_buf           4096  bytes  (NOW68K_CONTROL_BUFFER_CAP, frame.h)
 *   g_sink                256  bytes  (bulk / oversized-control discard sink)
 *   g_out[4] slots          4 * (8 header + 1024 payload + 4 len + 4 off)
 *                         4 * 1040 = 4160  bytes  (was 1056 at depth 2 and
 *                                                 a 512-byte payload cap,
 *                                                 and 352 at 160 - see
 *                                                 NOW68K_CONTROL_SEND_CAP
 *                                                 in wire68.h and the
 *                                                 kWireOutQueueDepth
 *                                                 comment below for the
 *                                                 arithmetic behind both)
 *   g_proc_rows[48]        48 * ~56       = 2688  bytes  (one process.list
 *                                                 snapshot; see its own
 *                                                 comment for why it is
 *                                                 not on the stack)
 *   g_read (N68Reader)                      48  bytes  (state+hdr+4 counters
 *                                                       + 2 buffer ptrs and
 *                                                       a cap + ops/ctx ptrs)
 *   g_stats (WireStats)                     32  bytes  (8 longs)
 *   g_peer_name                             32  bytes
 *   g_status                                96  bytes
 *   scalars (state/target/retry/timers/ids) 62  bytes  (approx, no padding
 *                                                        assumed beyond
 *                                                        natural alignment)
 *   kReadOps (const, 8 fn ptrs)             32  bytes  (.data, not BSS)
 *   -----------------------------------------------------------------
 *   total                                ~11500  bytes  (~11.2 KB)
 * Measured whole-application delta for the process.list pass (the deeper
 * and wider send queue, the snapshot buffer, n68_proclist.c and
 * proc_list_rows), m68k-apple-macos-size, -O2: text +2948, data +292,
 * bss +5784 bytes - 97180/7136/33764 to 100128/7428/39548.
 * Measured cost of moving the state machine into n68_reader.c behind that
 * ops table (m68k-apple-macos-size, -O2, whole application): text +472,
 * data +40, bss +32 bytes.
 * Under 1% of the 1 MB free-memory design target, dominated entirely by the
 * 4 KB control receive buffer that frame.h's NOW68K_CONTROL_BUFFER_CAP
 * requires us to carry.
 */
#include "wire68.h"
#include "commands68.h"

#include "contract.h"
#include "frame.h"
#include "hello.h"
#include "json_scan.h"
#include "log.h"
#include "n68_proclist.h"
#include "n68_reader.h"
#include "numfmt.h"
#include "ping.h"
#include "proc68.h"

#include <OSUtils.h>    /* TickCount */
#include <string.h>     /* strcmp, strlen (via numfmt callers) */

/* No canonical app-version constant exists yet in guest68k/src (see
 * contract.h for the one that does exist, NOW68K_CONTRACT_REVISION). This is
 * a local placeholder for Hello.version, which the schema says is "for
 * display only" - nothing on the wire depends on its value. */
/* Bump this on every build that goes to a machine. The host shows it as
 * "Connected: now-68k v<X>", and with the FTP server appending #2/#3 rather
 * than overwriting, that string is the only reliable answer to "which build
 * am I actually running" - AGENTS.md: check the build stamp before believing
 * a test result. */
#define NOW68K_APP_VERSION "0.13"

enum {
    /* contract/asyncapi.yaml: "the guest sends ping after 30s of wire
     * silence"; cross-checked against wire.c's kPingIntervalTicks. */
    kWirePingIntervalTicks = 60 * 30,

    /* contract: "guest after 2 unanswered pings (~65s)". Implemented the
     * same way wire.c does it (kDeadTicks) - as a single wall-clock-since-
     * last-inbound-byte watchdog rather than counting individual unanswered
     * pings, because with no ping ever reset independently of traffic the
     * two come out identical: two 30s ping cycles with nothing heard back
     * is 60s, and 65s here gives the second ping's own round trip time to
     * land before the guest gives up on it. */
    kWireDeadTicks = 60 * 65,

    /* NOT in the contract. The contract describes the hello handshake but
     * gives no bound on how long the guest waits for the host's reply after
     * its own TCP connect succeeds - without one, a host that accepts the
     * TCP connection but never answers hello would leave this state machine
     * in kWireGreeting forever, immune to the redial timer (which only
     * triggers from kWireWaiting) and reachable only by the human calling
     * wire_stop(). Cross-checked against wire.c's kHelloTimeoutTicks, which
     * exists for exactly this reason; this file uses the same 8s. Flagging
     * this as an addition beyond the contract, not a silent invention: see
     * the deliverable report. */
    kWireHelloTimeoutTicks = 60 * 8,

    /* How long to stay awake waiting for a pong before going back to the
     * normal idle sleep. Two seconds is far beyond any healthy round trip on
     * this link (the metal floor is 2 ticks) while keeping a lost answer from
     * spinning the CPU for the whole 65 s death window on battery. */
    kWirePongPollTicks = 60 * 2,

    /* wire68.h: "a floor of >= 1 s between dial attempts so a misconfigured
     * loop cannot become a connect flood." */
    kWireRetryFloorSecs = 1,

    /* Outer bound on how long send_bye_and_close() polls net_idle() waiting
     * for net_close()'s own orderly-close/fallback-abort cycle to leave
     * kNetConnected. net.h documents that net_close() carries its own
     * bounded-time abort fallback; this is a second, belt-and-braces bound
     * in case that inner one somehow never fires, so a graceful quit can
     * never hang the application waiting on MacTCP. */
    kWireByeDrainTicks = 60 * 3
};

/* Payload cap for anything THIS guest sends. It used to be 160, chosen for
 * "hello (~110), ping (~30), or an error reply (~95)" - accurate when this
 * guest had no commands, and never revisited when launch and quit arrived
 * with replies twice that size. A 166-byte launch reply died here on the
 * 180c while the log blamed the queue. It is now stated once, in wire68.h,
 * as the wire's own limit rather than borrowed from one message family. */
#define kWireOutPayloadCap NOW68K_CONTROL_SEND_CAP

/* These two are the asserts the old comment here said could not exist. It
 * was right that comparing the slot to the builder was a tautology while
 * both read the same macro - but now there are three message families with
 * their OWN size statements (command.result in commands68.h, the
 * process.listing parts in n68_proclist.h), and "the slot can carry what
 * that family says it builds" is a real invariant that a future edit can
 * break. Failing at compile time is the whole point: the 160-vs-512 bug
 * was invisible until a reply of the wrong size reached real hardware. */
_Static_assert(NOW68K_CONTROL_SEND_CAP >= NOW68K_COMMAND_RESULT_CAP,
               "the outbound slot cannot carry a full command.result");
_Static_assert(NOW68K_CONTROL_SEND_CAP >= NOW68K_PROCLIST_MIN_CAP,
               "the outbound slot cannot carry a process.listing page with "
               "a row in it - every page would be empty with more:true, and "
               "the host would page forever");

/* Four slots, not two.
 *
 * Two existed because a ping can come due in the same wire_idle() pass
 * that an unimplemented request needs an error reply, and rule 4 ("never
 * silence") means the reply must not be the one dropped because the ping
 * took the only slot. That reasoning still holds and is now enforced
 * directly (send_ping keeps its hands off the last slot) rather than
 * left to emerge from the depth.
 *
 * What changed is that ONE wire_idle() pass can now answer several
 * requests: drain_frames() keeps pulling frames while the transport has
 * bytes, so a host that pipelines - a process.list page request behind a
 * command.request, which is exactly what paging looks like - produces
 * several replies before anything is flushed. Depth is what that pass can
 * answer before it has to stop reading and wait.
 *
 * The arithmetic: a slot is NOW68K_FRAME_HEADER_BYTES + the payload cap,
 * plus the two longs that track it = 8 + 1024 + 8 = 1040 bytes, so four
 * slots are 4160 bytes of BSS, up from 2 * (8 + 512 + 8) = 1056. That is
 * +3104 bytes: 0.8% of the 384 KB partition and 1.3% of the ~231 KB free
 * heap this application runs with. Eight slots would be 8320 and buy
 * nothing measurable - MacTCP's own staging
 * buffer, not this queue, is what paces the wire, and past the point where
 * a pass can answer everything in front of it, a deeper queue only defers
 * an honest stop. Two is the floor (ping + reply); four is the smallest
 * depth that keeps a listing page, a command result and a ping all moving
 * without a stop-and-wait round trip between them. */
#define kWireOutQueueDepth 4

/* One slot per queued frame. */
typedef struct {
    unsigned char buf[NOW68K_FRAME_HEADER_BYTES + kWireOutPayloadCap];
    long len;   /* total bytes (header+payload) once queued, 0 = empty */
    long off;   /* bytes already handed to net_queue_send */
} OutSlot;

static WireState      g_state = kWireIdle;
static short          g_want = 0;         /* human wants a connection */
static short          g_net_ready = 0;    /* net_init() succeeded */

static unsigned long  g_target_ip = 0;
static unsigned short g_target_port = 0;
static unsigned short g_target_timeout = 0;

static short          g_retry_enabled = 0;
static unsigned short g_retry_interval_secs = kWireRetryFloorSecs;

static unsigned long  g_next_dial_tick = 0;
static unsigned long  g_hello_deadline = 0;

static unsigned long  g_last_rx_tick = 0;   /* any inbound byte, this conn */
static unsigned long  g_next_ping_tick = 0;
static unsigned long  g_ping_sent_tick = 0;
static long           g_ping_id = 0;
static long           g_last_rtt_ms = -1;

static char           g_peer_name[32];
static char           g_status[96];

static WireStats      g_stats;

static N68Reader       g_read;
static char            g_ctrl_buf[NOW68K_CONTROL_BUFFER_CAP];
static unsigned char   g_sink[256];   /* scratch sink for skip-state draining */

static OutSlot         g_out[kWireOutQueueDepth];
static int             g_out_head = 0;   /* next slot to flush */
static int             g_out_count = 0;  /* occupied slots */

/* ---- status line building -------------------------------------------- */
/* g_status is built once per state transition, never reformatted on a
 * plain wire_idle() pass - wire_status() is a cheap pointer return, matching
 * "keep those cheap, they are read on the idle path". */

static void status_begin(long *pos)
{
    *pos = 0;
    g_status[0] = '\0';
}

/* now68k_fmt_append_str/long leave *pos unspecified on failure (numfmt.h).
 * Every call site here re-derives a safe position from the NUL the previous
 * successful append left behind, so a failed append truncates the status
 * line instead of risking an out-of-bounds write on status_end(). */
static void status_append(long *pos, const char *s)
{
    if (!now68k_fmt_append_str(g_status, (long)sizeof g_status, pos, s)
        && (*pos < 0 || *pos >= (long)sizeof g_status)) {
        *pos = (long)strlen(g_status);
    }
}

static void status_append_long(long *pos, long v)
{
    if (!now68k_fmt_append_long(g_status, (long)sizeof g_status, pos, v)
        && (*pos < 0 || *pos >= (long)sizeof g_status)) {
        *pos = (long)strlen(g_status);
    }
}

static void status_end(long pos)
{
    if (pos < 0 || pos >= (long)sizeof g_status) {
        pos = (long)sizeof(g_status) - 1;
    }
    g_status[pos] = '\0';
}

static void set_status_str(const char *s)
{
    long pos;

    status_begin(&pos);
    status_append(&pos, s);
    status_end(pos);
}

static void append_status_suffix(const char *suffix)
{
    long pos = (long)strlen(g_status);

    status_append(&pos, suffix);
    status_end(pos);
}

/* ---- tiny local JSON/string helpers ------------------------------------ */

/* Same shape as now68k_json_read_type (json_scan.c) but for an arbitrary
 * key - that function is hardcoded to "type", and refuse.reason / bye.code /
 * error.code / error.message / hello.name / hello.version all need the same
 * bounded quoted-string read for a different key. */
static int read_string_field(const char *json, size_t json_len,
                              const char *key, char *out, long cap)
{
    const char *end = json + json_len;
    const char *p = now68k_json_value(json, json_len, key);
    long n = 0;

    if (p == NULL || p >= end || *p != '"' || out == NULL || cap < 1) {
        return 0;
    }
    ++p;
    while (p < end && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return (p < end && *p == '"');
}

static void bounded_strcpy(char *dst, long dst_cap, const char *src)
{
    long i = 0;

    if (dst_cap <= 0) {
        return;
    }
    while (i < dst_cap - 1 && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

/* ---- the frame reader's world ------------------------------------------ */

/* n68_reader.c holds the state machine itself; these are the real net.h,
 * Toolbox and teardown calls it used to make directly. Nothing here decides
 * anything - a wrapper that grew a condition would be behaviour the tests
 * across the seam can no longer see. */

static void teardown_and_retry(const char *log_reason, const char *bye_code);
static void handle_control_message(const char *json, long len);
static void refresh_live_status(void);

static long read_take(void *ctx, void *dst, long cap)
{
    (void)ctx;
    return net_take(dst, cap);
}

static void read_took(void *ctx, long got)
{
    (void)ctx;
    g_stats.bytes_in += got;
    g_last_rx_tick = TickCount();
}

static void read_frame_started(void *ctx)
{
    (void)ctx;
    ++g_stats.frames_in;
}

static void read_oversized_frame(void *ctx, unsigned long length)
{
    (void)ctx;
    now68k_log_num("wire: frame exceeds the protocol maximum, dropping "
                    "connection", (long)length);
    set_status_str("Protocol error: oversized frame");
    teardown_and_retry(NULL, "protocol-error");
}

static void read_oversized_control(void *ctx, unsigned long length)
{
    (void)ctx;
    now68k_log_num("wire: control frame too large for our buffer, skipped",
                    (long)length);
}

static void read_empty_control(void *ctx)
{
    (void)ctx;
    now68k_log("wire: empty control frame");
}

static void read_control_message(void *ctx, const char *json, long len)
{
    (void)ctx;
    handle_control_message(json, len);
}

/* Asked after every control message the reader hands up. Two reasons to
 * stop, and they are different in kind:
 *
 *  - the handler tore the connection down (the original reason), or
 *  - the outbound queue is full, so the NEXT request we read is one we
 *    could not answer.
 *
 * The second is back-pressure, and it is the smallest honest fix for a
 * queue that can fill: reading a request we cannot answer converts a
 * temporary shortage of slots into a permanent contract violation, and the
 * only evidence is a log line. Not reading it leaves the bytes in MacTCP's
 * receive buffer and eventually in the host's TCP window, which is what
 * back-pressure is for; wire_idle() flushes before it drains, so the next
 * pass picks the request up with room to answer it. There is no deadlock
 * to fear: sends drain from net_idle() whether or not we are reading. */
static int read_still_reading(void *ctx)
{
    (void)ctx;
    if (g_state != kWireGreeting && g_state != kWireLive) {
        return 0;
    }
    return g_out_count < kWireOutQueueDepth;
}

static const N68ReaderOps kReadOps = {
    read_take,
    read_took,
    read_frame_started,
    read_oversized_frame,
    read_oversized_control,
    read_empty_control,
    read_control_message,
    read_still_reading
};

/* ---- read/write state resets ------------------------------------------- */

/* Re-binding the ops on every reset rather than once at startup keeps the
 * reader's wiring impossible to get half-done: there is no window in which
 * g_read is reset but not connected to anything. */
static void reset_read_state(void)
{
    n68_reader_init(&g_read, g_ctrl_buf, g_sink, (long)sizeof g_sink,
                     &kReadOps, NULL);
}

static void reset_outbound_queue(void)
{
    g_out_head = 0;
    g_out_count = 0;
}

/* ---- outbound: queue, then flush through net_queue_send ---------------- */

/* A frame this guest built and could not send. Counted (wire68.h ::
 * WireStats.sends_dropped) and folded into the status line, because the
 * log is on a machine nobody is watching and the message that vanished is
 * usually a reply somebody is waiting for. Once non-zero it stays visible
 * for the rest of the launch - a drop that scrolled away is a drop nobody
 * finds out about. */
static void note_send_dropped(void)
{
    ++g_stats.sends_dropped;
    if (g_state == kWireLive) {
        refresh_live_status();
    }
}

/* Builds one 8-byte control-frame header plus payload into the next free
 * slot as a SINGLE contiguous buffer, so flush_outbound() always hands
 * net_queue_send a whole frame's bytes at once rather than the header and
 * payload separately - the closest this module can get to the wire rule
 * "each frame is written as ONE contiguous send" from inside an API that
 * does not expose the underlying TCPSend call. Returns 0 (message dropped)
 * if the queue is full or the payload does not fit a slot; every caller
 * logs on a 0 return rather than pretending the message went out. */
static int enqueue_control_send(const void *payload, long payload_len)
{
    Now68kFrameHeader hdr;
    OutSlot *s;
    int slot;

    /* Two different failures used to return 0 here and every caller
     * logged the same "outbound queue full" for both. On the 180c that
     * cost an hour: a launch reply vanished, the log said the queue was
     * full, and the queue was one of two suspects the log could not tell
     * apart. Name them where they happen - the caller's message stays,
     * but it is no longer the only thing written down. */
    if (payload_len < 0
        || (NOW68K_FRAME_HEADER_BYTES + payload_len)
               > (long)sizeof(g_out[0].buf)) {
        now68k_log_num("wire: send dropped - payload too big for a slot, "
                        "bytes", payload_len);
        note_send_dropped();
        return 0;
    }
    if (g_out_count >= kWireOutQueueDepth) {
        now68k_log_num("wire: send dropped - all slots busy, queued",
                        (long)g_out_count);
        note_send_dropped();
        return 0;
    }

    slot = (g_out_head + g_out_count) % kWireOutQueueDepth;
    s = &g_out[slot];

    hdr.channel = NOW68K_CHANNEL_CONTROL;
    hdr.flags = 0;
    hdr.transfer = 0;
    hdr.length = (unsigned long)payload_len;
    now68k_frame_pack(&hdr, s->buf);
    memcpy(s->buf + NOW68K_FRAME_HEADER_BYTES, payload, (size_t)payload_len);

    s->len = (long)NOW68K_FRAME_HEADER_BYTES + payload_len;
    s->off = 0;
    ++g_out_count;
    return 1;
}

/* Drains queued slots in order. A short accept from net_queue_send stops
 * the loop rather than starting the next slot's bytes early, so two queued
 * messages never interleave on the wire even though net.h's own staging
 * buffer is what actually paces the TCPSend calls. */
static void flush_outbound(void)
{
    while (g_out_count > 0) {
        OutSlot *s = &g_out[g_out_head];
        long remaining = s->len - s->off;
        long sent;

        if (remaining <= 0) {
            g_out_head = (g_out_head + 1) % kWireOutQueueDepth;
            --g_out_count;
            continue;
        }
        sent = net_queue_send(s->buf + s->off, remaining);
        if (sent <= 0) {
            return;
        }
        s->off += sent;
        g_stats.bytes_out += sent;
        if (s->off >= s->len) {
            ++g_stats.frames_out;
            g_out_head = (g_out_head + 1) % kWireOutQueueDepth;
            --g_out_count;
        } else {
            return;   /* short accept: wait for more room before continuing */
        }
    }
}

/* ---- graceful close: bye, then net_close(), then drain it ---------------- */

/* Queues `bye {code}`, flushes it toward MacTCP, and drives net_close()'s
 * queued-send/TCPClose sequence to completion by polling net_idle() -
 * this function IS the event loop for the duration of the close, since
 * every caller (wire_stop, wire_shutdown, a protocol-error teardown) is a
 * synchronous entry point with no other pump running underneath it.
 *
 * DEFECT 6: wire_stop() and teardown_and_retry() used to go straight to
 * net_disconnect() (TCPAbort) on every path, including the ones where a
 * session was live - discarding whatever MacTCP had staged and leaving
 * the host to notice we are gone only via the ~65s keepalive death
 * window, when net.h now gives us net_close() for exactly the orderly
 * exit the contract requires. Bye is documented best-effort, so a queue
 * or send failure here is logged and we still proceed to close. */
static void send_bye_and_close(const char *code)
{
    char payload[64];
    long pos = 0;
    int ok = 1;
    unsigned long deadline;

    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"bye\",\"code\":\"");
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      code);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "\"}");
    if (ok && pos > 0) {
        if (!enqueue_control_send(payload, pos)) {
            now68k_log("wire: bye dropped, outbound queue full");
        }
    } else {
        now68k_log("wire: bye payload build failed");
    }

    flush_outbound();
    net_close();
    deadline = TickCount() + (unsigned long)kWireByeDrainTicks;
    while (net_state() == kNetConnected && TickCount() < deadline) {
        flush_outbound();
        net_idle();
    }
    if (net_state() == kNetConnected) {
        /* net_close() did not resolve within our outer bound (see the
         * kWireByeDrainTicks comment) - fall back to the same funnel
         * every other failure path uses rather than leaving a stream
         * outstanding. */
        net_disconnect();
    }
}

/* ---- the single failure funnel ----------------------------------------- */

/* Every teardown path - dial failure, hello timeout, protocol violation,
 * refuse, bye, keepalive death - routes here, matching net.h's own
 * "single failure funnel" discipline (net_disconnect's doc comment) so a
 * failed stream is never leaked. log_reason may be NULL when the caller
 * already logged a more specific line itself.
 *
 * bye_code is non-NULL only for the two callers that can still have a
 * live TCP stream when they land here (a protocol violation caught mid-
 * handshake or mid-session): every other caller either never had a
 * stream (a failed dial) or is reacting to a close the peer already
 * initiated (refuse, bye received), where sending our own bye would be
 * redundant or land on a connection already going away. When bye_code is
 * non-NULL but g_state shows no live stream (e.g. a dial itself failed),
 * this still falls through to the plain abort - there is nothing to
 * gracefully close. */
static void teardown_and_retry(const char *log_reason, const char *bye_code)
{
    if (log_reason != NULL) {
        now68k_log(log_reason);
    }
    if (bye_code != NULL && (g_state == kWireGreeting || g_state == kWireLive)) {
        send_bye_and_close(bye_code);
    } else {
        net_disconnect();
    }
    reset_read_state();
    reset_outbound_queue();
    g_stats.last_fail_ticks = (long)TickCount();

    if (g_want && g_retry_enabled) {
        unsigned long interval_ticks =
            (unsigned long)g_retry_interval_secs * 60UL;

        g_state = kWireWaiting;
        g_next_dial_tick = TickCount() + interval_ticks;
        append_status_suffix(" - retrying");
    } else {
        /* DEFECT 17: this used to also clear g_want here, silently
         * revoking the human's "keep wanting a connection" intent
         * (wire68.h: wire_start "keeps wanting a connection until
         * wire_stop") whenever a single dial failed with the retry
         * checkbox off. Going idle here means "not retrying
         * automatically", not "the standing request is cancelled" - only
         * wire_start()/wire_stop() (and the deliberate host-declared
         * protocol-error case in handle_bye) get to change g_want. */
        g_state = kWireIdle;
    }
}

/* ---- generic "not implemented" reply ------------------------------------ */

static void send_error_reply(long id, int have_id)
{
    char payload[kWireOutPayloadCap];
    long pos = 0;
    int ok = 1;

    /* The failed request's own "type" is deliberately NOT echoed into this
     * message: our JSON writer never escapes text, and a peer-controlled
     * type string could contain a byte (a bare quote or backslash) that
     * breaks the JSON we are trying to emit. A fixed message costs nothing
     * here since the id already correlates the reply for anyone who needs
     * to know which request failed. */
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"error\",");
    if (have_id) {
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          "\"id\":");
        ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload,
                                           &pos, id);
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          ",");
    }
    ok = ok && now68k_fmt_append_str(
                   payload, (long)sizeof payload, &pos,
                   "\"code\":\"not-implemented\","
                   "\"message\":\"unsupported message type\"}");
    if (!ok || pos <= 0) {
        now68k_log("wire: error-reply build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: error reply dropped, outbound queue full");
    }
}

/* ---- inbound message handlers ------------------------------------------- */

static void refresh_live_status(void)
{
    long pos;

    status_begin(&pos);
    status_append(&pos, "Connected");
    if (g_peer_name[0] != '\0') {
        status_append(&pos, ": ");
        status_append(&pos, g_peer_name);
    }
    if (g_last_rtt_ms >= 0) {
        status_append(&pos, " - ");
        status_append_long(&pos, g_last_rtt_ms);
        status_append(&pos, " ms");
    }
    /* A dropped frame is almost always a reply somebody is blocked on.
     * It belongs where the human already looks, not only in the log. */
    if (g_stats.sends_dropped > 0) {
        status_append(&pos, " - ");
        status_append_long(&pos, g_stats.sends_dropped);
        status_append(&pos, " dropped");
    }
    status_end(pos);
}

static void handle_pong(const char *json, long len)
{
    long id;
    unsigned long delta;

    if (!now68k_pong_read(json, (size_t)len, &id)) {
        now68k_log("wire: malformed pong");
        return;
    }
    /* DEFECT 18 (id): the id read above used to be discarded, so a stale
     * or duplicate pong - one answering a ping cycle we have already
     * moved past - would still overwrite g_last_rtt_ms, timed against the
     * CURRENT g_ping_sent_tick rather than whichever ping it actually
     * answers. Only accept a pong that matches the one outstanding ping;
     * g_ping_id is cleared below once consumed so a retransmitted
     * duplicate cannot match twice. */
    if (g_ping_id == 0 || id != g_ping_id) {
        now68k_log_num("wire: pong id mismatch, ignored", id);
        return;
    }
    /* DEFECT 18 (overflow): TickCount() is ticks-since-boot, so
     * (delta * 1000UL) can wrap a 32-bit unsigned long well inside a
     * single uptime - and DEFECT 18 (stale base) made it worse, since
     * without the g_ping_sent_tick reset on a new session below, delta
     * could be the ENTIRE uptime rather than one ping's RTT. 1000/60 ==
     * 50/3, so scaling by 50 first instead of 1000 gives the same result
     * with 20x the headroom before the multiply can overflow. */
    delta = (unsigned long)TickCount() - g_ping_sent_tick;
    g_last_rtt_ms = (long)(delta * 50UL / 3UL);
    g_ping_id = 0;
    refresh_live_status();
}

static void handle_bye(const char *json, long len)
{
    char code[24];

    if (!read_string_field(json, (size_t)len, "code", code, sizeof code)) {
        code[0] = '\0';
    }
    {
        long pos;

        status_begin(&pos);
        status_append(&pos, "Host closed: ");
        status_append(&pos, code[0] != '\0' ? code : "(no code)");
        status_end(pos);
    }
    now68k_log("wire: bye from host");

    /* DEFECT 12: the code above used to be parsed and then ignored, so a
     * host closing with "protocol-error" got the same handling as one
     * saying "normal" or "shutting-down" - retried at the standing
     * cadence forever, hammering a peer that just told us the mismatch
     * producing the error will still be there on the next dial too.
     * "normal" and "shutting-down" keep the ordinary timed retry - that
     * auto-reconnect is exactly what those closes are for. A declared
     * protocol-error instead cancels the standing want-a-connection
     * intent outright (the one exception to DEFECT 17's rule that only
     * wire_start()/wire_stop() change it): unlike a transient dial
     * failure, retrying here cannot succeed until a human fixes
     * whatever the mismatch is. */
    if (strcmp(code, "protocol-error") == 0) {
        g_want = 0;
        g_retry_enabled = 0;
    }
    teardown_and_retry(NULL, NULL);
}

static void handle_error_from_host(const char *json, long len)
{
    char code[32];
    char message[64];
    char line[128];
    long pos = 0;

    if (!read_string_field(json, (size_t)len, "code", code, sizeof code)) {
        code[0] = '\0';
    }
    if (!read_string_field(json, (size_t)len, "message", message,
                            sizeof message)) {
        message[0] = '\0';
    }
    now68k_fmt_append_str(line, (long)sizeof line, &pos, "wire: host error ");
    now68k_fmt_append_str(line, (long)sizeof line, &pos, code);
    now68k_fmt_append_str(line, (long)sizeof line, &pos, ": ");
    now68k_fmt_append_str(line, (long)sizeof line, &pos, message);
    if (pos < 0 || pos >= (long)sizeof line) {
        pos = (long)sizeof(line) - 1;
    }
    line[pos] = '\0';
    now68k_log(line);
}

static void handle_host_hello(const char *json, long len)
{
    long contract = -1;
    char name[32];
    char version[24];

    if (!now68k_json_find_int(json, (size_t)len, "contract", &contract)
        || contract != NOW68K_CONTRACT_REVISION) {
        now68k_log_num("wire: host hello has an unexpected contract "
                        "revision", contract);
        set_status_str("Protocol error: contract mismatch");
        teardown_and_retry(NULL, "protocol-error");
        return;
    }

    if (!read_string_field(json, (size_t)len, "name", name, sizeof name)) {
        name[0] = '\0';
    }
    if (!read_string_field(json, (size_t)len, "version", version,
                            sizeof version)) {
        version[0] = '\0';
    }
    bounded_strcpy(g_peer_name, (long)sizeof g_peer_name, name);

    g_state = kWireLive;
    g_last_rtt_ms = -1;
    g_last_rx_tick = TickCount();
    g_next_ping_tick = g_last_rx_tick + (unsigned long)kWirePingIntervalTicks;
    g_ping_id = 0;
    /* DEFECT 18 (stale base): g_ping_sent_tick was reset in wire_init()
     * only, so a second (or later) session on the same launch inherited
     * whatever TickCount() the FIRST session's last ping happened to
     * sent at. g_ping_id == 0 above already blocks handle_pong() from
     * matching against it, but reset the base too so nothing stale
     * lingers past the point a new session actually begins. */
    g_ping_sent_tick = 0;

    {
        long pos;

        status_begin(&pos);
        status_append(&pos, "Connected");
        if (name[0] != '\0') {
            status_append(&pos, ": ");
            status_append(&pos, name);
        }
        if (version[0] != '\0') {
            status_append(&pos, " (v");
            status_append(&pos, version);
            status_append(&pos, ")");
        }
        status_end(pos);
    }
    now68k_log("wire: connected");
}

static void handle_refuse(const char *json, long len)
{
    char reason[64];

    if (!read_string_field(json, (size_t)len, "reason", reason,
                            sizeof reason)) {
        reason[0] = '\0';
    }
    {
        long pos;

        status_begin(&pos);
        status_append(&pos, "Refused: ");
        status_append(&pos, reason[0] != '\0' ? reason : "(no reason given)");
        status_end(pos);
    }
    now68k_log("wire: refused by host");
    /* No bye of our own here: the host has already decided to close
     * ("the host answers hello (accept) or refuse and closes" -
     * contract), so a guest-initiated bye would be redundant at best and
     * racing the host's own close at worst. */
    teardown_and_retry(NULL, NULL);
}

/* ---- command.request / census.request: contract-shaped replies --------- */
/* DEFECT 11. Unlike send_error_reply()'s generic "not implemented", the
 * contract gives these two message families their own reply envelope, and
 * a host waiting on a command.result or census.report for a given id would
 * never see one otherwise (an error message doesn't satisfy that wait). */

/* CensusRequest.probe is the first peer-controlled string this file ever
 * echoes back inside JSON WE transmit (every other one - bye.code,
 * refuse.reason, error.message - only ever reaches a status line or a log
 * call). send_error_reply() already declined to echo the failed request's
 * own "type" for this exact reason: "our JSON writer never escapes text,
 * and a peer-controlled ... string could contain a byte (a bare quote or
 * backslash) that breaks the JSON we are trying to emit." Replace anything
 * that could reopen or escape our string literal, in place, before it is
 * appended - cheaper than a real escaper and sufficient because the only
 * bytes that can break a JSON string literal are '"', '\\', and raw
 * control characters. */
static void sanitize_json_string(char *s)
{
    for (; *s != '\0'; ++s) {
        unsigned char c = (unsigned char)*s;

        if (c == '"' || c == '\\' || c < 0x20) {
            *s = '?';
        }
    }
}

static void handle_command_request(const char *json, long len)
{
    char payload[NOW68K_COMMAND_RESULT_CAP];
    char name[32];
    char args[224];
    long pos = 0;
    int ok = 1;
    long id = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    /* Two commands are implemented (launch, quit); everything else still
     * falls through to unknown-command below. The dispatcher writes nothing
     * unless it recognises the name, so the fallback can reuse this buffer. */
    if (!read_string_field(json, (size_t)len, "name", name, sizeof name)) {
        name[0] = '\0';
    }
    /* The argument is args.target, NOT args itself: CommandRequest.args is an
     * OBJECT ({"target":"TeachText"}), so reading "args" as a string always
     * came back empty and every launch/quit answered bad-args. The scanner is
     * flat and first-occurrence-wins, which is safe here precisely because the
     * contract forbids an arg key from shadowing type/id/name/args - "target"
     * appears only inside the args object. */
    if (!read_string_field(json, (size_t)len, "target", args, sizeof args)) {
        args[0] = '\0';
    }
    if (name[0] != '\0') {
        long built = 0;
        if (now68k_commands_dispatch(name, args, have_id ? id : 0,
                                     payload, (long)sizeof payload, &built)
            && built > 0) {
            if (!enqueue_control_send(payload, built)) {
                now68k_log("wire: command.result dropped, outbound queue full");
            }
            return;
        }
    }

    /* Unrecognised: the contract's own answer is a command.result carrying
     * ok:false and code "unknown-command", never a protocol error
     * (CommandRequest.name doc: "that is what keeps commands additive").
     * CommandResult.id is required by the schema, so it is always emitted,
     * defaulting to 0 on the (contract-violating) case where the request
     * itself had none - better than silence. */
    pos = 0;
    ok = 1;
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       have_id ? id : 0);
    ok = ok && now68k_fmt_append_str(
                   payload, (long)sizeof payload, &pos,
                   ",\"ok\":false,\"error\":{\"code\":\"unknown-command\","
                   "\"message\":\"no commands implemented\"}}");
    if (!ok || pos <= 0) {
        now68k_log("wire: command.result build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: command.result dropped, outbound queue full");
    }
}

static void handle_census_request(const char *json, long len)
{
    char payload[160];
    char probe[24];
    long pos = 0;
    int ok = 1;
    long id = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (!read_string_field(json, (size_t)len, "probe", probe,
                            sizeof probe)) {
        probe[0] = '\0';
    }
    sanitize_json_string(probe);

    /* This guest implements no x-census probes, so every census.request is
     * "refused" (CensusRequest.probe doc: "never a protocol error; that is
     * what keeps the registry additive"), never "absent" - "absent" means
     * the machine was asked and said no, which is not what happened here.
     * CensusReport.id/probe/outcome/rows/more are all required by the
     * schema and so are always emitted. */
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"census.report\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       have_id ? id : 0);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"probe\":\"");
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      probe);
    ok = ok && now68k_fmt_append_str(
                   payload, (long)sizeof payload, &pos,
                   "\",\"outcome\":\"refused\",\"rows\":[],\"more\":false,"
                   "\"note\":\"no probes implemented\"}");
    if (!ok || pos <= 0) {
        now68k_log("wire: census.report build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: census.report dropped, outbound queue full");
    }
}

/* ---- process.list: this guest's share of the symmetric family --------- */

/* The snapshot one process.list page is cut from. Static rather than a
 * local because it is 48 rows of ~56 bytes and proc_list_rows() is called
 * from inside the frame reader's callback chain - proc68.c already spends
 * 1920 bytes of stack on proc_list's own scratch, and stacking another
 * 2.6 KB underneath it is the kind of thing that shows up as a crash on
 * metal and nowhere else. Single-threaded, one caller, rebuilt on every
 * request. 48 is proc68.c's kProcListScratchMax, deliberately the same
 * number: two different ceilings on "how many processes exist" would
 * disagree the day one of them mattered.
 *
 * Rebuilt per PAGE, not per walk: a listing that pages sees a fresh
 * snapshot for each page, so a process that quits mid-listing can shift
 * the rows after it by one. The PowerPC guest's serve_process_list has
 * exactly the same property (it re-walks the Process Manager per page),
 * and the contract's cursor is an index, not a stable handle. Worth
 * knowing; not worth a snapshot cache that can go stale in the other
 * direction. */
static N68ProcRow g_proc_rows[48];

/* Serve process.list from our OWN Process Manager. The contract's rule is
 * that whoever RECEIVES the message serves its own list; NOW implements
 * the host->guest direction only, and this is that direction's guest half.
 *
 * Read-only and needs no share - a process list reveals nothing a person
 * standing at the machine could not read off the Application menu. It is
 * also what makes `quit` independently checkable on this guest: until now
 * the only way to ask "is it gone?" was to ask `quit` again, the same
 * subsystem that just answered. */
static void handle_process_list(const char *json, long len)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    long id = 0;
    long cursor = 0;
    long count;
    long n;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (!now68k_json_find_int(json, (size_t)len, "cursor", &cursor)) {
        cursor = 1;   /* absent cursor means the first page */
    }
    count = proc_list_rows(g_proc_rows,
                            (long)(sizeof g_proc_rows / sizeof g_proc_rows[0]));
    n = n68_proclist_build(have_id ? id : 0, cursor, g_proc_rows, count,
                            payload, (long)sizeof payload, NULL, NULL);
    if (n <= 0) {
        /* Unreachable at the shipping cap - the static asserts at the top
         * of this file are what make it so - but a host waiting on a
         * process.listing must never wait forever, so say something. */
        now68k_log("wire: process.listing build failed");
        send_error_reply(have_id ? id : 0, have_id);
        return;
    }
    if (!enqueue_control_send(payload, n)) {
        now68k_log("wire: process.listing dropped, outbound queue full");
    }
}

/* Dispatch for one fully-received control payload. Everything the guest
 * does not implement (capture, files, streams, the process drive verbs and
 * the software listing) falls through to the generic error reply - see
 * wire68.h and the send_error_reply comment for why that is the generic
 * shape rather than each family's own bespoke refusal message. */
static void handle_control_message(const char *json, long len)
{
    char type[32];

    if (len <= 0) {
        now68k_log("wire: empty control frame");
        return;
    }
    if (!now68k_json_read_type(json, (size_t)len, type, (long)sizeof type)) {
        now68k_log("wire: control frame has no readable type");
        return;
    }

    if (g_state == kWireGreeting) {
        /* "Nothing else may precede hello" (contract) applies to the host's
         * side of the handshake too: only hello or refuse are legal here. */
        if (strcmp(type, "hello") == 0) {
            handle_host_hello(json, len);
            return;
        }
        if (strcmp(type, "refuse") == 0) {
            handle_refuse(json, len);
            return;
        }
        now68k_log("wire: unexpected message before handshake completed");
        set_status_str("Protocol error: unexpected reply");
        teardown_and_retry(NULL, "protocol-error");
        return;
    }

    /* kWireLive */
    if (strcmp(type, "pong") == 0) {
        handle_pong(json, len);
        return;
    }
    if (strcmp(type, "bye") == 0) {
        handle_bye(json, len);
        return;
    }
    if (strcmp(type, "error") == 0) {
        handle_error_from_host(json, len);
        return;
    }
    if (strcmp(type, "hello") == 0 || strcmp(type, "refuse") == 0) {
        now68k_log("wire: handshake message repeated after connect");
        set_status_str("Protocol error: repeated handshake");
        teardown_and_retry(NULL, "protocol-error");
        return;
    }
    /* DEFECT 11: command.request and census.request have contract-mandated
     * reply shapes for "not implemented" - command.result{ok:false,
     * error.code:"unknown-command"} and census.report{outcome:"refused"}
     * respectively (asyncapi.yaml: "never a protocol error; that is what
     * keeps commands additive" / "keeps the registry additive"). Routing
     * them into the generic send_error_reply() below used to leave a host
     * waiting on a command.result or census.report for this id forever -
     * the wrong envelope answers a different waiter than the one that is
     * actually blocked. */
    if (strcmp(type, "command.request") == 0) {
        handle_command_request(json, len);
        return;
    }
    if (strcmp(type, "census.request") == 0) {
        handle_census_request(json, len);
        return;
    }
    if (strcmp(type, "process.list") == 0) {
        handle_process_list(json, len);
        return;
    }

    {
        long id;
        int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

        send_error_reply(have_id ? id : 0, have_id);
    }
}

/* ---- frame read state machine ------------------------------------------- */

/* The machine itself is n68_reader.c, driven through kReadOps above. It is
 * called from both kWireGreeting (to receive the host's hello) and kWireLive
 * so the same header/skip/body machinery serves the whole connection. */
static void drain_frames(void)
{
    /* The entry half of read_still_reading()'s back-pressure. That hook is
     * only asked AFTER a message, so without this check a pass that begins
     * with a full queue (flush_outbound made no progress) would still read
     * and fail to answer one more request. Same reasoning, other end of
     * the loop: do not read what we cannot answer. */
    if (g_out_count >= kWireOutQueueDepth) {
        return;
    }
    n68_reader_drain(&g_read);
}

/* ---- outbound protocol messages ----------------------------------------- */

static void queue_hello(void)
{
    char payload[kWireOutPayloadCap];
    long n = now68k_hello_build(payload, (long)sizeof payload,
                                 NOW68K_CONTRACT_REVISION,
                                 NOW68K_APP_VERSION);

    if (n <= 0) {
        set_status_str("Internal error building hello");
        /* TCP is up (we are only called from kWireGreeting) even though
         * this is our own bug rather than the peer's - a graceful close
         * costs nothing more than the abort it replaces. */
        teardown_and_retry("wire: hello payload did not fit its buffer",
                            "protocol-error");
        return;
    }
    if (!enqueue_control_send(payload, n)) {
        set_status_str("Internal error queuing hello");
        teardown_and_retry("wire: could not queue the hello frame",
                            "protocol-error");
    }
}

/* Returns 1 if a ping went into the queue. The caller must not advance the
 * ping deadline on a 0 - a keepalive that never left counts the next 30 s
 * from a message that does not exist.
 *
 * The last slot is reserved for replies. That was the original reason for
 * having two slots at all ("the reply must not be the one that gets
 * dropped because the ping got the only slot first"), left to emerge from
 * the depth; with a deeper queue and paged listings it has to be stated,
 * because a listing walking the queue down to its last slot is exactly
 * when a ping would take it. A deferred ping is not a drop and is not
 * logged: nothing is lost, the deadline does not move, and the next pass
 * sends it as soon as there is room. If there is never room for 65 s the
 * keepalive watchdog fires, which is the correct answer to a wire that
 * cannot absorb thirty bytes. */
static int send_ping(void)
{
    char payload[40];
    long n;

    if (g_out_count >= kWireOutQueueDepth - 1) {
        return 0;
    }
    n = now68k_ping_build(payload, (long)sizeof payload, g_ping_id + 1);
    if (n <= 0) {
        now68k_log("wire: ping build failed");
        return 0;
    }
    if (!enqueue_control_send(payload, n)) {
        now68k_log("wire: ping dropped, outbound queue full");
        return 0;
    }
    /* The id advances only once the ping is really queued: handle_pong
     * matches on g_ping_id, so bumping it for a ping that never went out
     * would leave the guest waiting on an answer to nothing. */
    ++g_ping_id;
    g_ping_sent_tick = TickCount();
    ++g_stats.pings_sent;
    return 1;
}

/* ---- dial / redial ------------------------------------------------------- */

static void begin_dial(void)
{
    short err;

    reset_read_state();
    reset_outbound_queue();
    ++g_stats.dials;
    err = net_connect(g_target_ip, g_target_port, g_target_timeout);
    if (err != 0) {
        long pos;

        status_begin(&pos);
        status_append(&pos, "Connect failed (error ");
        status_append_long(&pos, (long)err);
        status_append(&pos, ")");
        status_end(pos);
        /* net_connect() itself failed synchronously: there is no stream
         * to say goodbye on. */
        teardown_and_retry("wire: net_connect returned an error", NULL);
        return;
    }
    g_state = kWireDialing;
    set_status_str("Connecting...");
}

static void service_dialing(void)
{
    NetState ns = net_state();

    if (ns == kNetConnecting) {
        return;
    }
    if (ns == kNetConnected) {
        g_state = kWireGreeting;
        reset_read_state();
        g_hello_deadline = TickCount() + (unsigned long)kWireHelloTimeoutTicks;
        set_status_str("Connected, waiting for host...");
        queue_hello();
        return;
    }
    /* kNetFailed, or unexpectedly still kNetIdle. */
    {
        long pos;

        status_begin(&pos);
        status_append(&pos, "Connect failed: ");
        status_append(&pos, net_last_error());
        status_end(pos);
    }
    /* kNetFailed here means the connect itself never reached kNetConnected
     * - no stream to say goodbye on. */
    teardown_and_retry("wire: dial failed", NULL);
}

static void service_greeting(void)
{
    flush_outbound();
    drain_frames();
    if (g_state != kWireGreeting) {
        return;   /* moved to Live, or torn down, inside drain_frames */
    }
    if (TickCount() > g_hello_deadline) {
        set_status_str("No answer from host");
        /* TCP connected but the host never answered hello (NOT in the
         * contract - see kWireHelloTimeoutTicks). "protocol-error" is the
         * closest of the three declared bye codes to "the handshake this
         * guest expected did not happen". */
        teardown_and_retry("wire: timed out waiting for the host's hello",
                            "protocol-error");
    }
}

static void service_live(void)
{
    unsigned long now;

    flush_outbound();
    drain_frames();
    if (g_state != kWireLive) {
        return;   /* torn down inside drain_frames (protocol error / bye) */
    }
    now = TickCount();
    if (now - g_last_rx_tick > (unsigned long)kWireDeadTicks) {
        set_status_str("Connection timed out");
        /* No bye: the peer has already gone 65s+ without a word back, so
         * the link is presumed dead, not merely quiet - trying to send a
         * graceful close over it is exactly the case "bye is best-effort"
         * exists to excuse skipping. */
        teardown_and_retry("wire: no traffic within the keepalive window",
                            NULL);
        return;
    }
    /* DEFECT 18 (ALSO): the contract's keepalive is GUEST-driven ping
     * after 30s of WIRE SILENCE, but g_next_ping_tick used to advance only
     * from the last time WE sent a ping, never pulled back in by inbound
     * traffic - so once connected, a ping fired on a fixed 30s cadence
     * regardless of how recently the host had actually spoken. Re-anchor
     * the deadline to the last inbound byte whenever that pushes it
     * later than what is already scheduled. */
    if (g_last_rx_tick + (unsigned long)kWirePingIntervalTicks > g_next_ping_tick) {
        g_next_ping_tick = g_last_rx_tick + (unsigned long)kWirePingIntervalTicks;
    }
    if (now >= g_next_ping_tick && send_ping()) {
        g_next_ping_tick = now + (unsigned long)kWirePingIntervalTicks;
    }
}

static void service_waiting(void)
{
    if (TickCount() >= g_next_dial_tick) {
        begin_dial();
    }
}

/* ---- public API ---------------------------------------------------------- */

void wire_init(void)
{
    short err;

    g_state = kWireIdle;
    g_want = 0;
    g_target_ip = 0;
    g_target_port = 0;
    g_target_timeout = 0;
    g_retry_enabled = 0;
    g_retry_interval_secs = kWireRetryFloorSecs;
    g_next_dial_tick = 0;
    g_hello_deadline = 0;
    g_last_rx_tick = 0;
    g_next_ping_tick = 0;
    g_ping_sent_tick = 0;
    g_ping_id = 0;
    g_last_rtt_ms = -1;
    g_peer_name[0] = '\0';
    memset(&g_stats, 0, sizeof g_stats);
    reset_read_state();
    reset_outbound_queue();

    err = net_init();
    g_net_ready = (err == 0);
    if (g_net_ready) {
        set_status_str("Not connected");
    } else {
        set_status_str("MacTCP unavailable");
        now68k_log_num("wire: net_init failed", (long)err);
    }
}

void wire_set_target(unsigned long ip, unsigned short port,
                      unsigned short connect_timeout_secs)
{
    g_target_ip = ip;
    g_target_port = port;
    g_target_timeout = connect_timeout_secs;
}

void wire_set_retry(short enabled, unsigned short interval_secs)
{
    g_retry_enabled = (short)(enabled != 0);
    if (interval_secs < kWireRetryFloorSecs) {
        interval_secs = kWireRetryFloorSecs;
    }
    g_retry_interval_secs = interval_secs;
}

void wire_start(void)
{
    if (!g_net_ready) {
        set_status_str("MacTCP unavailable");
        return;
    }
    g_want = 1;
    if (g_state == kWireIdle || g_state == kWireWaiting) {
        begin_dial();
    }
    /* Already dialing/greeting/live: g_want is already what it should be. */
}

void wire_stop(void)
{
    g_want = 0;
    if (g_state == kWireIdle) {
        return;
    }
    if (g_state == kWireGreeting || g_state == kWireLive) {
        /* DEFECT 6: this used to go straight to net_disconnect() (an
         * abortive TCPAbort) unconditionally, which throws away anything
         * already staged and leaves the host to notice the guest is gone
         * only via the ~65s keepalive death window. code "normal": a
         * human asked to disconnect; the application itself keeps
         * running. */
        send_bye_and_close("normal");
    } else {
        /* kWireDialing or kWireWaiting: no TCP stream exists yet (or one
         * is only mid-connect), so there is nothing to say goodbye on. */
        net_disconnect();
    }
    reset_read_state();
    reset_outbound_queue();
    g_state = kWireIdle;
    set_status_str("Stopped");
}

void wire_shutdown(void)
{
    /* MUST be correct on every quit path, including the one where the
     * human never pressed Connect (net_shutdown() below is documented
     * safe to call when net_init() was never even reached). An earlier
     * version of wire68.h declared no such verb, so nothing could call
     * net_shutdown() and every launch leaked a MacTCP stream whose
     * rcvBuff pointed into our BSS - which the .IPP driver kept writing
     * to at interrupt time after the application's memory was gone. */
    if (g_state == kWireGreeting || g_state == kWireLive) {
        /* code "shutting-down": the application itself is exiting, not
         * just disconnecting - the one case in this file where DEFECT 6's
         * fix and this verb's own reason for existing are the same call. */
        send_bye_and_close("shutting-down");
    } else if (g_state != kWireIdle) {
        net_disconnect();
    }
    reset_read_state();
    reset_outbound_queue();
    g_state = kWireIdle;
    g_want = 0;
    net_shutdown();
}

long wire_sleep_ticks(long idle_ticks)
{
    /* Dial setup and the hello handshake want the same fast-poll
     * treatment as an in-flight net.h send/receive, even before any bytes
     * have moved - net_sleep_ticks() only knows about net.h's own
     * activity, not about service_dialing() waiting on a net_state()
     * transition or service_greeting()'s hello_deadline, so those two
     * states are forced to 0 here rather than trusting net.h to already
     * cover them. */
    if (g_state == kWireDialing || g_state == kWireGreeting) {
        return 0;
    }
    /* A ping that has already gone out and is waiting for its answer is just
     * as much "in flight" as a send, but net.h cannot know that - from its
     * side the send completed and nothing is outstanding. Measured on the
     * PowerBook 180c, leaving it out cost a whole idle sleep on every other
     * round trip: RTT settled into a clean two-state alternation of 2 ticks
     * (the real round trip) and 7 ticks (2 + one kSleepTicks nap), because
     * successive pongs land at alternating phases of the sleep.
     *
     * Bounded on purpose. Fast-polling until the pong arrives would spin at
     * zero sleep for the full 65 s death window if an answer is ever lost,
     * and this machine runs on a battery. One round trip is worth staying
     * awake for; a lost one is not. */
    if (g_state == kWireLive && g_ping_id != 0) {
        unsigned long waited = (unsigned long)TickCount() - g_ping_sent_tick;
        if (waited < kWirePongPollTicks) {
            return 0;
        }
    }
    return net_sleep_ticks(idle_ticks);
}

void wire_idle(void)
{
    net_idle();

    switch (g_state) {
    case kWireIdle:
        break;
    case kWireDialing:
        service_dialing();
        break;
    case kWireGreeting:
        service_greeting();
        break;
    case kWireLive:
        service_live();
        break;
    case kWireWaiting:
        service_waiting();
        break;
    }
}

WireState wire_state(void)
{
    return g_state;
}

const char *wire_status(void)
{
    return g_status;
}

long wire_last_rtt_ms(void)
{
    return g_last_rtt_ms;
}

void wire_stats(WireStats *out)
{
    if (out == NULL) {
        return;
    }
    *out = g_stats;
}
