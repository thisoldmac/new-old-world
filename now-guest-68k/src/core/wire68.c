/*
 * wire68.c - implementation of wire68.h. See that header for the design
 * rationale (why fixed-interval redial, why this is not a wire.c port).
 *
 * Derived from contract/asyncapi.yaml (connection rules preamble + Hello /
 * Refuse / Ping / Pong / Error schemas), cross-checked against the shipping
 * PPC guest's now/now-guest-ppc/src/core/wire.c for the two timings the contract states
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
 *   g_sink                256  bytes  (bulk delivery / oversized-control
 *                                     discard scratch)
 *   g_put_batch          8192  bytes  (kN68PutProgressStep - the file
 *                                     receive write batch; the single
 *                                     largest thing this file owns, and
 *                                     the reason the whole feature costs
 *                                     what it does. See n68_putrx.h for
 *                                     why it is this size and not larger)
 *   g_putrx (N68PutRx)    ~340  bytes  (offer + counters + buffer ptrs)
 *   g_putfile             ~690  bytes  (two FSSpecs, the open forks, and
 *                                     512 bytes of resource-fork head
 *                                     kept for the close-time verify -
 *                                     n68_putfile.h says why that exists)
 *   g_put_last_* etc.      ~90  bytes  (what `xfer` reports after the fact)
 *   g_out[4] slots          4 * (8 header + 1024 payload + 4 len + 4 off)
 *                         4 * 1040 = 4160  bytes  (was 1056 at depth 2 and
 *                                                 a 512-byte payload cap,
 *                                                 and 352 at 160 - see
 *                                                 NOW68K_CONTROL_SEND_CAP
 *                                                 in wire68.h and the
 *                                                 kWireOutQueueDepth
 *                                                 comment below for the
 *                                                 arithmetic behind both)
 *   g_file_rows[16]        16 * ~56        = 896  bytes  (one file.list
 *                                                 page; see its own comment
 *                                                 for why it is not on the
 *                                                 stack)
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
 *
 * Measured whole-application delta for the file-receive pass (this file's
 * new state plus n68_crc32.c's 1 KB table, n68_putrx.c and n68_putfile.c),
 * m68k-apple-macos-size, -O2, against fcda926:
 *     text 105644 -> 113796  (+8152)
 *     data   8360 ->   9756  (+1396)
 *     bss   50508 ->  60368  (+9860)
 * so +19408 bytes, about 5% of the 384 KB application partition, which
 * now holds roughly 184 KB of image before stack and heap. That is the
 * largest single addition this application has taken and it is worth
 * saying plainly: the partition is preferred == minimum on a 4 MB
 * machine (now-guest-68k.r), so there is no headroom to borrow, and the next
 * feature of this size needs the budget looked at rather than assumed.
 *
 * Measured whole-application delta for the BROWSE half (this file's
 * g_file_rows and handler, n68_fileenum.c, n68_filelist.c, and the rows
 * result type in n68_cmdresult.c), m68k-apple-macos-size, -O2, against
 * bb54ab3:
 *     text 138328 -> 145064  (+6736)
 *     data  13040 ->  13648   (+608)
 *     bss   67224 ->  69928  (+2704)
 * so +10048 bytes, about 2.6% of the partition. The bss is the honest
 * cost of the design: ~900 bytes for the page this file cuts a listing
 * from and ~1.8 KB for commands68.c's one N68CmdRows, both file-scope
 * rather than stack because the command path can be re-entered (see the
 * DEFECT 3 note in proc68.c for what that cost the last time it was
 * assumed away).
 *
 * Measured whole-application delta for the SOFTWARE family (this file's
 * g_sw_rows and handler, n68_swenum.c, n68_swlist.c and commands68.c's
 * `sw`), m68k-apple-macos-size, -O2, against cc67682:
 *     text 170216 -> 178188  (+7972)
 *     data  17940 ->  18652   (+712)
 *     bss   75396 ->  80072  (+4676)
 * so +13360 bytes, about 3.5% of the 384 KB partition. The bss is almost
 * entirely the two bounded caches this design is built on and neither is
 * incidental: ~3360 bytes for the apps sweep's 48 FSSpecs
 * (NOW68K_SWLIST_APP_CACHE_MAX, which is the whole reason a whole-volume
 * sweep is affordable here at all) and ~1300 for the page this file cuts a
 * listing from. AGENTS.md's warning after the file-receive pass still
 * stands: the partition is preferred == minimum on a 4 MB machine, there
 * is no headroom to borrow, and the next feature of this size needs the
 * budget looked at rather than assumed.
 */
#include "wire68.h"
#include "continuity_udp.h"
#include "commands68.h"

#include "contract.h"
#include "frame.h"
#include "hello.h"
#include "json_scan.h"
#include "log.h"
#include "n68_fileenum.h"
#include "n68_filelist.h"
#include "census68.h"        /* census.request: the hardware census */
#include "n68_cmdresult.h"   /* now68k_json_append_escaped */
#include "n68_census.h"
#include "n68_exec.h"        /* exec.request: the console plane */
#include "n68_filesrc.h"
#include "n68_proclist.h"
#include "n68_putfile.h"
#include "n68_putrx.h"
#include "n68_puttx.h"
#include "n68_shotwire.h"
#include "n68_swenum.h"
#include "n68_swlist.h"
#include "shotstage68.h"
#include "n68_reader.h"
#include "numfmt.h"
#include "ping.h"
#include "proc68.h"

#include <OSUtils.h>    /* TickCount */
#include <string.h>     /* strcmp, strlen (via numfmt callers) */

/* No canonical app-version constant exists yet in now-guest-68k/src (see
 * contract.h for the one that does exist, NOW68K_CONTRACT_REVISION). This is
 * a local placeholder for Hello.version, which the schema says is "for
 * display only" - nothing on the wire depends on its value. */
/* Bump this on every build that goes to a machine. The host shows it as
 * "Connected: now-68k v<X>", and with the FTP server appending #2/#3 rather
 * than overwriting, that string is the only reliable answer to "which build
 * am I actually running" - AGENTS.md: check the build stamp before believing
 * a test result. */
#define NOW68K_APP_VERSION "0.22"

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
_Static_assert(NOW68K_CONTROL_SEND_CAP >= NOW68K_CENSUS_MIN_CAP,
               "the outbound slot cannot carry a census.report with a row in "
               "it and still say `more` - every page would be empty with "
               "more:true and the host would page forever, which is the same "
               "loop the two asserts around this one prevent");
_Static_assert(NOW68K_CONTROL_SEND_CAP >= NOW68K_FILELIST_MIN_CAP,
               "the outbound slot cannot carry a file.listing page with an "
               "entry in it - the same infinite paging loop, one message "
               "family over. Shorten NOW68K_FILELIST_PATH_MAX, or widen the "
               "slot");
_Static_assert(NOW68K_CONTROL_SEND_CAP >= NOW68K_SWLIST_MIN_CAP,
               "the outbound slot cannot carry a software.listing page with "
               "an entry in it - the same infinite paging loop again. "
               "NOW68K_SWLIST_PATH_MAX is what this bound was solved for; "
               "shorten it, or widen the slot");

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
/* Scratch for the skip state (discard) and the bulk state (deliver). The
 * bulk state hands whatever it reads straight to n68_putrx, so this size
 * costs nothing in throughput terms - it only decides how many memcpys a
 * frame takes. 256 is inherited from when this was a pure discard sink;
 * a 4 MB transfer at 8 KB frames therefore makes ~32 passes per frame,
 * each a bounded memcpy into the receive batch. Worth measuring on the
 * 180c before enlarging: BSS is the scarcer resource here. */
static unsigned char   g_sink[256];

/* ---- the file family's receive half -----------------------------------
 * One transfer at a time (the lane is one transfer wide, and a 384 KB
 * partition has no room to hold a second offer open). The batch buffer
 * is the single largest thing this file owns; see the static budget at
 * the top of this file. */
static N68PutRx        g_putrx;
static N68PutFile      g_putfile;
static unsigned char   g_put_batch[kN68PutProgressStep];
static long            g_put_id;         /* the offer id in flight */
/* The BULK correlation id of the transfer arriving, taken from
 * file.begin. Kept only because file.cancel names a transfer and nothing
 * else - it carries no id - so without this there is no way to tell a
 * cancel meant for the push in flight from one for a transfer that has
 * already ended. 0 means "no file.begin has been seen yet". */
static unsigned short  g_put_transfer;
/* What the console's own face on this capability reads. Kept across the
 * end of a transfer on purpose: "what happened to the last one" is the
 * question a person actually has, and it is unanswerable the moment the
 * transfer is over if nothing is remembered. */
static char            g_put_last_name[kN68PutNameCap];
static long            g_put_last_bytes;
static int             g_put_last_ok;
static char            g_put_last_code[16];
static int             g_put_had_one;

static OutSlot         g_out[kWireOutQueueDepth];
static int             g_out_head = 0;   /* next slot to flush */
static int             g_out_count = 0;  /* occupied slots */

/* ---- the file family's SEND half --------------------------------------
 *
 * The rule for how these bytes share the wire with the control queue
 * above is stated once, in n68_puttx.h. The part of it that lives here
 * is the slot: ONE bulk frame, its own buffer, never a control slot.
 * That is rule 1, and it is structural rather than disciplined - there
 * is no code path by which a transfer of any length can consume a slot
 * a command.result needs.
 *
 * 4104 bytes (8 + 4096). It is the second largest thing this file owns,
 * after the receive batch, and it is deliberately NOT unioned with that
 * batch even though the contract's one-transfer-at-a-time rule means the
 * two can never both be live. The saving would be 4 KB out of a 384 KB
 * partition - about 1% - and the cost would be two state machines whose
 * safety depended on an invariant enforced somewhere neither of them can
 * see. */
static N68SendTx       g_puttx;
static N68FileSrc      g_filesrc;
static unsigned char   g_bulk[kN68SendFrameCap];
static long            g_bulk_len = 0;   /* frame bytes staged, 0 = empty */
static long            g_bulk_off = 0;   /* bytes already accepted */
static long            g_send_next_id = 1;
static unsigned short  g_send_next_transfer = 1;

/* THIS TRANSFER IS A CAPTURE, not a file. The lane, the chunking, the
 * back-pressure rule and the source interface are all n68_puttx's and are
 * shared verbatim; what differs is the ENVELOPE - the contract announces a
 * capture with capture.begin/capture.end and a file with
 * file.offer/begin/end - and the handshake, because a host-requested
 * capture has no offer/accept step to wait through (contract:
 * capture.request -> capture.begin -> bulk -> capture.end). Two senders
 * would have been two back-pressure rules; one sender with two envelopes
 * is the arrangement n68_bytesrc.h was shaped for. */
static int             g_send_is_capture = 0;
static N68ShotWirePlan g_capture_plan;
static long            g_capture_capture_ms = 0;
static long            g_capture_encode_ms = 0;
static long            g_capture_id = 0;
static unsigned short  g_capture_transfer = 0;

/* Defined with the send half, below; declared here because the control
 * dispatcher is above it. */
int now68k_wire_send_capture(long id, char *why, long why_cap);
static void handle_capture_request(const char *json, long len);
static unsigned long   g_send_start_tick = 0;

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

/* A bounded quoted-string read for an arbitrary key.
 *
 * This WAS a local copy of now68k_json_read_type with the key made a
 * parameter, written because that function is hardcoded to "type". The
 * file family needs the same read for name / path / container, which
 * would have made a third caller of a second implementation - so the
 * generalized form now lives in json_scan.c beside the scanner it is
 * built on, read_type is that function with the key filled in, and this
 * is the one name the rest of this file already calls it by. */
#define read_string_field(json, json_len, key, out, cap) \
    now68k_json_find_string((json), (json_len), (key), (out), (cap))

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

static void put_report_progress(int force);
static void put_finish_failed(N68PutCode code);

/* Bulk is wanted exactly while a push is in flight. Anything else -
 * a frame that outlived its transfer, a capture this guest never asked
 * for - is consumed and dropped, which is what this reader did with
 * every bulk frame before there was a file family at all. */
static int read_bulk_wanted(void *ctx, unsigned long length)
{
    (void)ctx;
    (void)length;
    return g_putrx.active;
}

/* One run of file bytes. n68_putrx owns what happens to them; this
 * decides only whether the host still needs telling.
 *
 * A write failure is NOT reported back to the reader: the frame still
 * has to be drained to stay in sync, and n68_putrx has already
 * discarded the partial and gone inactive - so the rest of this frame
 * arrives with nothing expecting it and is dropped, which is exactly
 * right. The host learns from the file.done that follows. */
static void read_bulk_data(void *ctx, const unsigned char *bytes, long len)
{
    N68PutCode rc;

    (void)ctx;
    rc = n68_putrx_data(&g_putrx, bytes, len);
    if (rc != kN68PutOK) {
        put_finish_failed(rc);
        return;
    }
    if (n68_putrx_due_report(&g_putrx)) {
        put_report_progress(0);
    }
}

static const N68ReaderOps kReadOps = {
    read_take,
    read_took,
    read_frame_started,
    read_oversized_frame,
    read_oversized_control,
    read_empty_control,
    read_bulk_wanted,
    read_bulk_data,
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
    /* Same reasoning as the reader's own reset, one layer up: a
     * half-received FILE from a dead connection has nothing to do with
     * the next one, and its staging file is debris that must not
     * outlive the connection that was writing it. Sending file.done
     * would be pointless - there is no longer anyone to send it to. */
    n68_putrx_cancel(&g_putrx);
    /* And the same for a transfer going the other way. This is where the
     * open data fork of an outbound file gets closed on a dropped
     * connection - promise (5) in n68_bytesrc.h says close() happens on
     * EVERY ending, and a link that died mid-chunk is the ending nobody
     * writes code for. */
    n68_puttx_cancel(&g_puttx, kN68SendGone);
    g_send_start_tick = 0;
}

static void reset_outbound_queue(void)
{
    g_out_head = 0;
    g_out_count = 0;
    /* The staged chunk belongs to the connection that was carrying it. */
    g_bulk_len = 0;
    g_bulk_off = 0;
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

/* Hands one staged frame's remaining bytes toward net.h. Returns 1 when
 * the whole frame is away, 0 when the transport took less than all of it
 * and the rest must wait - which is the ONLY back-pressure signal this
 * side has and the only one it needs (n68_puttx.h, rule 4). */
static int flush_one(unsigned char *buf, long *len, long *off)
{
    long remaining = *len - *off;
    long sent;

    if (remaining <= 0) {
        *len = 0;
        *off = 0;
        return 1;
    }
    sent = net_queue_send(buf + *off, remaining);
    if (sent <= 0) {
        return 0;
    }
    *off += sent;
    g_stats.bytes_out += sent;
    if (*off < *len) {
        return 0;       /* short accept: the rest waits for room */
    }
    ++g_stats.frames_out;
    *len = 0;
    *off = 0;
    return 1;
}

/* Drains what is staged, in the order n68_puttx.h states. A short accept
 * stops the drain rather than starting the next frame's bytes early, so
 * two frames never interleave on the wire even though net.h's own staging
 * buffer is what actually paces the TCPSend calls. */
static void flush_outbound(void)
{
    /* RULE 2. A frame whose bytes have already begun going out finishes
     * before any other frame's first byte. Only one frame can ever be
     * part-sent, so this is the single place bulk may go ahead of the
     * control queue - and it must, because the alternative is a frame
     * cut in half by a reply. */
    if (g_bulk_len > 0 && g_bulk_off > 0) {
        if (!flush_one(g_bulk, &g_bulk_len, &g_bulk_off)) {
            return;
        }
    }

    /* RULE 3. Control before bulk. A reply queued during a transfer waits
     * for the chunk in flight and never for the transfer. */
    while (g_out_count > 0) {
        OutSlot *s = &g_out[g_out_head];

        if (!flush_one(s->buf, &s->len, &s->off)) {
            return;
        }
        g_out_head = (g_out_head + 1) % kWireOutQueueDepth;
        --g_out_count;
    }

    if (g_bulk_len > 0) {
        (void)flush_one(g_bulk, &g_bulk_len, &g_bulk_off);
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
/* Get what was just queued onto the wire, then drive net_close()'s
 * queued-send/TCPClose sequence to completion. Shared by the two
 * messages that are followed by a close of our own (bye, refuse). */
static void flush_and_close(void)
{
    unsigned long deadline;

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

static void send_bye_and_close(const char *code)
{
    char payload[64];
    long pos = 0;
    int ok = 1;

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

    flush_and_close();
}

/* Refuse the host's hello, then close - the same shape as the bye above,
 * for the one message that is not a bye.
 *
 * The contract's connection rules bind the revision gate to whoever
 * RECEIVES a hello, and say the refusal is SENT: a silent hang-up is
 * indistinguishable from a dropped network at the far end, which is the
 * one thing gating at the door exists to tell apart. `contract` here is
 * OURS - a peer that is merely stale learns from this message which
 * number to be. Best effort, like bye: a queue that will not take it
 * still ends in a close, because the alternative is serving a session we
 * have just decided we cannot speak. */
static void send_refuse_and_close(const char *reason)
{
    /* The envelope is ~40 bytes and handle_host_hello's reason buffer is
     * 80, so this holds the longest refusal that can reach it with room
     * to spare - and a longer one truncates into a shorter message
     * rather than overrunning, because numfmt is bounded. */
    char payload[160];
    long pos = 0;
    int ok = 1;

    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"refuse\",\"contract\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       (long)NOW68K_CONTRACT_REVISION);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"reason\":\"");
    /* Not escaped, and never given peer text: every caller passes a
     * literal built here, the same rule send_error_reply follows for the
     * same reason - this writer does not escape. */
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      reason);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "\"}");
    if (ok && pos > 0) {
        if (!enqueue_control_send(payload, pos)) {
            now68k_log("wire: refuse dropped, outbound queue full");
        }
    } else {
        now68k_log("wire: refuse payload build failed");
    }

    flush_and_close();
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

/* Continuity is deliberately absent on NOW-68K, but the control contract
 * still requires this family to answer in its own envelope. A generic error
 * would leave the host's arm waiter unresolved for five seconds and make an
 * unsupported machine look like a lossy one. */
static void handle_continuity_unsupported(const char *json, long len)
{
    char payload[160];
    long id = 0;
    long epoch = 0;
    long pos = 0;
    int ok = 1;

    (void)now68k_json_find_int(json, (size_t)len, "id", &id);
    (void)now68k_json_find_int(json, (size_t)len, "epoch", &epoch);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
        "{\"type\":\"continuity.report\",\"version\":4,\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload,
                                       &pos, id);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"epoch\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload,
                                       &pos, epoch);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
        ",\"state\":\"refused\",\"reason\":\"unsupported\"}");
    if (!ok || pos <= 0 || !enqueue_control_send(payload, pos)) {
        now68k_log("wire: continuity refusal dropped");
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
    int found = now68k_json_find_int(json, (size_t)len, "contract", &contract);

    if (!found || contract != NOW68K_CONTRACT_REVISION) {
        char reason[80];
        long pos = 0;
        long spos;
        int absent = !found;

        /* Terminated before the first append, the way status_begin() does
         * it: numfmt leaves *pos unspecified on a failure, and the
         * recovery below re-derives the position with strlen(), which on
         * an untouched buffer would be reading whatever the stack held. */
        reason[0] = '\0';

        /* The numbers, not just the fact. This used to read "contract
         * mismatch" and tear down with a bye, which told a person nothing
         * about WHICH revision the peer speaks and told the peer nothing
         * at all - and the contract now states both halves of that: the
         * reason names both numbers, and the refusal is sent rather than
         * being a silent hang-up. An ABSENT field lands here too and says
         * so, because the contract requires the field and there is then
         * no revision to compare. */
        now68k_log_num("wire: host hello has an unexpected contract "
                        "revision", contract);
        if (absent) {
            (void)now68k_fmt_append_str(reason, (long)sizeof reason, &pos,
                                         "host hello states no contract "
                                         "revision; this guest speaks ");
            (void)now68k_fmt_append_long(reason, (long)sizeof reason, &pos,
                                          (long)NOW68K_CONTRACT_REVISION);
        } else {
            (void)now68k_fmt_append_str(reason, (long)sizeof reason, &pos,
                                         "contract revision ");
            (void)now68k_fmt_append_long(reason, (long)sizeof reason, &pos,
                                          contract);
            (void)now68k_fmt_append_str(reason, (long)sizeof reason, &pos,
                                         " != ");
            (void)now68k_fmt_append_long(reason, (long)sizeof reason, &pos,
                                          (long)NOW68K_CONTRACT_REVISION);
        }
        if (pos < 0 || pos >= (long)sizeof reason) {
            pos = (long)strlen(reason);
        }
        reason[pos] = '\0';

        status_begin(&spos);
        status_append(&spos, "Protocol error: ");
        status_append(&spos, reason);
        status_end(spos);

        send_refuse_and_close(reason);
        /* No bye: the refusal IS the answer and the stream is already
         * closed above. This still routes through the one failure funnel
         * so the retry the contract asks of a guest gets scheduled. */
        teardown_and_retry(NULL, NULL);
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

    /* Three commands are implemented (help, launch, quit); everything else
     * still falls through to unknown-command below. The dispatcher writes
     * nothing unless it recognises the name, so the fallback can reuse this
     * buffer. */
    if (!read_string_field(json, (size_t)len, "name", name, sizeof name)) {
        name[0] = '\0';
    }
    /* The argument is args.target, NOT args itself: CommandRequest.args is an
     * OBJECT ({"target":"TeachText"}), so reading "args" as a string always
     * came back empty and every launch/quit answered bad-args. The scanner is
     * flat and first-occurrence-wins, which is safe here precisely because the
     * contract forbids an arg key from shadowing type/id/name/args/line -
     * "target" appears only inside the args object. */
    if (!read_string_field(json, (size_t)len, "target", args, sizeof args)) {
        /* No typed arg: a CONSOLE sent this, and a console sends the raw
         * line a human typed instead (CommandRequest.line) because it knows
         * no command's grammar. For every command this build serves the
         * argument is the whole rest of the line, so the line IS the target
         * and needs no reshaping here - the grammar inside it is parsed by
         * commands68.c, the side that serves the verb. */
        if (!read_string_field(json, (size_t)len, "line", args, sizeof args)) {
            args[0] = '\0';
        }
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

/* ---- exec.request: the console plane -----------------------------------
 *
 * The other half of the two-planes design (contract preamble, "Exec"). Where
 * handle_command_request above takes a NAME the host already split off and
 * answers with a declared output schema, this takes the whole LINE and
 * answers with the text this machine's own console window would have shown -
 * because it asks the same function that window asks (n68_exec.h).
 *
 * Nothing here knows a verb. That is the property being bought: a command
 * added to commands68.c is typeable from the host the moment it exists, with
 * no edit to this file, to the contract, or to the host binary.
 */

/* Raw text per exec.output frame, chosen from the escape blow-up rather
 * than from taste. A MacRoman high byte becomes \uXXXX - six bytes - so a
 * worst-case chunk is 6x its raw size, and the frame also carries ~55 bytes
 * of envelope. 150 * 6 + 55 = 955, comfortably inside
 * NOW68K_CONTROL_SEND_CAP with room for the envelope to grow a field. Most
 * text is ASCII and packs 1:1, so this is the floor of what fits, not the
 * size a frame usually is. */
enum { kExecChunkRaw = 150 };

/* How long an interpreter may wait for exec.input before giving up.
 *
 * BOUNDED ON PURPOSE. This guest is cooperatively scheduled on a machine
 * with no preemption to rescue it, so an unbounded wait here is a Mac that
 * needs a power cycle - the `sertx` failure with a different cause. 30
 * seconds is long enough for a person to read a prompt and type, short
 * enough that a forgotten prompt frees the machine while somebody is still
 * in the room. The wait PUMPS rather than blocks, so the guest stays
 * answerable throughout and exec.cancel can end it early. */
enum { kExecInputTicks = 60 * 30 };

typedef struct {
    int  active;
    long id;
    long seq;
    long len;
    int  failed;      /* an enqueue failed; stop building frames nobody gets */
    int  cancelled;
    int  waiting;     /* an interpreter is blocked on exec.input */
    int  have_input;
    char input[128];
    char raw[kExecChunkRaw + 1];
} ExecSink;

/* ONE exec at a time, and the state is a file static rather than a stack
 * local because exec.cancel and exec.input arrive on a LATER frame than the
 * request they answer - they have to find it. A second exec.request while
 * one runs is refused "exec-busy": the dispatch below is synchronous, so a
 * second could only run by re-entering it. */
static ExecSink g_exec;

static void exec_flush(ExecSink *s)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    long pos = 0;
    int ok = 1;

    if (s->len <= 0 || s->failed) {
        s->len = 0;
        return;
    }
    s->raw[s->len] = '\0';

    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     "{\"type\":\"exec.output\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                      s->id);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     ",\"seq\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                      s->seq);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     ",\"text\":\"");
    ok = ok && now68k_json_append_escaped(payload, (long)sizeof payload, &pos,
                                          s->raw);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     "\"}");
    s->len = 0;
    if (!ok || pos <= 0) {
        /* The chunk bound above makes this unreachable for text this guest
         * produces. Logged rather than asserted because the honest failure
         * is a gap in `seq` the host can see, not a dead guest. */
        now68k_log("wire: exec.output build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: exec.output dropped, outbound queue full");
        s->failed = 1;
        return;
    }
    s->seq++;

    /* DRAIN, or the queue eats the reply. Found on the q800 emulator
     * 2026-07-28, and it presented as `help` never coming back at all
     * while `frobnicate` answered instantly - the signature of "enough
     * output to fill the queue" rather than of anything wrong with exec.
     *
     * kWireOutQueueDepth is FOUR. `help` renders about ten lines, so the
     * frames past the fourth were dropped, and the one dropped last was
     * the terminal exec.result - so the host waited out its full 60s
     * watchdog for a message the guest had built correctly and thrown
     * away. Every other producer on this wire enqueues one or two frames
     * and returns to the event loop; exec is the first that emits an
     * unbounded number inside a single dispatch, so it is the first that
     * has to pay for its own drain.
     *
     * flush_outbound, NOT wire_idle: this pushes queued bytes toward
     * MacTCP and reads nothing, so it cannot re-enter the dispatch that
     * is currently on the stack. That distinction is the whole reason
     * this is safe to call from here - see the NULL pump argument in
     * handle_exec_request. */
    flush_outbound();
}

/* n68_exec.h's emitter: text plus the CR the console's own con_out appends,
 * chunked to what a frame can carry. A block longer than one chunk is split
 * across frames at no particular boundary, which is why ExecOutput's `text`
 * promises to be a chunk and not a line - the host reassembles. */
static void exec_emit(void *ctx, const char *text, long length)
{
    ExecSink *s = (ExecSink *)ctx;
    long i;

    if (s->failed || s->cancelled) {
        return;
    }
    for (i = 0; i < length; ++i) {
        if (s->len >= kExecChunkRaw) {
            exec_flush(s);
            if (s->failed) {
                return;
            }
        }
        s->raw[s->len++] = text[i];
    }
    if (s->len >= kExecChunkRaw) {
        exec_flush(s);
        if (s->failed) {
            return;
        }
    }
    s->raw[s->len++] = '\r';
}

/* Terminal status, sent exactly once however the exec ended. Carries no
 * output by schema - the text left in exec.output frames, including when
 * there was only one. */
static void exec_finish(int ok, const char *code, const char *message)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    long pos = 0;
    int built = 1;

    exec_flush(&g_exec);

    built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                          &pos,
                                          "{\"type\":\"exec.result\",\"id\":");
    built = built && now68k_fmt_append_long(payload, (long)sizeof payload,
                                           &pos, g_exec.id);
    if (ok) {
        built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                              &pos, ",\"ok\":true}");
    } else {
        built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                              &pos, ",\"ok\":false,\"code\":\"");
        built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                              &pos, code);
        built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                              &pos, "\",\"message\":\"");
        built = built && now68k_json_append_escaped(payload,
                                                    (long)sizeof payload,
                                                    &pos, message);
        built = built && now68k_fmt_append_str(payload, (long)sizeof payload,
                                              &pos, "\"}");
    }
    g_exec.active = 0;
    g_exec.waiting = 0;
    g_exec.have_input = 0;
    if (!built || pos <= 0) {
        now68k_log("wire: exec.result build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: exec.result dropped, outbound queue full");
    }
}

static void handle_exec_request(const char *json, long len)
{
    /* A line is a human's typing, not a path or a name: kInputCap on this
     * guest's own console is 256, and a line the host could send but this
     * machine could not have typed would answer differently on the two
     * faces. Same number, for that reason. */
    char line[256];
    int served;
    long id = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (g_exec.active) {
        char payload[NOW68K_CONTROL_SEND_CAP];
        long pos = 0;
        int ok = 1;

        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                         "{\"type\":\"exec.result\",\"id\":");
        ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                          have_id ? id : 0);
        ok = ok && now68k_fmt_append_str(
                       payload, (long)sizeof payload, &pos,
                       ",\"ok\":false,\"code\":\"exec-busy\",\"message\":\""
                       "another command is already running on this Mac\"}");
        if (ok && pos > 0 && !enqueue_control_send(payload, pos)) {
            now68k_log("wire: exec.result dropped, outbound queue full");
        }
        return;
    }

    if (!read_string_field(json, (size_t)len, "line", line, sizeof line)) {
        line[0] = '\0';
    }

    g_exec.active = 1;
    g_exec.id = have_id ? id : 0;
    g_exec.seq = 0;
    g_exec.len = 0;
    g_exec.failed = 0;
    g_exec.cancelled = 0;
    g_exec.waiting = 0;
    g_exec.have_input = 0;

    /* NULL pump: this IS the wire, and pumping from inside its own dispatch
     * would re-enter the read path with a half-served request on the stack.
     * The console window passes wire_idle instead - see N68ExecPump. An
     * interpreter that genuinely needs the wire to keep turning asks for it
     * explicitly through now68k_exec_read_input, which pumps under the
     * exec-busy guard above. */
    served = now68k_exec_line(line, exec_emit, &g_exec, NULL);

    if (g_exec.cancelled) {
        exec_finish(0, "cancelled", "stopped at the host's request");
    } else if (!served) {
        /* The human already read "! unknown-command: <verb>" in the output;
         * this is the same fact in the form a TOOL can branch on. Both come
         * from one return value, so they cannot disagree. */
        exec_finish(0, "unknown-command", "this Mac serves no such command");
    } else {
        exec_finish(1, (const char *)0, (const char *)0);
    }
}

/* ALWAYS answered, even for an exec this Mac no longer has - the rule
 * stream.stop was hardened into, inherited rather than rediscovered. An
 * unanswered cancel is a host waiting on a reply that never comes.
 *
 * Marked, not acted on: the dispatch is synchronous, so this stops further
 * output at once and handle_exec_request sends the one terminal result when
 * the command returns. Exactly one exec.result goes out however the race
 * falls. A cancel can only ARRIVE mid-command while something pumps, so a
 * command that runs straight through finishes first and the cancel finds
 * nothing running - which is answered "not-running", and is true. */
static void handle_exec_cancel(const char *json, long len)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    long pos = 0;
    int ok = 1;
    long id = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (g_exec.active && have_id && g_exec.id == id) {
        g_exec.cancelled = 1;
        g_exec.waiting = 0;      /* breaks a bounded input wait at once */
        return;
    }
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     "{\"type\":\"exec.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                      have_id ? id : 0);
    ok = ok && now68k_fmt_append_str(
                   payload, (long)sizeof payload, &pos,
                   ",\"ok\":false,\"code\":\"not-running\",\"message\":\""
                   "nothing by that id is running on this Mac\"}");
    if (!ok || pos <= 0) {
        now68k_log("wire: exec.result build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: exec.result dropped, outbound queue full");
    }
}

/* Input for an exec that is not asking is DROPPED, not buffered: a line
 * typed at a prompt that has already gone would otherwise be answered into
 * the NEXT prompt, which is how a console runs something nobody meant. */
static void handle_exec_input(const char *json, long len)
{
    long id = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (!g_exec.active || !g_exec.waiting || !have_id || g_exec.id != id) {
        return;
    }
    if (!read_string_field(json, (size_t)len, "text", g_exec.input,
                           sizeof g_exec.input)) {
        g_exec.input[0] = '\0';
    }
    g_exec.have_input = 1;
    g_exec.waiting = 0;
}

int now68k_exec_read_input(char *out, long cap, const char *prompt)
{
    unsigned long deadline;

    if (out == (char *)0 || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    /* Only an exec can be asked for input. A person at this Mac's own
     * console window is never prompted, because they would have no way to
     * answer - so there is never a prompt on screen nobody can reach. */
    if (!g_exec.active || g_exec.cancelled) {
        return 0;
    }
    if (prompt != (const char *)0 && prompt[0] != '\0') {
        exec_emit(&g_exec, prompt, (long)strlen(prompt));
    }
    exec_flush(&g_exec);     /* the prompt must LEAVE before we wait on it */

    g_exec.waiting = 1;
    g_exec.have_input = 0;
    deadline = (unsigned long)TickCount() + (unsigned long)kExecInputTicks;

    while (g_exec.waiting && !g_exec.cancelled) {
        wire_idle();
        if ((unsigned long)TickCount() > deadline) {
            /* The bounded end of a bounded wait. An interpreter gets 0 and
             * must cope; it must never be handed a line that never came. */
            g_exec.waiting = 0;
            return 0;
        }
    }
    if (g_exec.cancelled || !g_exec.have_input) {
        return 0;
    }
    {
        long i = 0;

        while (i < cap - 1 && g_exec.input[i] != '\0') {
            out[i] = g_exec.input[i];
            ++i;
        }
        out[i] = '\0';
    }
    g_exec.have_input = 0;
    return 1;
}

/* The page one census.request is cut from. Static rather than a local for
 * exactly g_proc_rows' reason one message family over: it is ~1.1 KB, and
 * this function is reachable from inside the frame reader's callback chain
 * with a pumped dispatch potentially underneath it. One instance is also
 * the right number - a census.request is answered whole before the next
 * frame is read, and nothing keeps a pointer into it. */
static N68CensusPage g_census_page;

static void handle_census_request(const char *json, long len)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    char probe[kN68CensusProbeCap];
    long pos = 0;
    long id = 0;
    long cursor = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    if (!read_string_field(json, (size_t)len, "probe", probe,
                            sizeof probe)) {
        probe[0] = '\0';
    }
    sanitize_json_string(probe);
    if (!now68k_json_find_int(json, (size_t)len, "cursor", &cursor)) {
        cursor = 0;             /* absent means start over, per the schema */
    }

    if (now68k_census_gather(probe, cursor, &g_census_page)) {
        pos = n68_census_report_json(probe[0] != '\0' ? probe : "overview",
                                     have_id ? id : 0, &g_census_page,
                                     payload, (long)sizeof payload);
    } else {
        /* A name that is not in the registry. "refused" with a note, never
         * a protocol error (CensusRequest.probe: "that is what keeps the
         * registry additive") and never "absent" - absent would say the
         * machine was asked and said no, which is not what happened. This
         * is now the ONLY census answer that is refused for not knowing
         * the name; the fourteen the contract declares are all answered by
         * census68.c, several of them absent, which is a different and
         * truer thing. */
        n68_census_page_init(&g_census_page, 0);
        n68_census_page_say(&g_census_page, kN68CensusRefused,
                            "no such probe on this Mac - see the contract's "
                            "x-census registry");
        pos = n68_census_report_json(probe, have_id ? id : 0, &g_census_page,
                                     payload, (long)sizeof payload);
    }
    if (pos <= 0) {
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

/* ---- file.list: this guest's share of the browse half ------------------
 *
 * The contract's hostBrowsesFiles, and the same symmetric rule the rest of
 * the family follows: whoever RECEIVES the request serves its OWN share.
 * NOW-68K's share is now68k_desktop_folder() - the one root all three
 * directions use (n68_fileenum.h says why a fourth would be a bug).
 *
 * Additive: FileList and FileListing were already in the contract, already
 * decoded by the host, and already served by the PowerPC guest. Nothing in
 * contract/asyncapi.yaml changed for this.
 *
 * Every judgement here belongs to n68_filelist.c and every disk call to
 * n68_fileenum.c. What is left in this file is the wire.
 */

/* file.refuse, for any request in the family that cannot be served.
 *
 * ONE builder, because the family now has two kinds of refusal - a folder
 * this guest will not list, and an offer it will not take (put_refuse,
 * below) - and a second copy of these bytes is how one of them eventually
 * stops matching the schema while the other still does. `code` and `reason`
 * are always this build's own literals, never a host string, so neither
 * needs escaping. */
static void send_file_refuse(long id, const char *code, const char *reason)
{
    char payload[224];
    long pos = 0;
    int ok = 1;

    now68k_log(reason);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"file.refuse\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos, id);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"code\":\"");
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos, code);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "\",\"reason\":\"");
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      reason);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "\"}");
    if (!ok || pos <= 0) {
        now68k_log("wire: file.refuse build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        /* The host is waiting on an answer to this request and will not
         * get one. Worth a line of its own: silence here looks exactly
         * like a wedged guest. */
        now68k_log("wire: file.refuse dropped, outbound queue full");
    }
}

/* The page one file.listing is cut from. Static rather than a local for the
 * reason g_proc_rows is: ~900 bytes underneath a handler that is reachable
 * from inside the frame reader's callback chain, on a machine where
 * MaxApplZone() leaves no slack between the stack and the heap. Rebuilt on
 * every request; single-threaded, one caller. */
static N68FileRow g_file_rows[NOW68K_FILELIST_MAX_ROWS];

static void handle_file_list(const char *json, long len)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    /* +2, not +1. find_string TRUNCATES to fit, so a buffer of exactly
     * cap+1 makes strlen() top out AT the cap and the over-long check
     * below can never fire - it would list the wrong folder rather than
     * refuse. The extra byte is what lets a 65-character path arrive as 65
     * characters and be seen. */
    char path[NOW68K_FILELIST_PATH_MAX + 2];
    char root[NOW68K_FILELIST_ROOT_MAX + 1];
    long id = 0;
    long cursor = 0;
    long count;
    long n;
    int more = 0;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    path[0] = '\0';
    /* A path longer than the buffer is TRUNCATED by find_string, which
     * would silently list a different folder - so the truncation is
     * detected rather than trusted. One byte of slack past the cap is
     * exactly what makes an over-long path visible here.
     *
     * Read with find_string, not a text decoder: this guest has none. A
     * host sending a UTF-8 path with an accented character therefore fails
     * to RESOLVE it and gets not-found, which is a truthful refusal - the
     * receive half has the same property (n68_putrx.c) and neither half
     * mis-names anything as a result. It is a real gap and it is in
     * docs/open-issues.md, not papered over here. */
    (void)now68k_json_find_string(json, (size_t)len, "path",
                                  path, (long)sizeof path);
    if (strlen(path) > NOW68K_FILELIST_PATH_MAX) {
        send_file_refuse(have_id ? id : 0,
                         n68_fileenum_code_word(kN68EnumBadPath),
                         n68_fileenum_code_reason(kN68EnumBadPath));
        return;
    }
    if (!now68k_json_find_int(json, (size_t)len, "cursor", &cursor)) {
        cursor = 1;   /* absent cursor means the first page */
    }
    if (cursor < 1) {
        cursor = 1;
    }

    count = n68_fileenum_page(path, cursor, g_file_rows,
                              (long)NOW68K_FILELIST_MAX_ROWS, &more);
    if (count < 0) {
        N68EnumCode rc = (N68EnumCode)(-count);

        send_file_refuse(have_id ? id : 0, n68_fileenum_code_word(rc),
                         n68_fileenum_code_reason(rc));
        return;
    }

    root[0] = '\0';
    if (path[0] == '\0') {
        n68_fileenum_root_name(root, (long)sizeof root);
    }
    n = n68_filelist_build(have_id ? id : 0, path, cursor, g_file_rows,
                           count, more, root[0] != '\0' ? root : NULL,
                           payload, (long)sizeof payload, NULL, NULL);
    if (n <= 0) {
        /* Unreachable at the shipping cap - the static asserts at the top
         * of this file are what make it so - but a host waiting on a
         * file.listing must never wait forever, so answer the refusal the
         * family already has a shape for. */
        now68k_log("wire: file.listing build failed");
        send_file_refuse(have_id ? id : 0,
                         n68_fileenum_code_word(kN68EnumIOError),
                         "the listing did not fit one frame");
        return;
    }
    if (!enqueue_control_send(payload, n)) {
        now68k_log("wire: file.listing dropped, outbound queue full");
    }
}

/* ---- software.list: this guest's share of the software family -----------
 *
 * The contract's hostBrowsesSoftware, and the same symmetric rule: whoever
 * RECEIVES the request serves its OWN installed software. Additive -
 * SoftwareList and SoftwareListing were already in the contract, already
 * decoded by the host, and already served by the PowerPC guest. Nothing in
 * contract/asyncapi.yaml changed for this.
 *
 * The family has NO refuse message, deliberately: the contract answers a
 * bad domain with a listing carrying `note` ("no such domain"), so every
 * outcome is a software.listing and a host waiting on one always gets one.
 * The two failures this guest can have - an unknown domain, and a machine
 * whose System Folder or startup volume it could not read - therefore both
 * arrive as an empty page with the reason in `note` rather than as silence.
 *
 * THIS HANDLER CAN BLOCK FOR SECONDS. Cursor 1 on the "apps" domain runs
 * the whole-volume sweep, which is the contract's own warning ("the asker's
 * watchdog must outlive it"). It pumps the wire between slices through
 * proc_yield_ticks, which means this handler is re-entrant in exactly the
 * way proc68.c's DEFECT 3 note describes - and is safe for the same reason,
 * because that one guard is shared rather than copied.
 *
 * Every judgement here belongs to n68_swlist.c and every disk call to
 * n68_swenum.c. What is left in this file is the wire.
 */

/* The page one software.listing is cut from. Static rather than a local for
 * the reason g_file_rows is - ~1.3 KB underneath a handler reachable from
 * inside the frame reader's callback chain - and more so here, because the
 * sweep this handler can start makes that chain deeper than any other. */
static N68SwRow g_sw_rows[NOW68K_SWLIST_MAX_ROWS];

static void send_software_listing(long id, const char *domain_word,
                                  long cursor, const N68SwRow *rows,
                                  long count, int more, const char *note)
{
    char payload[NOW68K_CONTROL_SEND_CAP];
    long n = n68_swlist_build(id, domain_word, cursor, rows, count, more,
                              note, payload, (long)sizeof payload,
                              NULL, NULL);

    if (n <= 0) {
        /* Unreachable at the shipping cap - the static assert at the top of
         * this file is what makes it so - but a host waiting on a
         * software.listing must never wait forever. An empty page with the
         * reason in `note` is the shape this family has for saying no. */
        now68k_log("wire: software.listing build failed");
        n = n68_swlist_build(id, domain_word, cursor, NULL, 0, 0,
                             n68_swenum_code_reason(kN68SwIOError),
                             payload, (long)sizeof payload, NULL, NULL);
        if (n <= 0) {
            return;
        }
    }
    if (!enqueue_control_send(payload, n)) {
        now68k_log("wire: software.listing dropped, outbound queue full");
    }
}

static void handle_software_list(const char *json, long len)
{
    /* A domain is one short word from a closed enum. Anything longer than
     * this buffer is by construction not one of the five, and find_string
     * truncating it cannot turn a non-domain into a domain. */
    char word[16];
    long id = 0;
    long cursor = 0;
    long count;
    int more = 0;
    int truncated = 0;
    const char *note = "";
    const char *domain_word;
    N68SwDomain d;
    int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

    word[0] = '\0';
    (void)now68k_json_find_string(json, (size_t)len, "domain",
                                  word, (long)sizeof word);
    d = n68_swlist_domain(word);
    if (!now68k_json_find_int(json, (size_t)len, "cursor", &cursor)) {
        cursor = 1;   /* absent cursor means the first page */
    }
    if (cursor < 1) {
        cursor = 1;
    }

    /* `domain` is REQUIRED by the schema, so an absent one is as much a
     * bad request as a misspelt one - and both get the same answer the
     * contract already defines rather than a second vocabulary. The echoed
     * word is this build's literal for a known domain and the empty string
     * for an unknown one: a host's own string never reaches the wire from
     * here, which is why nothing below has to trust the escaping. */
    if (d == kN68SwDomainNone || d == kN68SwDomainUnknown) {
        send_software_listing(have_id ? id : 0, "", cursor, NULL, 0, 0,
                              n68_swlist_note_unknown_domain());
        return;
    }
    domain_word = n68_swlist_domain_word(d);

    count = n68_swenum_page(d, cursor, g_sw_rows,
                            (long)NOW68K_SWLIST_MAX_ROWS, &more, &truncated,
                            &note);
    if (count < 0) {
        N68SwCode rc = (N68SwCode)(-count);

        send_software_listing(have_id ? id : 0, domain_word, cursor, NULL, 0,
                              0, n68_swenum_code_reason(rc));
        return;
    }
    /* `truncated` is already folded into `note` by the enumerator - the
     * inventory bound and the root-only fallback each have their own
     * sentence there. It stays in the signature because `sw`'s table
     * renders the two facts as separate rows and the wire has only one
     * field for them. */
    (void)truncated;
    send_software_listing(have_id ? id : 0, domain_word, cursor, g_sw_rows,
                          count, more, note);
}

/* ---- the drive verbs: process.quit and process.front --------------------
 *
 * The other half of the identity story process.listing's isSelf starts.
 * The `quit` and `front` COMMANDS name a process the way a person does,
 * by name; these name it the way a machine should, by the PSN read off a
 * listing. One implementation under both (proc68.c), two ways in - the
 * second face of the same capability rather than a second capability, and
 * the shape the PowerPC guest already answers (wire.c ::
 * serve_process_act), not a second model invented here.
 *
 * ok:true means the verb was APPLIED, per the contract, and no more than
 * that: for quit, the Apple Event was delivered (process.result has no
 * field that could carry "gone" versus "declined"); for front, the
 * switch was accepted (none that could carry "and it landed"). Neither
 * pretends to know. A caller that needs to know asks process.list again,
 * which is a different subsystem and so a real check - `front` on a
 * listing row is the answer for one, the row's absence for the other.
 *
 * NOTE this guest answers process.quit and process.front but not
 * process.shot: it has no capture at all (docs/contract-coverage.md), and
 * the gap is visible here - process.shot still falls through to
 * send_error_reply - rather than hidden behind a partial family. */
static void handle_process_drive(const char *json, long len, int quit)
{
    char payload[kWireOutPayloadCap];
    char detail[128];
    long id = 0;
    long psn_high = 0;
    long psn_low = 0;
    long pos = 0;
    int  have_id = now68k_json_find_int(json, (size_t)len, "id", &id);
    int  ok = 1;
    int  applied;

    /* Both halves are required by the contract. A missing one is a
     * malformed request, not a request to quit process zero - kNoProcess
     * is a real value and guessing at it is how a drive verb acts on
     * something nobody named. */
    if (!now68k_json_find_int(json, (size_t)len, "psnHigh", &psn_high)
        || !now68k_json_find_int(json, (size_t)len, "psnLow", &psn_low)) {
        now68k_log(quit ? "wire: process.quit without a PSN"
                        : "wire: process.front without a PSN");
        send_error_reply(have_id ? id : 0, have_id);
        return;
    }

    detail[0] = '\0';
    if (quit) {
        ProcOutcome outcome = proc_quit_psn((unsigned long)psn_high,
                                            (unsigned long)psn_low,
                                            detail, (long)sizeof detail);
        /* kProcSentUnconfirmed is proc_quit_psn's success: delivered,
         * deliberately unconfirmed (proc68.h). */
        applied = (outcome == kProcSentUnconfirmed);
    } else {
        ProcFrontOutcome front = proc_front_psn((unsigned long)psn_high,
                                                (unsigned long)psn_low,
                                                detail,
                                                (long)sizeof detail);
        /* proc_front_psn does not wait, so "accepted" IS its success -
         * see proc68.h. Everything else is a refusal with a reason. */
        applied = (front == kProcFrontUnconfirmed);
    }

    /* A drive verb changes the machine, and its reason lives nowhere else
     * once the reply is off the wire - the same argument the PowerPC
     * guest's serve_process_act makes for logging both outcomes. */
    now68k_log(detail[0] != '\0' ? detail : "wire: drive verb answered");

    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                     "{\"type\":\"process.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                      have_id ? id : 0);
    if (applied) {
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                         ",\"ok\":true}");
    } else {
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                         ",\"ok\":false,\"reason\":\"");
        /* detail is proc68.c's sentence: ASCII by construction, but it
         * carries a process NAME, and a name with a quote in it would
         * reopen the literal. Escaped like every other variable string
         * that reaches this wire. */
        ok = ok && now68k_json_append_escaped(payload, (long)sizeof payload,
                                              &pos, detail);
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                         "\"}");
    }
    if (!ok || pos <= 0) {
        now68k_log("wire: process.result build failed");
        send_error_reply(have_id ? id : 0, have_id);
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: process.result dropped, outbound queue full");
    }
}

/* ---- the file family: receiving a push --------------------------------
 *
 * The contract's hostPutsFiles sequence, and this guest's share of a
 * SYMMETRIC family: whoever receives a request serves its own share.
 * NOW-68K serves the receive direction only - it never offers a file of
 * its own and never lists a share - so the other half of file.* still
 * falls through to send_error_reply below, deliberately and visibly.
 *
 * Every judgement here belongs to n68_putrx.c and every disk call to
 * n68_putfile.c. What is left in this file is the wire: read a message,
 * hand it over, render the answer.
 */

/* file.progress. ADVISORY by contract - "dropped rather than queued when
 * the control queue is busy... a receiver must treat it as a floor that
 * may skip, never as a sequence" - so it yields to real traffic rather
 * than crowding out a pong or a file.done.
 *
 * It is also the SENDER'S CLOCK (docs/large-transfers.md), which is why
 * yielding is safe but silence is not: `received` is cumulative, so a
 * skipped report costs nothing because the next one carries everything
 * the skipped one would have. Dropping every report would deadlock the
 * sender; dropping some is free. */
static void put_report_progress(int force)
{
    char payload[96];
    long pos = 0;
    int ok = 1;

    if (!force && g_out_count >= kWireOutQueueDepth / 2) {
        return;                       /* real traffic first */
    }
    n68_putrx_noted_report(&g_putrx);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"file.progress\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       g_put_id);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"received\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       g_putrx.received);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos, "}");
    if (!ok || pos <= 0) {
        return;                       /* a lost report costs nothing */
    }
    (void)enqueue_control_send(payload, pos);
}

/* file.refuse: the offer was never accepted, so nothing was created and
 * there is nothing to clean up. */
static void put_refuse(long id, N68PutCode code)
{
    send_file_refuse(id, n68_putrx_code_word(code),
                     n68_putrx_code_reason(code));
}

/* file.done: the transfer is over, one way or the other. */
static void put_done(int okay, N68PutCode code)
{
    char payload[288];
    long pos = 0;
    int ok = 1;

    g_put_had_one = 1;
    g_put_last_ok = okay;
    g_put_last_bytes = g_putrx.received;
    memcpy(g_put_last_name, g_putrx.offer.name, sizeof g_put_last_name);
    g_put_last_name[sizeof g_put_last_name - 1] = '\0';
    if (okay) {
        g_put_last_code[0] = '\0';
    } else {
        long n = (long)strlen(n68_putrx_code_word(code));

        if (n > (long)sizeof g_put_last_code - 1) {
            n = (long)sizeof g_put_last_code - 1;
        }
        memcpy(g_put_last_code, n68_putrx_code_word(code), (size_t)n);
        g_put_last_code[n] = '\0';
    }

    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"file.done\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       g_put_id);
    if (okay) {
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          ",\"ok\":true,\"received\":");
        ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                           g_put_last_bytes);
        /* The guest's own CRC, so the host can check the file it now has
         * against the one it sent even when it chose not to send a
         * checksum of its own. */
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          ",\"crc32\":");
        ok = ok && now68k_fmt_append_u32(payload, (long)sizeof payload, &pos,
                                          g_putrx.crc);
        ok = ok && now68k_fmt_append_str(
                       payload, (long)sizeof payload, &pos,
                       ",\"finalization\":\"same-folder-rename\","
                       "\"cleanup\":\"temp-renamed\"");
        if (now68k_putfile_relaunch_required(&g_putfile)) {
            ok = ok && now68k_fmt_append_str(
                           payload, (long)sizeof payload, &pos,
                           ",\"relaunchRequired\":true");
        }
        ok = ok && now68k_fmt_append_str(
                       payload, (long)sizeof payload, &pos, "}");
    } else {
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          ",\"ok\":false,\"code\":\"");
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          n68_putrx_code_word(code));
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          "\",\"reason\":\"");
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          n68_putrx_code_reason(code));
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          "\",\"received\":");
        ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                           g_put_last_bytes);
        /* Always temp-discarded: this guest keeps no partials, because
         * it does not implement resume and a partial nothing can resume
         * from is debris. */
        ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                          ",\"cleanup\":\"temp-discarded\"}");
    }
    if (!ok || pos <= 0) {
        now68k_log("wire: file.done build failed");
        return;
    }
    if (!enqueue_control_send(payload, pos)) {
        now68k_log("wire: file.done dropped, outbound queue full");
    }
}

/* A failure that happened while bytes were streaming. n68_putrx has
 * already discarded the partial and gone inactive. */
static void put_finish_failed(N68PutCode code)
{
    now68k_log(n68_putrx_code_reason(code));
    put_done(0, code);
}

static void handle_file_offer(const char *json, long len)
{
    N68PutOffer offer;
    N68PutCode rc;
    char payload[224];
    long pos = 0;
    int ok = 1;

    if (!n68_putrx_parse_offer(json, len, &offer)) {
        /* No id, no name, or no size: there is nothing to address an
         * answer to, or nothing to answer about. The generic error reply
         * is the honest shape - a file.refuse would have to invent the
         * id it is refusing. */
        long id;
        int have_id = now68k_json_find_int(json, (size_t)len, "id", &id);

        now68k_log("wire: file.offer is missing a field it cannot be "
                    "answered without");
        send_error_reply(have_id ? id : 0, have_id);
        return;
    }

    rc = n68_putrx_offer(&g_putrx, &offer);
    if (rc != kN68PutOK) {
        put_refuse(offer.id, rc);
        return;
    }
    g_put_id = offer.id;
    g_put_transfer = 0;   /* file.begin has not named one yet */

    /* file.accept. No `have`: this guest does not implement resume, and
     * the contract reads an absent `have` as "start from the beginning"
     * (FileAccept) - so a receiver that never resumes is a
     * contract-legal receiver rather than a broken one.
     *
     * `staging` IS declared, because it is true and it is the thing a
     * host most wants to know about a receiver it is about to trust with
     * 4 MB: nothing appears under the final name before it is whole. */
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      "{\"type\":\"file.accept\",\"id\":");
    ok = ok && now68k_fmt_append_long(payload, (long)sizeof payload, &pos,
                                       offer.id);
    ok = ok && now68k_fmt_append_str(payload, (long)sizeof payload, &pos,
                                      ",\"staging\":\"same-folder-temp\"}");
    if (!ok || pos <= 0 || !enqueue_control_send(payload, pos)) {
        /* The host never learned we accepted, so it will never send the
         * bytes. Undo the acceptance rather than sit holding an open
         * staging file for a transfer that cannot happen. */
        now68k_log("wire: file.accept could not be sent, abandoning");
        n68_putrx_cancel(&g_putrx);
        return;
    }
    now68k_log(offer.name);
}

/* file.begin fixes where the stream starts. This guest always answered
 * `have` absent, so the only offset it can serve is 0 - and a sender
 * naming another one has to be refused rather than silently written at
 * the wrong place, which no checksum can repair, only detect. */
static void handle_file_begin(const char *json, long len)
{
    long offset = 0;
    long transfer = 0;

    if (!g_putrx.active) {
        return;
    }
    /* Remembered, not checked: this guest correlates bulk by "there is
     * one transfer and it is this one" and always has. It is kept
     * because file.cancel names a transfer and carries no id, so this
     * is the only thing that can tell a cancel for the push in flight
     * from a late one for a transfer that already ended. */
    if (now68k_json_find_int(json, (size_t)len, "transfer", &transfer)
        && transfer > 0 && transfer <= 0xFFFFL) {
        g_put_transfer = (unsigned short)transfer;
    }
    if (now68k_json_find_int(json, (size_t)len, "offset", &offset)
        && offset != 0) {
        now68k_log_num("wire: file.begin names an offset this guest never "
                        "offered to resume from", offset);
        n68_putrx_cancel(&g_putrx);
        put_done(0, kN68PutCorrupt);
    }
}

static void handle_file_end(const char *json, long len)
{
    unsigned long crc = 0;
    int has_crc;
    long sender_ok = 1;
    N68PutCode rc;

    if (!g_putrx.active) {
        return;
    }
    has_crc = now68k_json_find_u32(json, (size_t)len, "crc32", &crc);
    {
        const char *v = now68k_json_value(json, (size_t)len, "ok");

        sender_ok = (v == NULL || v >= json + len || *v == 't');
    }

    /* One last report before the confirmation, so the host's count
     * reaches the total rather than stopping wherever the step last
     * landed. Past the yield rule on purpose: it is one frame and it is
     * the one that closes the bar. */
    if (sender_ok && g_putrx.received > 0) {
        /* `force` rather than a temporary lie about g_out_count: the
         * queue depth is also what enqueue_control_send picks a free
         * slot by, so zeroing it here would have written this frame
         * over the one currently being flushed. */
        put_report_progress(1);
    }

    rc = n68_putrx_end(&g_putrx, (int)sender_ok, has_crc, crc);
    put_done(rc == kN68PutOK, rc);
}

/* ---- the file family's send half ---------------------------------------
 *
 * The state machine and every judgement in it are n68_puttx.c; this is
 * the part that has a wire and a clock. The rule for sharing the wire is
 * in n68_puttx.h and enforced in flush_outbound() above.
 */

/* Ends a transfer that cannot continue: tell the host, then let the
 * sender clean up. file.end ok:false is the contract's way of saying so
 * once file.begin has been announced - by then a refusal is no longer
 * available, because the transfer already exists on both sides. */
static void send_file_end(int ok, N68SendCode why)
{
    char payload[kWireOutPayloadCap];
    long ms = -1;
    long n;

    if (ok && g_send_start_tick != 0) {
        /* Ticks are 1/60 s. sendMs is advisory (the contract types it as
         * an integer with no stated precision), so the rounding is not
         * worth a divide-and-remainder here. */
        ms = (long)(((unsigned long)TickCount() - g_send_start_tick)
                    * 1000UL / 60UL);
    }
    if (g_send_is_capture) {
        /* capture.end, and then STRAIGHT TO IDLE. A file transfer waits
         * for the host's file.done - a put is not finished until the
         * receiver says so - but the contract gives a capture no such
         * receipt, so waiting for one would leave the lane occupied
         * forever after the first capture. */
        n = n68_shotwire_end_json(g_capture_id, g_capture_transfer, ok,
                                  payload, (long)sizeof payload);
        if (n <= 0 || !enqueue_control_send(payload, n)) {
            now68k_log("wire: capture.end could not be queued");
        }
        n68_puttx_done(&g_puttx, g_capture_id, ok, NULL);
        g_send_is_capture = 0;
        g_send_start_tick = 0;
        /* The staged bytes have now either been sent or been abandoned;
         * either way they are 65 KB of a 4 MB disk. */
        shotstage68_discard();
        if (!ok) {
            now68k_log_num("wire: capture failed", (long)why);
        }
        return;
    }
    n = n68_puttx_build_end(&g_puttx, payload, (long)sizeof payload, ok, ms);
    if (n > 0) {
        if (!enqueue_control_send(payload, n)) {
            now68k_log("wire: file.end could not be queued");
        }
    } else {
        now68k_log("wire: file.end did not fit its buffer");
    }
    if (!ok) {
        char line[96];
        long pos = 0;

        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    "wire: send failed - ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    n68_puttx_code_reason(why));
        line[pos] = '\0';
        now68k_log(line);
    }
    g_send_start_tick = 0;
}

/* One step of a transfer, once per wire_idle() pass. Deliberately not a
 * loop: the event loop that already runs is what advances this, so there
 * is no stretch of time in which the guest is deaf and nothing to pump
 * from inside. See n68_puttx.h, "Nothing here loops". */
static void service_send(void)
{
    N68SendCode why = kN68SendOK;
    long n;

    /* RULE 4: the previous chunk must be entirely away before another is
     * produced. net_queue_send's short accept is the whole flow control. */
    if (g_bulk_len > 0) {
        return;
    }
    /* RULE 3, from the producing end: do not build a bulk frame while a
     * control message is still waiting for the wire. Without this the
     * bulk slot would refill the instant it drained and a reply would
     * wait behind a chunk that had not needed to exist yet. */
    if (g_out_count > 0) {
        return;
    }

    if (n68_puttx_all_sent(&g_puttx)) {
        send_file_end(1, kN68SendOK);
        return;
    }

    n = n68_puttx_next_frame(&g_puttx, g_bulk, (long)sizeof g_bulk, &why);
    if (n > 0) {
        g_bulk_len = n;
        g_bulk_off = 0;
        return;
    }
    if (why != kN68SendOK) {
        /* The sender has already closed the source and gone idle; all
         * that is left is to tell the host the transfer is over. */
        send_file_end(0, why);
    }
}

/* The host granted the offer. Announce the transfer and start. */
static void handle_file_accept(const char *json, long len)
{
    char payload[kWireOutPayloadCap];
    long id;
    long n;

    if (!now68k_json_find_int(json, (size_t)len, "id", &id)) {
        return;
    }
    if (!n68_puttx_accepted(&g_puttx, id, g_send_next_transfer)) {
        return;   /* stale, or for a transfer that is already over */
    }
    ++g_send_next_transfer;
    if (g_send_next_transfer == 0) {
        g_send_next_transfer = 1;   /* 0 is reserved for control frames */
    }

    n = n68_puttx_build_begin(&g_puttx, payload, (long)sizeof payload);
    if (n <= 0 || !enqueue_control_send(payload, n)) {
        /* Nothing has been announced, so this ends as a cancellation
         * rather than a file.end for a transfer the host never saw. */
        now68k_log("wire: file.begin could not be sent");
        n68_puttx_cancel(&g_puttx, kN68SendGone);
        return;
    }
    g_send_start_tick = (unsigned long)TickCount();
}

static void handle_file_refuse(const char *json, long len)
{
    long id;

    if (!now68k_json_find_int(json, (size_t)len, "id", &id)
        || id != g_puttx.id) {
        return;
    }
    now68k_log("wire: the host refused the offer");
    n68_puttx_cancel(&g_puttx, kN68SendRefused);
    g_send_start_tick = 0;
}

/* The host's receipt. Only now is a put finished - a put is not done
 * until the far side's File Manager says so, which is the same rule this
 * guest applies in the other direction. */
static void handle_file_done(const char *json, long len)
{
    char code[24];
    long id;
    int ok;
    int have_code;
    const char *v;

    if (!now68k_json_find_int(json, (size_t)len, "id", &id)) {
        return;
    }
    /* A JSON boolean, so not find_int - the same idiom handle_file_end
     * uses on the receiving side. An ABSENT `ok` reads as false here,
     * where file.end's reads as true, and the difference is deliberate:
     * the contract requires the field in both, so either absence is a
     * malformed message, but only one of the two guesses can invent a
     * file that landed safely. */
    v = now68k_json_value(json, (size_t)len, "ok");
    ok = (v != NULL && v < json + len && *v == 't');
    have_code = now68k_json_find_string(json, (size_t)len, "code",
                                        code, (long)sizeof code);
    n68_puttx_done(&g_puttx, id, ok, have_code ? code : NULL);
    g_send_start_tick = 0;
}

/* file.cancel {transfer} - the peer has stopped wanting a transfer, in
 * whichever direction it was going.
 *
 * WHY THIS EXISTS AT ALL. There is no message for "I have lost
 * interest", so an abandoned transfer is indistinguishable from a slow
 * one, and neither half of this guest carries a timer: the only clock
 * anywhere near a transfer is service_live()'s 65 s no-traffic
 * watchdog, which is a property of the CONNECTION and never fires while
 * the guest's own keepalive ping is being answered. Before this handler
 * existed a cancel fell through to send_error_reply() - the guest
 * answered "not-implemented" and carried on holding a staging file, or
 * carried on streaming megabytes at a host that had already thrown them
 * away. The lane is one transfer wide in BOTH directions, so that
 * turned a host changing its mind into a guest that refused every
 * later transfer until it was relaunched. This is the only exit.
 *
 * DELIVERABILITY, which is the part worth checking rather than
 * assuming: a cancel is a control frame, and control frames are read
 * whole and dispatched between bulk frames (n68_reader.c), so this
 * handler runs at most one chunk - 4096 bytes, ~12 ms at the measured
 * link speed - after the cancel arrives, not at the end of the
 * transfer. That is n68_puttx.h rule 3 read from the receiving side,
 * and it is the case that rule exists for.
 *
 * MID-FRAME is the one thing a cancel may not do. A bulk frame whose
 * bytes have already begun going out finishes (rule 2) - the peer's
 * decoder is counting them, and a frame cut short is a desynchronised
 * wire, not a cancelled transfer. A frame merely STAGED has not been
 * seen by anyone and is dropped.
 *
 * TWO FACES, ONE IMPLEMENTATION. This is the body of both the wire's
 * file.cancel and the console's `cancel` verb (commands68.c), which is
 * the rule in docs/command-parity.md rather than a convenience: a
 * person at a PowerBook whose host has stopped answering is exactly
 * who needs to end a transfer, and the wire is exactly the face not
 * available to them then. `named` says whether the caller is naming a
 * particular transfer - the wire does, a person cannot and does not
 * need to. `what` takes a short phrase naming what was stopped, for
 * whoever is going to render it; NULL when nobody is. */
static int cancel_in_flight(int named, long transfer, char *what, long cap)
{
    int hit = 0;
    long pos = 0;

    if (what != NULL && cap > 0) {
        what[0] = '\0';
    }

    /* `transfer` is required by the contract, so its absence is a
     * malformed message rather than a shape to support. It is still
     * acted on: the lane is one transfer wide, so "the transfer" is
     * never ambiguous here, and refusing to cancel over a missing field
     * would leave the wedge this handler exists to prevent. The same
     * reasoning covers a transfer we hold no id for - a push whose
     * file.begin has not arrived yet. */
    if (g_putrx.active
        && (!named || g_put_transfer == 0
            || transfer == (long)g_put_transfer)) {
        now68k_log("wire: the file arriving was cancelled");
        if (what != NULL) {
            (void)now68k_fmt_append_str(what, cap, &pos, "stopped ");
            (void)now68k_fmt_append_str(what, cap, &pos,
                                        g_putrx.offer.name);
            (void)now68k_fmt_append_str(what, cap, &pos, " on its way in");
        }
        n68_putrx_cancel(&g_putrx);
        /* The staging file is already deleted by the cancel; this tells
         * the host so, with the contract's own word for it. A receiver
         * still owes a file.done - it is the only thing that closes a
         * put, and a host that cancelled still has a transfer open on
         * its side until it hears one. */
        put_done(0, kN68PutCancelled);
        hit = 1;
    }

    if (g_puttx.state != kN68SendIdle
        && (!named || g_puttx.state == kN68SendOffered
            || transfer == (long)g_puttx.transfer)) {
        now68k_log("wire: the file going out was cancelled");
        if (what != NULL) {
            /* Both directions can be live only if something has gone
             * wrong upstream, but if they are, both get named rather
             * than one silently winning the buffer. */
            if (pos > 0) {
                (void)now68k_fmt_append_str(what, cap, &pos, "; ");
            }
            (void)now68k_fmt_append_str(what, cap, &pos, "stopped ");
            (void)now68k_fmt_append_str(what, cap, &pos, g_puttx.name);
            (void)now68k_fmt_append_str(what, cap, &pos, " on its way out");
        }
        /* A staged chunk nobody has seen goes; one already part-way out
         * does not (rule 2 - flush_outbound finishes it). */
        if (g_bulk_off == 0) {
            g_bulk_len = 0;
        }
        /* file.end ok:false says the transfer is over in the sender's
         * own voice, which is what the PowerPC guest sends here too
         * (wire.c, xfer_abort -> xfer_finish(false)). It moves this
         * sender to kN68SendEnded, so the cancel that follows is not
         * belt-and-braces: a host that has given up sends no file.done
         * (GuestListener.swift, finishFile returns early for a transfer
         * it is discarding), and waiting for one is precisely the park
         * that wedged the lane. */
        send_file_end(0, kN68SendCancelled);
        n68_puttx_cancel(&g_puttx, kN68SendCancelled);
        g_send_start_tick = 0;
        hit = 1;
    }

    if (what != NULL && pos > 0 && pos < cap) {
        what[pos] = '\0';
    }
    return hit;
}

/* The wire's face on it. Nothing is answered on a miss: a cancel for a
 * transfer that has already ended is a message that arrived late, and
 * the contract gives file.cancel no reply of any kind - so an error
 * reply here would answer a message nobody is waiting on. */
static void handle_file_cancel(const char *json, long len)
{
    long transfer = 0;
    int named = now68k_json_find_int(json, (size_t)len, "transfer",
                                     &transfer);

    if (!cancel_in_flight(named, transfer, NULL, 0)) {
        now68k_log_num("wire: file.cancel names no transfer in flight",
                        transfer);
    }
}

/* The console's face on it, and the host console reaches the same verb
 * over command.request - see commands68.c :: run_cancel. A person
 * cannot name a transfer id and does not need to: the lane is one
 * transfer wide, so there is only ever one thing "cancel" can mean. */
int now68k_wire_cancel_transfer(char *what, long cap)
{
    return cancel_in_flight(0, 0, what, cap);
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
    /* Same rule as command.request above and for the same reason: this has a
     * contract-mandated reply shape (exec.result, always), so it must never
     * fall through to send_error_reply - a host waiting on exec.result is
     * not listening for an error envelope and would wait forever. */
    if (strcmp(type, "exec.request") == 0) {
        handle_exec_request(json, len);
        return;
    }
    if (strcmp(type, "exec.cancel") == 0) {
        handle_exec_cancel(json, len);
        return;
    }
    if (strcmp(type, "exec.input") == 0) {
        handle_exec_input(json, len);
        return;
    }
    if (strcmp(type, "census.request") == 0) {
        handle_census_request(json, len);
        return;
    }
    if (strcmp(type, "continuity.arm") == 0
            || strcmp(type, "continuity.disarm") == 0) {
        handle_continuity_unsupported(json, len);
        return;
    }
    if (strcmp(type, "capture.request") == 0) {
        handle_capture_request(json, len);
        return;
    }
    if (strcmp(type, "process.list") == 0) {
        handle_process_list(json, len);
        return;
    }
    if (strcmp(type, "process.quit") == 0) {
        handle_process_drive(json, len, 1);
        return;
    }
    if (strcmp(type, "process.front") == 0) {
        handle_process_drive(json, len, 0);
        return;
    }
    /* The file family: push, pull and now browse. file.get and the
     * mutations (file.move, file.trash, file.mkdir) still fall through to
     * send_error_reply below - this guest can be asked WHAT is there and
     * can move a file in either direction, but will not change the shape
     * of its own disk on request. That is the asymmetry left, and it is
     * visible here rather than hidden. */
    if (strcmp(type, "software.list") == 0) {
        handle_software_list(json, len);
        return;
    }
    if (strcmp(type, "file.list") == 0) {
        handle_file_list(json, len);
        return;
    }
    if (strcmp(type, "file.offer") == 0) {
        handle_file_offer(json, len);
        return;
    }
    if (strcmp(type, "file.begin") == 0) {
        handle_file_begin(json, len);
        return;
    }
    if (strcmp(type, "file.end") == 0) {
        handle_file_end(json, len);
        return;
    }
    /* The answers to an offer THIS side made. */
    if (strcmp(type, "file.accept") == 0) {
        handle_file_accept(json, len);
        return;
    }
    if (strcmp(type, "file.refuse") == 0) {
        handle_file_refuse(json, len);
        return;
    }
    if (strcmp(type, "file.done") == 0) {
        handle_file_done(json, len);
        return;
    }
    /* Either direction's, and the only message in the family that names
     * a transfer rather than an offer id. */
    if (strcmp(type, "file.cancel") == 0) {
        handle_file_cancel(json, len);
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
    char sysver[kNowIdentityVersionCap];
    /* A model name, not a path or a list: Gestalt 'mnam' returns a Str63
     * at most, and this file's table is shorter still. */
    char model[72];
    long n;

    /* Asked at hello time, every connection, rather than cached at
     * startup: a System upgrade or a machine rename between two dials is
     * exactly the change this field exists to notice. Three Gestalt reads
     * the census already performs; nothing new is asked of a 384 KB
     * partition. */
    now68k_system_version(sysver, (long)sizeof sysver);
    now68k_machine_model(model, (long)sizeof model);

    n = now68k_hello_build(payload, (long)sizeof payload,
                            NOW68K_CONTRACT_REVISION,
                            NOW68K_APP_VERSION,
                            sysver, now68k_machine_type(), model);

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
    /* After the drain, so a file.accept that arrived this pass starts its
     * transfer in the same pass rather than a whole idle sleep later; and
     * before the ping, so a live transfer's chunk is staged ahead of a
     * keepalive that is not due yet. */
    service_send();
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
    /* Before reset_read_state, which cancels through g_putrx: cancelling
     * an uninitialised receiver would call through a NULL ops table. */
    now68k_putfile_init(&g_putfile);
    n68_putrx_init(&g_putrx, g_put_batch, (long)sizeof g_put_batch,
                    now68k_putfile_ops(), &g_putfile);
    g_put_id = 0;
    g_put_transfer = 0;
    g_put_had_one = 0;
    g_put_last_name[0] = '\0';
    g_put_last_code[0] = '\0';
    g_put_last_bytes = 0;
    g_put_last_ok = 0;
    n68_puttx_init(&g_puttx);
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

/* ---- what the console asks about a transfer ---------------------------
 * The console's face on this capability. A message family is a
 * capability too (docs/command-parity.md), and this one has no command
 * table to reach it through - so the reader is here, and conwin.c
 * renders it. ONE implementation, two renderers: nothing below decides
 * anything, it only copies out what the receiver already knows. */
void now68k_wire_put_status(N68PutStatus *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    out->active = g_putrx.active;
    out->id = g_put_id;
    out->bytes = g_putrx.offer.bytes;
    out->received = g_putrx.received;
    out->chunks = g_putrx.chunks;
    out->writes = g_putrx.writes;
    out->crc = g_putrx.crc;
    if (g_putrx.active) {
        memcpy(out->name, g_putrx.offer.name, sizeof out->name);
        out->name[sizeof out->name - 1] = '\0';
    }
    out->had_one = g_put_had_one;
    out->last_ok = g_put_last_ok;
    out->last_bytes = g_put_last_bytes;
    memcpy(out->last_name, g_put_last_name, sizeof out->last_name);
    out->last_name[sizeof out->last_name - 1] = '\0';
    memcpy(out->last_code, g_put_last_code, sizeof out->last_code);
    out->last_code[sizeof out->last_code - 1] = '\0';
    out->last_error = now68k_putfile_last_error(&g_putfile);
}

void now68k_wire_put_where(char *out, long cap)
{
    now68k_putfile_where(out, cap);
}

int now68k_wire_send_file(const char *leaf, char *why, long why_cap)
{
    N68ByteSource src;
    N68SendCode rc;
    char name[kN68SendNameCap];
    char type[8];
    char creator[8];
    unsigned long modified = 0;
    char payload[kWireOutPayloadCap];
    long n;
    long pos = 0;

    if (why != NULL && why_cap > 0) {
        why[0] = '\0';
    }
    if (g_state != kWireLive) {
        (void)now68k_fmt_append_str(why, why_cap, &pos, "not connected");
        why[pos] = '\0';
        return 0;
    }
    /* Asked BEFORE the file is opened. One transfer at a time is the
     * contract's rule, and a refusal that has already opened a fork is a
     * fork that has to be closed on a path nobody tests. */
    if (g_puttx.state != kN68SendIdle) {
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    n68_puttx_code_reason(kN68SendBusy));
        why[pos] = '\0';
        return 0;
    }
    /* And a receive counts too: the lane is one transfer wide in both
     * directions, so a push arriving while one is going out would have
     * two streams sharing a bulk channel that correlates by transfer id
     * but multiplexes by nothing. */
    if (g_putrx.active) {
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "a file is arriving right now");
        why[pos] = '\0';
        return 0;
    }

    if (!now68k_filesrc_open(&g_filesrc, leaf, &src, name, (long)sizeof name,
                             type, creator, &modified)) {
        (void)now68k_fmt_append_str(why, why_cap, &pos, "cannot read ");
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    leaf != NULL ? leaf : "that");
        (void)now68k_fmt_append_str(why, why_cap, &pos, " (error ");
        (void)now68k_fmt_append_long(why, why_cap, &pos,
                                     (long)now68k_filesrc_last_error(
                                         &g_filesrc));
        (void)now68k_fmt_append_str(why, why_cap, &pos, ")");
        why[pos] = '\0';
        return 0;
    }

    rc = n68_puttx_begin(&g_puttx, g_send_next_id, name, &src, 0,
                         type, creator, modified);
    if (rc != kN68SendOK) {
        /* begin took nothing, so the fork this function opened is still
         * this function's to close - see n68_filesrc.h. */
        src.ops->close(src.ctx);
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    n68_puttx_code_reason(rc));
        why[pos] = '\0';
        return 0;
    }

    n = n68_puttx_build_offer(&g_puttx, payload, (long)sizeof payload);
    if (n <= 0 || !enqueue_control_send(payload, n)) {
        n68_puttx_cancel(&g_puttx, kN68SendGone);
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "the offer could not be sent");
        why[pos] = '\0';
        return 0;
    }
    ++g_send_next_id;
    return 1;
}

/* capture.request from the host. The contract's answer to a request it
 * cannot serve is capture.end ok:false for that id, NOT a protocol error
 * and not silence - the host is already waiting on this id, and an error
 * envelope answers a different waiter than the one that is blocked (the
 * same reasoning DEFECT 11 records for command.request). */
static void handle_capture_request(const char *json, long len)
{
    char why[128];
    char payload[kWireOutPayloadCap];
    long id = 0;
    long depth = 0;
    long n;

    if (!now68k_json_find_int(json, (size_t)len, "id", &id)) {
        return;                 /* nothing to answer to */
    }
    /* depth 0 means native. This guest's capture plane is its native 8-bit
     * framebuffer, so 0 and 8 are the two honest spellings it serves. */
    if (now68k_json_find_int(json, (size_t)len, "depth", &depth)
        && depth != 0 && depth != 8) {
        now68k_log_num("wire: capture refused, depth", depth);
        n = n68_shotwire_end_json(id, 0, 0, payload, (long)sizeof payload);
        if (n > 0) {
            (void)enqueue_control_send(payload, n);
        }
        return;
    }
    if (!now68k_wire_send_capture(id, why, (long)sizeof why)) {
        /* The sentence, not just the fact. A refusal whose reason is only
         * in a return value is a refusal nobody can diagnose from the
         * machine it happened on. */
        now68k_log(why[0] != '\0' ? why : "wire: capture.request refused");
        n = n68_shotwire_end_json(id, 0, 0, payload, (long)sizeof payload);
        if (n > 0) {
            (void)enqueue_control_send(payload, n);
        }
    }
}

/* Stage a capture and put it on the wire: the tx half of `screenshot`.
 *
 * Staged rather than streamed, and shotstage68.h carries the argument -
 * capture.begin must promise an exact byte count, a PackBits length is not
 * knowable without packing, and this machine cannot hold a packed frame to
 * measure one. Packing to a file makes the length a fact. The bytes then
 * go out through the file source that already exists, because the staged
 * file IS the bulk payload, byte for byte.
 *
 * No offer, no accept: this announces capture.begin immediately and starts
 * sending, which is the sequence the contract states for a capture. */
int now68k_wire_send_capture(long id, char *why, long why_cap)
{
    N68ByteSource src;
    ShotStage68 staged;
    N68SendCode rc;
    char name[kN68SendNameCap];
    char type[8];
    char creator[8];
    unsigned long modified = 0;
    char payload[kWireOutPayloadCap];
    long n;
    long pos = 0;

    if (why != NULL && why_cap > 0) {
        why[0] = '\0';
    }
    if (g_state != kWireLive) {
        (void)now68k_fmt_append_str(why, why_cap, &pos, "not connected");
        why[pos] = '\0';
        return 0;
    }
    if (g_puttx.state != kN68SendIdle) {
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    n68_puttx_code_reason(kN68SendBusy));
        why[pos] = '\0';
        return 0;
    }
    if (g_putrx.active) {
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "a file is arriving right now");
        why[pos] = '\0';
        return 0;
    }

    /* Staging first, and BEFORE anything is announced: it reads the whole
     * screen and can refuse (wrong depth, no disk), and a capture.begin
     * already on the wire could then only be withdrawn with a
     * capture.end ok:false the host has to unwind. */
    if (shotstage68_write(&staged, why, why_cap) != kShotStage68OK) {
        return 0;
    }
    g_capture_plan = staged.plan;
    g_capture_capture_ms = staged.capture_ms;
    g_capture_encode_ms = staged.encode_ms;

    if (!now68k_filesrc_open(&g_filesrc, staged.leaf, &src, name,
                             (long)sizeof name, type, creator, &modified)) {
        shotstage68_discard();
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "the staged capture could not be read");
        why[pos] = '\0';
        return 0;
    }
    if (src.total != staged.total) {
        /* The file source measured the fork; staging counted what it
         * wrote. If those disagree, capture.begin would promise a number
         * the stream cannot keep - which the receiver sizes its staging
         * from. Refuse rather than send a length nobody can honour. */
        src.ops->close(src.ctx);
        shotstage68_discard();
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "the staged capture changed size");
        why[pos] = '\0';
        return 0;
    }

    rc = n68_puttx_begin(&g_puttx, id, name, &src, 0, type, creator,
                         modified);
    if (rc != kN68SendOK) {
        src.ops->close(src.ctx);
        shotstage68_discard();
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    n68_puttx_code_reason(rc));
        why[pos] = '\0';
        return 0;
    }

    g_capture_id = id;
    g_capture_transfer = g_send_next_transfer;
    if (!n68_puttx_accepted(&g_puttx, id, g_capture_transfer)) {
        n68_puttx_cancel(&g_puttx, kN68SendGone);
        shotstage68_discard();
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "the capture could not be armed");
        why[pos] = '\0';
        return 0;
    }
    ++g_send_next_transfer;
    if (g_send_next_transfer == 0) {
        g_send_next_transfer = 1;
    }

    g_capture_plan.total = staged.total;
    n = n68_shotwire_begin_json(&g_capture_plan, id, g_capture_transfer,
                                g_capture_capture_ms, g_capture_encode_ms,
                                1 /* staged rows are PackBits */,
                                payload, (long)sizeof payload);
    if (n <= 0 || !enqueue_control_send(payload, n)) {
        n68_puttx_cancel(&g_puttx, kN68SendGone);
        shotstage68_discard();
        (void)now68k_fmt_append_str(why, why_cap, &pos,
                                    "capture.begin could not be sent");
        why[pos] = '\0';
        return 0;
    }
    g_send_is_capture = 1;
    g_send_start_tick = (unsigned long)TickCount();
    now68k_log_num("wire: capture armed, bytes", staged.total);
    return 1;
}

void now68k_wire_send_status(N68SendStatus *out)
{
    memset(out, 0, sizeof *out);
    out->active = (g_puttx.state != kN68SendIdle);
    out->offered = (g_puttx.state == kN68SendOffered);
    out->id = g_puttx.id;
    out->bytes = g_puttx.total;
    out->sent = g_puttx.sent;
    if (out->active) {
        memcpy(out->name, g_puttx.name, sizeof out->name);
    }
    out->had_one = g_puttx.had_one;
    out->last_ok = g_puttx.last_ok;
    out->last_bytes = g_puttx.last_bytes;
    memcpy(out->last_name, g_puttx.last_name, sizeof out->last_name);
    memcpy(out->last_code, g_puttx.last_code, sizeof out->last_code);
}
