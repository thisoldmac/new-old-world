#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Processes.h>

#include "capture.h"
#include "fileshare.h"
#include "commands.h"
#include "census.h"
#include "json.h"
#include "nowlog.h"
#include "pixels.h"
#include "contract.h"
#include "ot_carbon.h"
#include "peek_read.h"
#include "prefs.h"
#include "proc_actions.h"
#include "product_identity.h"
#include "software.h"

enum {
    kConnectTimeoutTicks = 60 * 10,   /* 10s to establish the socket */
    kHelloTimeoutTicks = 60 * 8,      /* 8s for the host's hello */
    kPingIntervalTicks = 60 * 30,     /* ping after 30s of silence */
    kDeadTicks = 60 * 65,             /* no traffic for 65s => dead */
    kBackoffMinTicks = 60 * 2,        /* 2s, doubling... */
    kBackoffMaxTicks = 60 * 30,       /* ...to 30s */
    kRetryFloorTicks = 60 * 1,        /* the contract's only cadence rule */
    /* Big enough for the largest legal control frame (the contract caps
       control JSON at 4096). Bulk is never buffered whole — see
       next_frame — because one bulk frame is larger than anything this
       machine should hold in RAM merely to frame it. */
    kRxBufferSize = 4608
};

typedef struct {
    ConnPhase phase;
    char host[64];
    unsigned short port;
    Boolean want_connection;          /* false => stay disconnected */

    EndpointRef ep;
    UInt32 address;
    InetAddress connect_address;      /* async OTConnect retains both */
    TCall connect_call;
    volatile OSStatus connect_result;
    volatile Boolean connect_done;
    Boolean connect_notifier_installed;

    unsigned char rx[kRxBufferSize];
    long rx_len;
    long discard_remaining;           /* bytes of a message too big to
                                         hold, being thrown away */
    long bulk_remaining;              /* payload left in the bulk frame
                                         being consumed; 0 when none */

    unsigned long phase_deadline;     /* connect/hello timeout */
    unsigned long last_rx_tick;       /* any inbound bytes */
    unsigned long next_ping_tick;
    long pings_sent;                  /* since last pong */
    long ping_id;
    unsigned long ping_sent_tick;
    long last_rtt_ms;

    unsigned long backoff_ticks;
    unsigned long backoff_until;

    unsigned short transfer_seq;
    long offer_seq;
    char peer_name[64];
    char peer_version[32];
    char status[128];
    char last_fail[128];
    unsigned long connected_tick;     /* when the hello completed */
} ConnState;

static ConnState g;
static OTNotifyUPP g_connect_notifier;

static void send_hello(void);
static void xfer_cleanup(void);
static void offer_cleanup(void);

/* Is the shared lane in use? One transfer at a time is the rule, and
   every path that starts one has to ask the same question — four
   hand-written copies of this list had already drifted apart. */
static Boolean wire_busy(void);

/* A file send outlives the transfer that carries it — it ends on the
   host's receipt — so the transfer machine has to be able to end one
   that dies on the wire. */
static void send_cleanup(void);
static void note_file(const char *line);
static Boolean send_offer(Boolean overwrite);
static Boolean send_owns_transfer(long id);
static void take_bulk_in(const unsigned char *bytes, long len);
static void put_drop(void);
static void stream_drop(void);
static void shot_drop(void);
static void note_shot(const char *line);

/* Only the connect operation runs asynchronously: on the physical
   PowerBook a synchronous OTConnect to an unreachable address blocks
   inside the call forever (the emulator forgives it - the launch
   freeze this exists to prevent lived only on metal). The notifier
   runs at deferred-task time, acknowledges the event, and publishes
   one small result; all protocol, logging and UI work stays in
   conn_service on the main loop. OT notifiers are C-convention - the
   UPP macro is the documented exception to routine descriptors. */
static pascal void connect_notifier(void *context, OTEventCode code,
                                    OTResult result, void *cookie)
{
    ConnState *state = (ConnState *)context;

    (void)cookie;
    if (state == NULL || state->ep == kOTInvalidEndpointRef
        || state->connect_done) {
        return;
    }
    if (code == T_CONNECT) {
        state->connect_result = gNowOT.rcvConnect(state->ep, NULL);
        state->connect_done = true;
    } else if (code == T_DISCONNECT) {
        gNowOT.rcvDisconnect(state->ep, NULL);
        state->connect_result = result != noErr ? result : kOTLookErr;
        state->connect_done = true;
    } else if (code == T_ORDREL) {
        gNowOT.rcvOrderlyDisconnect(state->ep);
        state->connect_result = result != noErr ? result : kOTLookErr;
        state->connect_done = true;
    }
}

/* --- helpers ------------------------------------------------------------ */

static int parse_ipv4(const char *text, UInt32 *out)
{
    unsigned long parts[4];
    int i;
    const char *p = text;
    char *end;

    for (i = 0; i < 4; ++i) {
        parts[i] = strtoul(p, &end, 10);
        if (end == p || parts[i] > 255) {
            return 0;
        }
        p = end;
        if (i < 3) {
            if (*p != '.') {
                return 0;
            }
            ++p;
        }
    }
    if (*p != '\0') {
        return 0;
    }
    *out = (UInt32)((parts[0] << 24) | (parts[1] << 16)
                    | (parts[2] << 8) | parts[3]);
    return 1;
}

/* --- control TX queue ---------------------------------------------------
   Control messages must be reliable even when the pipe is stuffed with
   bulk pixels. A streaming guest runs the send buffer at the brim, and a
   single unretried OTSnd of capture.end / stream.stopped / a heartbeat
   ping dies there of kOTFlowErr — which is exactly how the first live
   stream wedged: the guest gave up, told no one (the telling failed too),
   and the host waited forever. So control frames queue here and drain
   from the event loop, never interleaving into a partially-sent bulk
   frame. Bulk stays best-effort and unqueued; pixels are re-capturable,
   protocol words are not. */

enum { kCtlQueueSlots = 8 };

static struct {
    Ptr frames[kCtlQueueSlots];       /* whole wire frames: header+payload */
    long lens[kCtlQueueSlots];
    long sent;                        /* bytes of frames[head] on the wire */
    int head, count;
} g_ctlq;

static int service_ctl_tx(void);
static int bulk_frame_partially_sent(void);

static void ctlq_clear(void)
{
    while (g_ctlq.count > 0) {
        DisposePtr(g_ctlq.frames[g_ctlq.head]);
        g_ctlq.head = (g_ctlq.head + 1) % kCtlQueueSlots;
        --g_ctlq.count;
    }
    g_ctlq.sent = 0;
    g_ctlq.head = 0;
}

/* One contiguous send per frame: back-to-back small writes are dropped by
   real classic NICs (PB1400c Farallon TX burst drop). Returns 1 once the
   frame is QUEUED - transmission happens from service_ctl_tx. 0 means the
   message cannot be delivered on this connection (no endpoint, oversize,
   or a backlog so deep the pipe is effectively dead). */
static int send_control(const char *json)
{
    unsigned long length = (unsigned long)strlen(json);
    Ptr frame;
    int slot;

    if (g.ep == kOTInvalidEndpointRef || length > (unsigned long)kNowMaxControl) {
        return 0;
    }
    if (g_ctlq.count >= kCtlQueueSlots) {
        return 0;
    }
    frame = NewPtr((long)(kNowFrameHeaderBytes + length));
    if (frame == NULL) {
        return 0;
    }
    frame[0] = (char)kNowChannelControl;
    frame[1] = 0;
    frame[2] = 0;
    frame[3] = 0;
    frame[4] = (char)((length >> 24) & 0xFF);
    frame[5] = (char)((length >> 16) & 0xFF);
    frame[6] = (char)((length >> 8) & 0xFF);
    frame[7] = (char)(length & 0xFF);
    memcpy(frame + kNowFrameHeaderBytes, json, length);
    slot = (g_ctlq.head + g_ctlq.count) % kCtlQueueSlots;
    g_ctlq.frames[slot] = frame;
    g_ctlq.lens[slot] = (long)(kNowFrameHeaderBytes + length);
    ++g_ctlq.count;
    service_ctl_tx();                 /* opportunistic immediate drain */
    return 1;
}

static void close_endpoint(void)
{
    if (g.ep != kOTInvalidEndpointRef) {
        if (g.connect_notifier_installed) {
            gNowOT.removeNotifier(g.ep);
            g.connect_notifier_installed = false;
        }
        gNowOT.unbind(g.ep);
        gNowOT.closeProvider(g.ep);
        g.ep = kOTInvalidEndpointRef;
    }
    g.rx_len = 0;
    g.bulk_remaining = 0;
}

/* Move to backoff after a failure; status keeps the reason already set. */
static void enter_backoff(void)
{
    now_log(kLogWarn, "wire", "disconnected from %s:%u: %.60s",
            g.host, g.port, g.last_fail);
    xfer_cleanup();                   /* a dropped link cancels any transfer */
    offer_cleanup();
    stream_drop();                    /* no stopped message on a dead wire */
    shot_drop();                      /* no deferred capture across a drop */
    put_drop();                       /* no half-written file left behind */
    ctlq_clear();
    close_endpoint();
    if (!g.want_connection) {
        g.phase = kConnIdle;
        return;
    }
    {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        if (prefs.retry_secs > 0) {
            /* Fixed cadence from the Connection dialog: predictable
               reconnects beat adaptive politeness on a private LAN. */
            g.backoff_ticks = (unsigned long)prefs.retry_secs * 60;
        } else if (g.backoff_ticks == 0) {
            g.backoff_ticks = kBackoffMinTicks;
        } else {
            g.backoff_ticks *= 2;
            if (g.backoff_ticks > kBackoffMaxTicks) {
                g.backoff_ticks = kBackoffMaxTicks;
            }
        }
        /* The contract's one cadence obligation: >= 1s between dials, so a
           bad prefs record cannot make this a connect flood. Enforced here
           rather than trusted from the loader, because the loader's range
           check is about a plausible record and this is about the wire. */
        if (g.backoff_ticks < kRetryFloorTicks) {
            g.backoff_ticks = kRetryFloorTicks;
        }
    }
    g.backoff_until = TickCount() + g.backoff_ticks;
    g.phase = kConnBackoff;
}

static void fail(const char *reason)
{
    if (reason != NULL) {
        snprintf(g.status, sizeof g.status, "%s", reason);
        snprintf(g.last_fail, sizeof g.last_fail, "%.95s", reason);
    }
    enter_backoff();
}

static void fail_ot(const char *operation, OSStatus err)
{
    char reason[96];

    snprintf(reason, sizeof reason, "%s (OT %ld)", operation, (long)err);
    fail(reason);
}

/* --- connect ------------------------------------------------------------ */

/* Open Transport's default receive window is small enough that a sender
   can only keep about one segment in flight: measured on the PB1400c,
   inbound files arrived at ~1.4 KB every ~350 ms — one segment per
   delayed ACK — for a flat 4 KB/s no matter the file size, while the
   same wire carried 227 KB/s outbound. Asking for a window several
   segments wide is what lets the sender fill the pipe.

   Best-effort by design: an older stack that refuses the option still
   works, just slowly, and that is better than refusing to connect. */
/* Left at the stack's default. Negotiating it with OTOptionManagement
   wedged the guest: synchronous, the call waits for a completion that
   needs a notifier this app does not install, and the connect never
   returns; non-blocking, it returns without taking effect. Raising the
   window needs a notifier — or the option set in the endpoint's
   configuration at open time — and neither belongs in a fix made at
   speed. The rate stays slow and honest until then. */
/* Bytes readable at the last pass, and the high-water mark since the
   connection came up. -3 means never sampled (no OTCountDataBytes). */
static long g_rcv_window = -3;
static long g_rcv_peak = -3;
/* Passes of the event loop that reached conn_service since the last
   file receive began. A collapsed transfer with this climbing normally
   means the loop is healthy and the bytes are simply not arriving. */
static long g_service_passes = 0;

/* The connect completed (either path); the rest of the protocol is
   written synchronously, so the endpoint goes back to that mode with
   the notifier gone before the first hello leaves. */
static void finish_connect(void)
{
    if (g.connect_notifier_installed) {
        gNowOT.removeNotifier(g.ep);
        g.connect_notifier_installed = false;
    }
    if (gNowOT.setSynchronous(g.ep) != noErr) {
        fail("Could not finish connection");
        return;
    }
    g.phase = kConnHandshaking;
    g.phase_deadline = TickCount() + kHelloTimeoutTicks;
    send_hello();
}

static void start_connect(void)
{
    OSStatus err, open_err = -1;

    close_endpoint();
    g.rx_len = 0;
    g.bulk_remaining = 0;
    g.pings_sent = 0;

    if (!parse_ipv4(g.host, &g.address)) {
        fail("Enter a numeric address like 10.0.2.2");
        return;
    }
    err = now_ot_resolve();
    if (err != noErr) {
        snprintf(g.status, sizeof g.status,
                 "Networking needs CarbonLib 1.6");
        g.phase = kConnNeedsCarbonLib;
        return;
    }
    if (now_ot_ensure_inited() != noErr) {
        fail("Open Transport could not start");
        return;
    }
    if (g_connect_notifier == NULL) {
        g_connect_notifier = NewOTNotifyUPP(connect_notifier);
        if (g_connect_notifier == NULL) {
            fail("Not enough memory for networking");
            return;
        }
    }
    g.ep = gNowOT.openEndpoint(OTCreateConfiguration(kTCPName), 0, NULL,
                               &open_err, gNowOTContext);
    if (open_err != noErr || g.ep == kOTInvalidEndpointRef) {
        fail("Could not open a TCP endpoint");
        return;
    }
    err = gNowOT.installNotifier(g.ep, g_connect_notifier, &g);
    if (err != noErr) {
        fail("Could not install networking callback");
        return;
    }
    g.connect_notifier_installed = true;
    err = gNowOT.bind(g.ep, NULL, NULL);      /* local operation, still sync */
    if (err != noErr) {
        fail("Bind failed");
        return;
    }
    /* Asynchronous for the dial itself: on metal a synchronous OTConnect
       to an address that never answers blocks INSIDE the call, and the
       whole application wedges before its first update event. The
       emulator forgives the synchronous form, which is how it shipped
       that way once already. */
    err = gNowOT.setAsynchronous(g.ep);
    if (err != noErr) {
        fail("Could not make connection asynchronous");
        return;
    }
    err = gNowOT.setNonBlocking(g.ep);
    if (err != noErr) {
        fail("Could not make connection nonblocking");
        return;
    }

    memset(&g.connect_address, 0, sizeof g.connect_address);
    g.connect_address.fAddressType = AF_INET;
    g.connect_address.fPort = g.port;
    g.connect_address.fHost = g.address;
    memset(&g.connect_call, 0, sizeof g.connect_call);
    g.connect_call.addr.buf = (UInt8 *)&g.connect_address;
    g.connect_call.addr.len = sizeof g.connect_address;
    g.connect_result = kOTNoDataErr;
    g.connect_done = false;
    g.phase_deadline = TickCount() + kConnectTimeoutTicks;
    snprintf(g.status, sizeof g.status, "Connecting to %s:%u...",
             g.host, g.port);
    now_log(kLogInfo, "wire", "connecting to %s:%u", g.host, g.port);
    err = gNowOT.connect(g.ep, &g.connect_call, NULL);
    if (err == noErr) {
        /* An asynchronous endpoint normally returns kOTNoDataErr and
           later delivers T_CONNECT. A local provider may still finish
           immediately; no completion event is owed in that case. */
        finish_connect();
    } else if (err == kOTNoDataErr) {
        g.phase = kConnConnecting;
    } else {
        fail_ot("Connect failed", err);
    }
}

static void service_connecting(void)
{
    if (g.connect_done) {
        OSStatus result = g.connect_result;

        g.connect_done = false;
        if (g.connect_notifier_installed) {
            gNowOT.removeNotifier(g.ep);
            g.connect_notifier_installed = false;
        }
        if (result != noErr) {
            fail_ot("Connection refused", result);
            return;
        }
        finish_connect();
        return;
    }
    if (TickCount() > g.phase_deadline) {
        fail("No answer (10s)");
    }
}

static void send_hello(void)
{
    char json[512];
    char name[64];
    char esc[256];

    /* This machine's name, not the product's: the other side puts it on
       screen ("Connected: Quadra 950"), and the product name is the one
       answer every machine running NOW would give. */
    now_machine_name(name, sizeof name);
    now_json_escape(name, esc, sizeof esc);
    snprintf(json, sizeof json,
             "{\"type\":\"hello\",\"contract\":%d,\"side\":\"guest\","
             "\"version\":\"%s\",\"name\":\"%s\",\"os\":\"9\",\"chunk\":%d}",
             kNowContractRevision, PRODUCT_VERSION, esc,
             kNowDefaultChunk);
    if (!send_control(json)) {
        fail("Sending hello failed");
    }
}

/* --- receive ------------------------------------------------------------ */

/* Pulls available bytes into the rx buffer. Returns 0 on a fatal transport
   condition (disconnect), 1 otherwise. */
static int pump_rx(void)
{
    OTFlags flags = 0;
    OTResult got;

    /* Sampled BEFORE draining, so it is the backlog the guest was left
       holding since the previous pass — the number that separates "this
       machine cannot keep up" from "nothing is arriving". Both look the
       same from the far end of the wire, which is how three throughput
       theories died here. */
    if (gNowOT.countDataBytes != NULL && g.ep != kOTInvalidEndpointRef) {
        OTByteCount waiting = 0;

        if (gNowOT.countDataBytes(g.ep, &waiting) == noErr) {
            g_rcv_window = (long)waiting;
            if ((long)waiting > g_rcv_peak) {
                g_rcv_peak = (long)waiting;
            }
        }
    }
    for (;;) {
        if (g.rx_len >= kRxBufferSize) {
            /* Full is not broken. A bulk stream fills this buffer every
               pass by design; the caller drains it and reads again.
               Returning failure here tore the connection down the moment
               a file started arriving. */
            return 1;
        }
        got = gNowOT.rcv(g.ep, g.rx + g.rx_len,
                         (OTByteCount)(kRxBufferSize - g.rx_len), &flags);
        if (got > 0) {
            g.rx_len += got;
            g.last_rx_tick = TickCount();
        } else if (got == kOTNoDataErr) {
            return 1;
        } else if (got == kOTLookErr) {
            OTResult look = gNowOT.look(g.ep);
            if (look == T_DISCONNECT) {
                gNowOT.rcvDisconnect(g.ep, NULL);
                return 0;
            }
            if (look == T_ORDREL) {
                gNowOT.rcvOrderlyDisconnect(g.ep);
                return 0;
            }
            return 1;
        } else {
            return 0;
        }
    }
}

/* Extracts one complete control frame into payload_out; returns 1 if one was
   dequeued, 0 if the buffer holds no full frame yet, -1 on a malformed
   frame (fatal). */
static int next_frame(char *payload_out, long cap)
{
    unsigned long length;
    long total;
    unsigned char channel;

    /* A bulk frame already under way: hand over whatever has arrived and
       wait for the rest. Bulk is NEVER buffered whole. One frame is
       larger than this buffer, and demanding the whole thing deadlocks:
       the buffer fills, the guest stops reading, TCP closes the window,
       and the sender waits forever on a transfer that has no way to
       finish. */
    if (g.discard_remaining > 0) {
        long take = g.rx_len;

        if (take <= 0) {
            return 0;
        }
        if (take > g.discard_remaining) {
            take = g.discard_remaining;
        }
        memmove(g.rx, g.rx + take, g.rx_len - take);
        g.rx_len -= take;
        g.discard_remaining -= take;
        payload_out[0] = '\0';
        return 0;
    }

    if (g.bulk_remaining > 0) {
        long take = g.rx_len;

        if (take <= 0) {
            return 0;
        }
        if (take > g.bulk_remaining) {
            take = g.bulk_remaining;
        }
        take_bulk_in(g.rx, take);
        memmove(g.rx, g.rx + take, g.rx_len - take);
        g.rx_len -= take;
        g.bulk_remaining -= take;
        payload_out[0] = '\0';
        return 1;
    }

    if (g.rx_len < kNowFrameHeaderBytes) {
        return 0;
    }
    channel = g.rx[0];
    length = ((unsigned long)g.rx[4] << 24) | ((unsigned long)g.rx[5] << 16)
        | ((unsigned long)g.rx[6] << 8) | (unsigned long)g.rx[7];
    if (length > kNowMaxPayload) {
        return -1;
    }
    if (channel != kNowChannelControl) {
        /* Take the header now; the payload streams in above. */
        memmove(g.rx, g.rx + kNowFrameHeaderBytes,
                g.rx_len - kNowFrameHeaderBytes);
        g.rx_len -= kNowFrameHeaderBytes;
        g.bulk_remaining = (long)length;
        payload_out[0] = '\0';
        return 1;
    }
    if (length + 1 > (unsigned long)cap) {
        /* Bigger than we can hold. Skipping it costs one message;
           dropping the connection costs everything in flight and looks
           like a network fault instead of a message we could not read.
           The peer is told nothing: it asked something reasonable and
           our buffer is our problem. */
        memmove(g.rx, g.rx + kNowFrameHeaderBytes,
                g.rx_len - kNowFrameHeaderBytes);
        g.rx_len -= kNowFrameHeaderBytes;
        g.discard_remaining = (long)length;
        snprintf(g.status, sizeof g.status,
                 "Ignored a %lu-byte message (too big to read)", length);
        now_log(kLogWarn, "wire", "skipped a %lu-byte control frame: bigger "
                "than this buffer holds", length);
        payload_out[0] = '\0';
        return 0;
    }
    total = kNowFrameHeaderBytes + (long)length;
    if (g.rx_len < total) {
        return 0;
    }
    memcpy(payload_out, g.rx + kNowFrameHeaderBytes, length);
    payload_out[length] = '\0';
    memmove(g.rx, g.rx + total, g.rx_len - total);
    g.rx_len -= total;
    return 1;
}

static void on_hello(const char *reply)
{
    if (!now_json_find_string(reply, "name", g.peer_name, sizeof g.peer_name)) {
        g.peer_name[0] = '\0';
    }
    if (!now_json_find_string(reply, "version", g.peer_version,
                          sizeof g.peer_version)) {
        strcpy(g.peer_version, "?");
    }
    g.phase = kConnConnected;
    g.connected_tick = TickCount();
    g.backoff_ticks = 0;              /* success resets backoff */
    g.last_fail[0] = '\0';
    g.pings_sent = 0;
    g.next_ping_tick = TickCount() + kPingIntervalTicks;
    if (g.last_rtt_ms >= 0) {
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s) - %ld ms",
                 g.peer_name, g.peer_version, g.last_rtt_ms);
    } else {
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s)",
                 g.peer_name, g.peer_version);
    }
}

/* --- bulk transfer -----------------------------------------------------
   Streaming is INCREMENTAL, pumped from the event loop rather than a
   blocking loop, for three reasons learned the hard way: a non-blocking
   OT endpoint refuses bytes once its send buffer fills (kOTFlowErr) and
   must be retried; the guest has to stay responsive while ~100 KB goes
   out; and a transfer you can observe is a transfer you can cancel. */

enum {
    kXferSliceTicks = 3,              /* ~50 ms of sending per service call */
    kXferDeadlineTicks = 60 * 120     /* give up after 2 min without progress */
};

typedef enum {
    kFrameStandalone = 0,             /* one-shot capture: no frame field */
    kFrameKey,
    kFrameDelta,
    kFrameEmpty
} FrameKind;

typedef struct {
    short width, height, depth, row_bytes;
    long capture_ms;
    FrameKind kind;
    PixelRect rects[kPixelMaxRects];  /* image/field coordinates */
    short n_rects;
    short row_scale, row_phase;       /* field -> canvas row mapping */
} ShotMeta;

/* Live-stream bracket (stream.start .. stream.stopped). service_stream
   turns the guest into a frame pump: finish a frame, capture fresh, send —
   never queue. One frame in flight bounds both latency and memory, and a
   stale screen self-corrects. Its own small state so the capture step can
   later become incremental (banded CopyBits) without touching the rest. */
static struct {
    Boolean active;
    long id;
    short depth;
    Boolean pack;
    long chunk;
    short pace_ms;
    long min_interval_ticks;
    unsigned long next_frame_tick;
    long frames;
    long empty_run;                   /* consecutive nothing-changed frames */
    /* The capture pipeline: frame N+1 is captured in event-loop-pumped
       bands while frame N is still going out (banding is metal-measured
       free: 139-143 ms total for 1..16 bands, ~17 ms per band at 8). The
       capture is scheduled to COMPLETE as the send completes - minimizing
       both frame age and the shear span - using the previous frame's
       measured send and capture+encode times. */
    BandedCapture cap;
    Boolean cap_active;
    PixelBlob ready_blob;             /* encoded, waiting for the lane */
    ShotMeta ready_meta;
    Boolean ready;
    Boolean stopping;                 /* stop acked once the drain ends */
    /* Delta base: the previous frame's raw rows plus its palette. A
       keyframe is forced at start, on host refresh, on palette change,
       and when a majority of rows are dirty anyway. */
    Ptr prev;
    long prev_bytes;
    short prev_row_bytes, prev_height;
    unsigned char prev_palette[768];
    long prev_palette_bytes;
    Boolean force_key;
    /* Optional capture policies (panel toggles, read at stream start).
       Predictive: read only rows likely to have changed - last frame's
       dirty rows plus margin, plus a rotating sweep slice so an unwatched
       change is caught within kSweepFrames frames. Interlace: capture and
       send alternate fields via CopyBits' 2:1 decimation, halving both
       the VRAM read and the wire per frame. */
    Boolean predictive;
    Boolean interlace;
    short phase;                      /* next field's parity */
    long sweep_pos;                   /* canvas row where the sweep is */
    CaptureSpan dirty_hist[kPixelMaxRects];  /* canvas rows, last frame */
    short n_dirty_hist;
    short cap_scale, cap_phase;       /* of the capture in progress */
    Boolean cap_full;                 /* captured everything (keyframes) */
    unsigned long cap_start_tick;
    long est_send_ticks;
    long est_cap_ticks;               /* capture + encode, measured */
} g_stream;

enum { kStreamReqTimeoutTicks = 60 * 10 };

static struct {
    Boolean pending;                  /* asked the host to open a bracket */
    unsigned long deadline;
} g_streamreq;

typedef enum {
    kXferCapture = 0,                 /* ends with capture.end */
    kXferFile                         /* ends with file.end */
} XferKind;

static struct {
    Boolean active;
    Boolean pushed;                   /* guest-initiated: report to panel */
    Boolean aborting;                 /* drain to the frame boundary, then
                                         end ok:false - never mid-frame */
    Boolean file_stream;              /* bytes come from File Manager */
    XferKind kind;
    Handle data;                      /* capture bytes; ownership below */
    PixelBlob blob;
    FileStage file;
    long total, offset;
    long chunk;
    unsigned short xfer;
    long id;
    Ptr frame;                        /* one framed chunk: header + payload */
    long frame_len, frame_sent;
    unsigned long next_tick;          /* pacing gate */
    unsigned long deadline;
    unsigned long started;
    short pace_ms;
} g_xfer;

/* "Screenshot App" (process.shot): bring a process forward, let it come
   front and redraw, then capture just its front window and deliver that
   over the capture transport - the wire-driven twin of the Processes
   page's Front & Capture, cropped to the window rather than the screen.
   Two-step, like that page: front now, capture from a later service pass,
   so nothing nests an event loop while the target repaints. */
static struct {
    Boolean active;
    ProcessSerialNumber target;
    ProcessSerialNumber self;         /* NOW, to restore once captured */
    long id;
    short depth;
    long chunk;
    short pace_ms;
    Boolean pack;
    unsigned long deadline;
} g_shot;

static int bulk_frame_partially_sent(void)
{
    return g_xfer.active && g_xfer.frame_sent > 0
        && g_xfer.frame_sent < g_xfer.frame_len;
}

/* Drains queued control frames. 1 = ok (possibly still pending on flow
   control), 0 = the endpoint is dead. */
static int service_ctl_tx(void)
{
    while (g_ctlq.count > 0) {
        Ptr frame = g_ctlq.frames[g_ctlq.head];
        long len = g_ctlq.lens[g_ctlq.head];
        OTResult sent;

        if (bulk_frame_partially_sent()) {
            return 1;                 /* finish that frame's bytes first */
        }
        sent = gNowOT.snd(g.ep, frame + g_ctlq.sent,
                          (OTByteCount)(len - g_ctlq.sent), 0);
        if (sent > 0) {
            g_ctlq.sent += sent;
            if (g_ctlq.sent >= len) {
                DisposePtr(frame);
                g_ctlq.head = (g_ctlq.head + 1) % kCtlQueueSlots;
                --g_ctlq.count;
                g_ctlq.sent = 0;
            }
        } else if (sent == kOTFlowErr || sent == kOTNoDataErr) {
            return 1;
        } else {
            return 0;
        }
    }
    return 1;
}

static void xfer_cleanup(void)
{
    if (g_xfer.frame != NULL) {
        DisposePtr(g_xfer.frame);
        g_xfer.frame = NULL;
    }
    if (g_xfer.data != NULL) {
        HUnlock(g_xfer.data);
    }
    if (g_xfer.file_stream) {
        now_files_stage_dispose(&g_xfer.file);
    } else if (g_xfer.blob.data != NULL) {
        now_pixels_dispose(&g_xfer.blob);
    } else if (g_xfer.data != NULL) {
        DisposeHandle(g_xfer.data);
    }
    g_xfer.data = NULL;
    g_xfer.active = false;
}

static void xfer_finish(Boolean ok)
{
    char json[256];

    if (ok && g_xfer.file_stream
        && !now_files_stage_unchanged(&g_xfer.file)) {
        ok = false;
    }
    if (ok && g_xfer.kind == kXferFile && g_xfer.file_stream) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":true,\"sendMs\":%ld,\"crc32\":%lu}",
                 g_xfer.id, g_xfer.xfer,
                 (long)((TickCount() - g_xfer.started) * 1000 / 60),
                 g_xfer.file.crc & 0xFFFFFFFFUL);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"%s.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":%s,\"sendMs\":%ld}",
                 g_xfer.kind == kXferFile ? "file" : "capture",
                 g_xfer.id, g_xfer.xfer, ok ? "true" : "false",
                 (long)((TickCount() - g_xfer.started) * 1000 / 60));
    }
    send_control(json);
    if (ok && g_stream.active && g_xfer.id == g_stream.id) {
        g_stream.est_send_ticks = (long)(TickCount() - g_xfer.started);
    }
    if (g_xfer.pushed) {
        if (ok) {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(json, sizeof json, "Sent to %s (%ld ms)", peer,
                         (long)((TickCount() - g_xfer.started) * 1000 / 60));
            }
            note_shot(json);
        } else {
            {
                char peer[40];
                char failed[96];

                conn_peer_label(peer, sizeof peer);
                snprintf(failed, sizeof failed, "Could not send to %s", peer);
                note_shot(failed);
            }
        }
    }
    /* A send that dies on the wire never gets a receipt, so this is the
       only place that can end it. Success stays quiet: the host has not
       written the file yet, and saying "sent" before it lands is the
       lie this whole path exists to avoid. */
    if (!ok && g_xfer.kind == kXferFile && send_owns_transfer(g_xfer.id)) {
        char peer[40];
        char failed[96];

        send_cleanup();
        conn_peer_label(peer, sizeof peer);
        snprintf(failed, sizeof failed, "Could not finish sending to %s",
                 peer);
        note_file(failed);
    }
    xfer_cleanup();
}

static int xfer_build_frame(void)
{
    long n = g_xfer.total - g_xfer.offset;
    long got = 0;
    Boolean last;

    if (n > g_xfer.chunk) {
        n = g_xfer.chunk;
    }
    last = (g_xfer.offset + n >= g_xfer.total);
    g_xfer.frame[0] = (char)kNowChannelBulk;
    g_xfer.frame[1] = (char)(last ? kNowFlagEnd : 0);
    g_xfer.frame[2] = (char)((g_xfer.xfer >> 8) & 0xFF);
    g_xfer.frame[3] = (char)(g_xfer.xfer & 0xFF);
    g_xfer.frame[4] = (char)((n >> 24) & 0xFF);
    g_xfer.frame[5] = (char)((n >> 16) & 0xFF);
    g_xfer.frame[6] = (char)((n >> 8) & 0xFF);
    g_xfer.frame[7] = (char)(n & 0xFF);
    if (g_xfer.file_stream) {
        if (now_files_stage_read(
                &g_xfer.file, g_xfer.frame + kNowFrameHeaderBytes,
                n, &got) != kFilesOK || got != n) {
            return 0;
        }
    } else {
        memcpy(g_xfer.frame + kNowFrameHeaderBytes,
               *g_xfer.data + g_xfer.offset, (size_t)n);
    }
    g_xfer.frame_len = kNowFrameHeaderBytes + n;
    g_xfer.frame_sent = 0;
    return 1;
}

/* Pumps the active transfer for a short slice. Partial sends and flow
   control simply resume on the next call. */
static void service_transfer(void)
{
    unsigned long slice_end = TickCount() + kXferSliceTicks;

    if (!g_xfer.active) {
        return;
    }
    if (TickCount() > g_xfer.deadline) {
        xfer_finish(false);
        return;
    }
    while (g_xfer.active && TickCount() <= slice_end) {
        OTResult sent;

        if (!g_xfer.aborting && TickCount() < g_xfer.next_tick) {
            return;                   /* paced: resume later */
        }
        if (g_xfer.frame_sent >= g_xfer.frame_len) {
            if (g_xfer.aborting) {
                xfer_finish(false);   /* boundary reached: end cleanly */
                return;
            }
            if (g_ctlq.count > 0) {
                return;               /* control goes first between frames */
            }
            g_xfer.offset += g_xfer.frame_len - kNowFrameHeaderBytes;
            if (g_xfer.offset >= g_xfer.total) {
                xfer_finish(true);
                return;
            }
            if (!xfer_build_frame()) {
                xfer_finish(false);
                return;
            }
            if (g_xfer.pace_ms > 0) {
                g_xfer.next_tick = TickCount()
                    + (unsigned long)g_xfer.pace_ms * 60 / 1000 + 1;
            }
        }
        sent = gNowOT.snd(g.ep, g_xfer.frame + g_xfer.frame_sent,
                          (OTByteCount)(g_xfer.frame_len - g_xfer.frame_sent),
                          0);
        if (sent > 0) {
            g_xfer.frame_sent += sent;
            /* This is an inactivity deadline, not a size ceiling. A
               healthy transfer larger than ~27 MB takes over two
               minutes on the measured link and must keep going. */
            g_xfer.deadline = TickCount() + kXferDeadlineTicks;
        } else if (sent == kOTFlowErr || sent == kOTNoDataErr) {
            return;                   /* buffer full: retry next pass */
        } else {
            xfer_finish(false);
            return;
        }
    }
}

/* Aborting mid-frame would corrupt the wire: the peer's decoder still
   expects the rest of the frame's bytes and would eat the next control
   message as bulk payload (the 4-bit stop bug - desync, protocol error,
   reconnect). So an abort drains to the frame boundary first; the
   remainder is at most one chunk, ~120 ms at wire speed. */
static void xfer_abort(void)
{
    if (!g_xfer.active) {
        return;
    }
    if (bulk_frame_partially_sent()) {
        g_xfer.aborting = true;
        return;
    }
    xfer_finish(false);
}

/* Panel hook: one status line about push transfers ("Sent to host"). */
static ConnShotNote g_shot_note;
static ConnFileNote g_file_note;

void conn_set_shot_note(ConnShotNote fn)
{
    g_shot_note = fn;
}

static void note_shot(const char *line)
{
    if (g_shot_note != NULL) {
        g_shot_note(line);
    }
}

void conn_set_file_note(ConnFileNote fn)
{
    g_file_note = fn;
}

/* A file's progress belongs in the window the human sent it from. */
static void note_file(const char *line)
{
    if (g_file_note != NULL) {
        g_file_note(line);
    }
}

/* JSON true/false with a fallback for an absent key. */
static int json_find_flag(const char *json, const char *key, int fallback)
{
    const char *v = now_json_value(json, key);

    if (v == NULL) {
        return fallback;
    }
    return *v == 't';
}

/* The initiator's knobs override the panel's; absent fields keep prefs. */
static void tuning_from_json(const char *json, const NowPrefs *prefs,
                             long *chunk, short *pace_ms, Boolean *pack)
{
    long v;

    v = now_json_find_int(json, "chunkKb", prefs->chunk_kb);
    if (v < 1 || v > 32) {
        v = prefs->chunk_kb;
    }
    *chunk = v * 1024;
    if (*chunk < 1024 || *chunk > kNowMaxPayload) {
        *chunk = 8192;
    }
    v = now_json_find_int(json, "paceMs", prefs->pace_ms);
    if (v < 0 || v > 100) {
        v = prefs->pace_ms;
    }
    *pace_ms = (short)v;
    *pack = json_find_flag(json, "pack", prefs->shot_pack) != 0;
}

static unsigned short next_xfer(void)
{
    ++g.transfer_seq;
    if (g.transfer_seq == 0) {
        g.transfer_seq = 1;
    }
    return g.transfer_seq;
}

/* Fills the meta and exports the wire pixels from an already-captured
   image, disposing it either way. Shared by the full-screen and
   window-cropped gatherers. */
static int export_shot(CaptureImage *image, short depth, Boolean pack,
                       unsigned long t_start, PixelBlob *blob, ShotMeta *meta)
{
    memset(meta, 0, sizeof *meta);    /* kind = kFrameStandalone */
    meta->capture_ms = (long)((TickCount() - t_start) * 1000 / 60);
    meta->width = (short)(image->bounds.right - image->bounds.left);
    meta->height = (short)(image->bounds.bottom - image->bounds.top);
    meta->depth = depth;
    meta->row_bytes = image->row_bytes;
    if (now_pixels_export(image, pack, blob) != 0) {
        capture_image_dispose(image);
        return 0;
    }
    capture_image_dispose(image);
    return 1;
}

/* Captures the screen and exports the wire pixels. On success the blob is
   the caller's to dispose. */
static int gather_shot(short depth, Boolean pack, PixelBlob *blob,
                       ShotMeta *meta)
{
    CaptureImage image;
    unsigned long t_start = TickCount();

    if (capture_screen(depth, &image) != kCaptureOK) {
        return 0;
    }
    return export_shot(&image, depth, pack, t_start, blob, meta);
}

/* As gather_shot, but captures a single screen rectangle - the anchor
   plane's payoff, used to crop "Screenshot App" to a process's window. */
static int gather_shot_rect(short depth, const Rect *rect, Boolean pack,
                            PixelBlob *blob, ShotMeta *meta)
{
    CaptureImage image;
    unsigned long t_start = TickCount();

    if (capture_screen_rect(depth, rect, &image) != kCaptureOK) {
        return 0;
    }
    return export_shot(&image, depth, pack, t_start, blob, meta);
}

/* Announces capture.begin and arms the incremental sender. Takes ownership
   of the blob either way; on failure the host gets capture.end ok:false so
   it never waits on a transfer that will not come. */
/* Appends the frame/rects fields for stream frames; standalone captures
   keep the original message shape. */
static long begin_frame_fields(const ShotMeta *meta, char *out, long cap)
{
    long pos = 0;
    short i;

    if (meta->kind == kFrameStandalone) {
        out[0] = '\0';
        return 0;
    }
    if (meta->kind == kFrameKey) {
        return snprintf(out, (size_t)cap, ",\"frame\":\"key\"");
    }
    pos = snprintf(out, (size_t)cap, ",\"frame\":\"delta\",\"rects\":[");
    for (i = 0; i < meta->n_rects; ++i) {
        short scale = meta->row_scale > 1 ? meta->row_scale : 1;
        long canvas_row = (long)meta->rects[i].row * scale
            + meta->row_phase;

        if (scale > 1) {
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            "%s[%ld,%d,%d,%d,%d]", i > 0 ? "," : "",
                            canvas_row, (int)meta->rects[i].n_rows,
                            (int)meta->rects[i].col_off,
                            (int)meta->rects[i].col_bytes, (int)scale);
        } else {
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            "%s[%ld,%d,%d,%d]", i > 0 ? "," : "",
                            canvas_row, (int)meta->rects[i].n_rows,
                            (int)meta->rects[i].col_off,
                            (int)meta->rects[i].col_bytes);
        }
    }
    pos += snprintf(out + pos, (size_t)(cap - pos), "]");
    return pos;
}

static int arm_xfer_common(long id, unsigned short xfer, long total,
                           long chunk, short pace_ms, XferKind kind)
{
    Ptr frame = NewPtr(chunk + kNowFrameHeaderBytes);

    if (frame == NULL) {
        return 0;
    }
    memset(&g_xfer, 0, sizeof g_xfer);
    g_xfer.kind = kind;
    g_xfer.frame = frame;
    g_xfer.active = true;
    g_xfer.total = total;
    g_xfer.offset = 0;
    g_xfer.chunk = chunk;
    g_xfer.xfer = xfer;
    g_xfer.id = id;
    g_xfer.pace_ms = pace_ms;
    g_xfer.frame_len = kNowFrameHeaderBytes;   /* primes the first build */
    g_xfer.frame_sent = kNowFrameHeaderBytes;
    g_xfer.started = TickCount();
    g_xfer.next_tick = 0;
    g_xfer.deadline = TickCount() + kXferDeadlineTicks;
    return 1;
}

/* Arms the sender over an arbitrary handle. The caller has already
   announced the transfer (capture.begin / file.begin); on success the
   transfer owns the handle. */
static int arm_blob_transfer(long id, unsigned short xfer, Handle data,
                             long total, long chunk, short pace_ms,
                             XferKind kind)
{
    if (!arm_xfer_common(id, xfer, total, chunk, pace_ms, kind)) {
        return 0;
    }
    g_xfer.data = data;
    HLock(data);
    return 1;
}

/* File bytes differ from captures only at the source boundary: one frame
   is filled from open forks instead of copied from a whole-file handle.
   After success the transfer owns `file`; the caller is reset to an
   inert value so its normal cleanup remains safe. */
static int arm_file_transfer(long id, unsigned short xfer, FileStage *file,
                             long chunk, short pace_ms)
{
    if (now_files_stage_open(file) != kFilesOK) {
        return 0;
    }
    if (!arm_xfer_common(id, xfer, file->total_bytes, chunk, pace_ms,
                         kXferFile)) {
        now_files_stage_dispose(file);
        return 0;
    }
    g_xfer.file_stream = true;
    g_xfer.file = *file;
    memset(file, 0, sizeof *file);
    file->data_ref = -1;
    file->rsrc_ref = -1;
    return 1;
}

static int arm_transfer(long id, unsigned short xfer, const ShotMeta *meta,
                        PixelBlob *blob, long chunk, short pace_ms,
                        Boolean pushed)
{
    char frame_fields[640];
    char json[1024];
    PixelBlob owned = *blob;

    memset(blob, 0, sizeof *blob);
    begin_frame_fields(meta, frame_fields, sizeof frame_fields);
    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld"
             "%s}",
             id, xfer, (int)meta->width, (int)meta->height,
             (int)meta->depth, (int)meta->row_bytes, owned.total_bytes,
             owned.palette_bytes, owned.packed ? "packbits" : "raw",
             meta->capture_ms, owned.encode_ms, frame_fields);
    if (!send_control(json)
        || !arm_blob_transfer(id, xfer, owned.data, owned.total_bytes,
                              chunk, pace_ms, kXferCapture)) {
        now_pixels_dispose(&owned);
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return 0;
    }
    g_xfer.blob = owned;              /* the blob owns the handle */
    g_xfer.pushed = pushed;
    return 1;
}

/* Captures, exports wire pixels, announces with capture.begin, and arms the
   incremental sender. Returns immediately - the bytes go out from
   service_transfer so the app keeps running. */
static void serve_capture(const char *request)
{
    NowPrefs prefs;
    PixelBlob blob;
    ShotMeta meta;
    char json[256];
    long id = now_json_find_int(request, "id", 0);
    long depth_arg = now_json_find_int(request, "depth", 0);
    short depth;
    unsigned short xfer;
    long chunk;
    short pace_ms;
    Boolean pack;

    if (g_stream.active) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, next_xfer());
        send_control(json);
        return;                       /* the stream owns the lane */
    }
    if (g_xfer.active) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, next_xfer());
        send_control(json);
        return;                       /* one transfer at a time */
    }
    now_prefs_load(&prefs);
    depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(request, &prefs, &chunk, &pace_ms, &pack);
    xfer = next_xfer();

    memset(&blob, 0, sizeof blob);
    if (!gather_shot(depth, pack, &blob, &meta)) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }
    arm_transfer(id, xfer, &meta, &blob, chunk, pace_ms, false);
}

/* The one failure shape a solicited capture (or shot) owes the host, so
   it never waits on a transfer that will not come. */
static void capture_fail(long id)
{
    char json[128];

    snprintf(json, sizeof json,
             "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":false}", id, next_xfer());
    send_control(json);
}

static void shot_drop(void)
{
    g_shot.active = false;
}

/* "Screenshot App": front the target, then arm the deferred capture. No
   reply yet - the answer is the capture transfer (or a capture.end
   ok:false), correlated by this id, exactly as a plain capture.request. */
static void serve_process_shot(const char *request)
{
    NowPrefs prefs;
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    long id = now_json_find_int(request, "id", 0);
    long depth_arg = now_json_find_int(request, "depth", 0);

    if (g_stream.active || g_xfer.active || g_shot.active) {
        now_log(kLogWarn, "proc", "#%ld shot refused: a transfer is in flight",
                id);
        capture_fail(id);             /* one transfer at a time */
        return;
    }
    psn.highLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnHigh", 0);
    psn.lowLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnLow", 0);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) != noErr
        || GetCurrentProcess(&g_shot.self) != noErr) {
        now_log(kLogWarn, "proc", "#%ld shot refused: no such process", id);
        capture_fail(id);
        return;
    }
    {
        char cname[32];
        memcpy(cname, name + 1, name[0]);
        cname[name[0]] = '\0';
        now_log(kLogInfo, "proc", "#%ld shot of %.31s begun", id, cname);
    }
    now_prefs_load(&prefs);
    g_shot.target = psn;
    g_shot.id = id;
    g_shot.depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(request, &prefs, &g_shot.chunk, &g_shot.pace_ms,
                     &g_shot.pack);
    now_proc_bring_to_front(&psn);
    g_shot.active = true;
    /* ~0.75 s for the target to come front and repaint before we read the
       framebuffer - the same beat the Front & Capture page waits. */
    g_shot.deadline = TickCount() + 45;
}

/* Fires the deferred shot once the target has had time to come forward:
   read its front window's fresh bounds, crop the capture to them, restore
   NOW, and deliver over the capture transport. */
static void service_shot(void)
{
    NowPeekWindowList w;
    Rect rect;
    Boolean have_rect = false;
    PixelBlob blob;
    ShotMeta meta;
    int ok;

    if (!g_shot.active || TickCount() < g_shot.deadline) {
        return;
    }
    g_shot.active = false;

    /* Crop to the target's front window when the anchor plane can read its
       bounds. When it cannot - a windowless process, or NOW reading its
       own slot - fall back to the whole screen rather than failing: the
       human asked for a picture of that app, and the app is now front, so
       the screen with it on it is a truthful answer, not an error. */
    if (now_peek_windows_for_psn(&g_shot.target, &w) == kNowPeekReadOk
        && w.count >= 1) {
        SetRect(&rect, w.windows[0].left, w.windows[0].top,
                w.windows[0].right, w.windows[0].bottom);
        have_rect = true;
    }

    memset(&blob, 0, sizeof blob);
    ok = have_rect
        ? gather_shot_rect(g_shot.depth, &rect, g_shot.pack, &blob, &meta)
        : gather_shot(g_shot.depth, g_shot.pack, &blob, &meta);
    /* Pixels grabbed; NOW comes back to the front to send them (it pumps
       the wire either way, but this leaves the human's machine where they
       left it). */
    SetFrontProcess(&g_shot.self);
    if (!ok) {
        capture_fail(g_shot.id);
        return;
    }
    arm_transfer(g_shot.id, next_xfer(), &meta, &blob, g_shot.chunk,
                 g_shot.pace_ms, false);
}

/* --- guest-initiated push ----------------------------------------------
   Send to Host is offer/accept: the guest captures FIRST (so the offer
   carries true byte counts and a refusal costs nothing but the capture),
   announces with capture.offer, and only starts the bulk stream when the
   host answers capture.accept. The host can refuse - busy, no landing
   pad - and the refusal reason lands in the panel, at the machine the
   human is actually sitting at. */

enum { kOfferTimeoutTicks = 60 * 15 };

static struct {
    Boolean active;
    PixelBlob blob;
    ShotMeta meta;
    long id;
    long chunk;
    short pace_ms;
    unsigned long deadline;
} g_offer;

static void offer_cleanup(void)
{
    now_pixels_dispose(&g_offer.blob);
    g_offer.active = false;
}

int now_wire_offer_shot(char *err, long cap)
{
    NowPrefs prefs;
    char json[512];
    char line[96];
    char peer[40];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_stream.active) {
        snprintf(err, (size_t)cap, "Already streaming");
        return -1;
    }
    if (wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_prefs_load(&prefs);
    g_offer.chunk = (long)prefs.chunk_kb * 1024;
    if (g_offer.chunk < 1024 || g_offer.chunk > kNowMaxPayload) {
        g_offer.chunk = 8192;
    }
    g_offer.pace_ms = prefs.pace_ms;
    memset(&g_offer.blob, 0, sizeof g_offer.blob);
    if (!gather_shot(prefs.shot_depth, prefs.shot_pack, &g_offer.blob,
                     &g_offer.meta)) {
        snprintf(err, (size_t)cap, "Screen capture failed");
        return -1;
    }
    ++g.offer_seq;
    g_offer.id = g.offer_seq;
    snprintf(json, sizeof json,
             "{\"type\":\"capture.offer\",\"id\":%ld,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld}",
             g_offer.id, (int)g_offer.meta.width, (int)g_offer.meta.height,
             (int)g_offer.meta.depth, (int)g_offer.meta.row_bytes,
             g_offer.blob.total_bytes, g_offer.blob.palette_bytes,
             g_offer.blob.packed ? "packbits" : "raw",
             g_offer.meta.capture_ms, g_offer.blob.encode_ms);
    if (!send_control(json)) {
        offer_cleanup();
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_offer.active = true;
    g_offer.deadline = TickCount() + kOfferTimeoutTicks;
    conn_peer_label(peer, sizeof peer);
    snprintf(line, sizeof line, "Offered %ld KB to %s...",
             g_offer.blob.total_bytes / 1024, peer);
    note_shot(line);
    return 0;
}

static void offer_accepted(const char *reply)
{
    if (!g_offer.active || now_json_find_int(reply, "id", -1) != g_offer.id) {
        return;                       /* stale or unsolicited accept */
    }
    g_offer.active = false;
    if (arm_transfer(g_offer.id, next_xfer(), &g_offer.meta, &g_offer.blob,
                     g_offer.chunk, g_offer.pace_ms, true)) {
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "Sending to %s...", peer);
            note_shot(line);
        }
    } else {
        note_shot("Send failed");
    }
}

static void offer_refused(const char *reply)
{
    char reason[64];
    char line[96];
    char peer[40];

    if (!g_offer.active || now_json_find_int(reply, "id", -1) != g_offer.id) {
        return;
    }
    offer_cleanup();
    conn_peer_label(peer, sizeof peer);
    if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.39s declined: %.44s", peer, reason);
    } else {
        snprintf(line, sizeof line, "%s declined the screenshot", peer);
    }
    note_shot(line);
}

static void service_offer(void)
{
    if (g_offer.active && TickCount() > g_offer.deadline) {
        offer_cleanup();
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "%s did not answer", peer);
            note_shot(line);
        }
    }
}

/* --- files -------------------------------------------------------------
   Listing is control-plane only, so browsing works even mid-stream. A
   pull is the standard begin -> bulk -> end shape on the shared lane,
   under the same one-at-a-time rule as captures. */

static void file_refuse(long id, const char *code, const char *reason)
{
    char json[256];

    now_log(kLogWarn, "files", "#%ld refused: %s (%.60s)", id, code, reason);

    snprintf(json, sizeof json,
             "{\"type\":\"file.refuse\",\"id\":%ld,\"code\":\"%s\","
             "\"reason\":\"%.120s\"}", id, code, reason);
    send_control(json);
}

/* Once file.begin has been announced, failure is an end rather than a
   refusal. The receiver has already opened its temp and needs the
   transfer-correlated terminal message to clean it immediately. */
static void file_start_failed(long id, unsigned short xfer)
{
    char json[160];

    snprintf(json, sizeof json,
             "{\"type\":\"file.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":false}", id, xfer);
    send_control(json);
}

static void file_refuse_rc(long id, int rc)
{
    switch (rc) {
    case kFilesBadPath:
        file_refuse(id, "bad-path", "path leaves the share");
        break;
    case kFilesNotFound:
        file_refuse(id, "not-found", "no such item in the share");
        break;
    case kFilesNotAFolder:
        file_refuse(id, "bad-path", "not a folder");
        break;
    case kFilesTooBig:
        file_refuse(id, "too-big", "the file cannot be prepared safely");
        break;
    default:
        file_refuse(id, "io-error", "the File Manager refused");
        break;
    }
}

/* --- changing the share -------------------------------------------------
   Every one of these answers with file.result, success or not, because
   the far side is holding an undo stack and a silent failure would
   leave it believing something it can reverse. */

static const char *files_code(int rc)
{
    switch (rc) {
    case kFilesBadPath:   return "bad-path";
    case kFilesNotFound:  return "not-found";
    case kFilesNotAFolder:return "bad-path";
    case kFilesExists:    return "exists";
    default:              return "io-error";
    }
}

static const char *files_reason(int rc)
{
    switch (rc) {
    case kFilesBadPath:   return "that path leaves the shared folder";
    case kFilesNotFound:  return "no such item - it may have been moved "
                                 "or the Trash emptied";
    case kFilesNotAFolder:return "not a folder";
    case kFilesExists:    return "something is already there";
    default:              return "the File Manager refused";
    }
}

static void file_result_fail(long id, int rc)
{
    char json[320];
    char detail[64];

    /* An io-error carries the File Manager's own number: without it the
       far side can only report that something went wrong. */
    detail[0] = '\0';
    if (rc != kFilesBadPath && rc != kFilesNotFound && rc != kFilesExists) {
        snprintf(detail, sizeof detail, " (File Manager error %d)",
                 (int)now_files_last_error());
    }
    snprintf(json, sizeof json,
             "{\"type\":\"file.result\",\"id\":%ld,\"ok\":false,"
             "\"code\":\"%s\",\"reason\":\"%s%s\"}",
             id, files_code(rc), files_reason(rc), detail);
    send_control(json);
}

static void file_result_ok(long id, const char *path, const char *trashed_as)
{
    char json[512];
    char esc[300];
    long pos;

    now_json_escape(path != NULL ? path : "", esc, sizeof esc);
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"file.result\",\"id\":%ld,\"ok\":true,"
                   "\"path\":\"%s\"", id, esc);
    if (trashed_as != NULL && trashed_as[0] != '\0') {
        char esc_name[160];

        now_json_escape(trashed_as, esc_name, sizeof esc_name);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        ",\"trashedAs\":\"%s\"", esc_name);
    }
    snprintf(json + pos, sizeof json - (size_t)pos, "}");
    send_control(json);
}

static void serve_file_move(const char *request)
{
    char from[224], to[224];
    long id = now_json_find_int(request, "id", 0);
    Boolean overwrite = now_json_find_bool(request, "overwrite", false);
    int rc;

    from[0] = to[0] = '\0';
    /* HFS names, not tokens: the host sends them UTF-8, and the File
       Manager wants MacRoman. find_text decodes; find_string would hand
       "café" to FSMakeFSSpec as the wrong bytes. */
    now_json_find_text(request, "path", from, sizeof from);
    now_json_find_text(request, "toPath", to, sizeof to);
    rc = now_files_move(from, to, overwrite);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, to, NULL);
    note_shot("Item moved");
}

static void serve_file_trash(const char *request)
{
    char path[224];
    char landed[64];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    rc = now_files_trash(path, landed, sizeof landed);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, landed);
    note_shot("Item moved to the Trash");
}

static void serve_file_restore(const char *request)
{
    char path[224];
    char trashed_as[64];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = trashed_as[0] = '\0';
    now_json_find_text(request, "trashedAs", trashed_as, sizeof trashed_as);
    now_json_find_text(request, "toPath", path, sizeof path);
    rc = now_files_restore(trashed_as, path);
    if (rc != kFilesOK) {
        /* not-found here means the Trash no longer holds it — emptied,
           or dragged out by hand. That is a real answer, not our error. */
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, NULL);
    note_shot("Item put back");
}

static void serve_file_mkdir(const char *request)
{
    char path[224];
    long id = now_json_find_int(request, "id", 0);
    int rc;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    rc = now_files_mkdir(path);
    if (rc != kFilesOK) {
        file_result_fail(id, rc);
        return;
    }
    file_result_ok(id, path, NULL);
    note_shot("Folder created");
}

/* --- browsing the OTHER machine's share ----------------------------------
   The mirror of serve_file_list: the same message, asked rather than
   answered. Listings are control-plane, so browsing works while a
   transfer or a stream is in flight - only the ANSWER is one at a
   time, and a second request simply replaces the first. */

enum { kBrowseTimeoutTicks = 60 * 20 };

static struct {
    Boolean pending;
    long id;
    char path[224];
    unsigned long deadline;
} g_browse;

static ConnListing g_listing_hook;

void conn_set_listing(ConnListing fn)
{
    g_listing_hook = fn;
}

int now_wire_list_host(const char *path, long cursor, char *err, long cap)
{
    char json[720];               /* an escaped path can be 6x its bytes */
    char esc[600];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (path == NULL) {
        path = "";
    }
    if (strlen(path) >= sizeof g_browse.path) {
        snprintf(err, (size_t)cap, "That path is too long");
        return -1;
    }
    now_json_escape(path, esc, sizeof esc);
    ++g.offer_seq;
    g_browse.id = g.offer_seq;
    strcpy(g_browse.path, path);
    snprintf(json, sizeof json,
             "{\"type\":\"file.list\",\"id\":%ld,\"path\":\"%s\","
             "\"cursor\":%ld}",
             g_browse.id, esc, cursor > 0 ? cursor : 1);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_browse.pending = true;
    g_browse.deadline = TickCount() + kBrowseTimeoutTicks;
    return 0;
}

/* A listing off the wire. Names are DECODED (UTF-8 to MacRoman) because
   everything here is either drawn or used as a file name, and neither
   can hold anything else. */
static void browse_listing(const char *reply)
{
    FileEntry entries[16];
    char object[320];
    char root[160];
    char kind[16];
    const char *p;
    int n = 0;

    if (!g_browse.pending
        || now_json_find_int(reply, "id", -1) != g_browse.id) {
        return;
    }
    g_browse.pending = false;

    memset(entries, 0, sizeof entries);
    p = now_json_array(reply, "entries");
    while (p != NULL && n < (int)(sizeof entries / sizeof entries[0])) {
        char type[8], creator[8];

        p = now_json_next_object(p, object, sizeof object);
        if (p == NULL) {
            break;
        }
        now_json_find_text(object, "name", entries[n].name,
                           sizeof entries[n].name);
        if (entries[n].name[0] == '\0') {
            continue;                 /* a nameless entry is unusable */
        }
        kind[0] = '\0';
        now_json_find_string(object, "kind", kind, sizeof kind);
        entries[n].folder = (strcmp(kind, "folder") == 0);
        entries[n].data_bytes = now_json_find_int(object, "dataBytes", 0);
        entries[n].rsrc_bytes = now_json_find_int(object, "rsrcBytes", 0);
        entries[n].modified =
            (unsigned long)now_json_find_int(object, "modified", 0);
        type[0] = '\0';
        creator[0] = '\0';
        now_json_find_string(object, "fileType", type, sizeof type);
        now_json_find_string(object, "creator", creator, sizeof creator);
        if (strlen(type) == 4) {
            memcpy(&entries[n].file_type, type, 4);
        }
        if (strlen(creator) == 4) {
            memcpy(&entries[n].creator, creator, 4);
        }
        ++n;
    }

    root[0] = '\0';
    now_json_find_text(reply, "root", root, sizeof root);
    if (g_listing_hook != NULL) {
        g_listing_hook(g_browse.path, entries, n,
                       now_json_find_bool(reply, "more", 0) ? true : false,
                       now_json_find_int(reply, "cursor", 1),
                       root[0] != '\0' ? root : NULL, NULL);
    }
}

/* Does this refusal answer OUR question? Browsing and sending both use
   the offer sequence, so the id says which. */
static Boolean browse_refused(const char *reply)
{
    char reason[96];

    if (!g_browse.pending
        || now_json_find_int(reply, "id", -1) != g_browse.id) {
        return false;
    }
    g_browse.pending = false;
    if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
        strcpy(reason, "the other Mac refused");
    }
    if (g_listing_hook != NULL) {
        g_listing_hook(g_browse.path, NULL, 0, false, 1, NULL, reason);
    }
    return true;
}

static void service_browse(void)
{
    if (g_browse.pending && TickCount() > g_browse.deadline) {
        g_browse.pending = false;
        if (g_listing_hook != NULL) {
            g_listing_hook(g_browse.path, NULL, 0, false, 1, NULL,
                           "no answer");
        }
    }
}

/* --- pulling a file FROM the other machine -------------------------------
   The same bytes as an inbound push, asked for rather than offered, so
   the receiving machinery is the same and only the destination differs:
   a pulled file lands in the downloads folder, outside the share. What
   a person fetches is theirs, not something the other machine can then
   reach back into. */

enum { kGetTimeoutTicks = 60 * 30 };

static struct {
    Boolean pending;                  /* asked; no bytes yet */
    Boolean receiving;                /* file.begin seen; writing */
    long id;
    long expected;
    char name[32];
    FileReceive rx;
    unsigned long deadline;
} g_get;

static ConnGetNote g_get_note;

void conn_set_get_note(ConnGetNote fn)
{
    g_get_note = fn;
}

static void get_note(const char *line)
{
    if (g_get_note != NULL) {
        g_get_note(line);
    }
}

static void get_cleanup(Boolean keep_file)
{
    if (g_get.receiving && !keep_file) {
        now_files_receive_abort(&g_get.rx);
    }
    g_get.pending = false;
    g_get.receiving = false;
}

Boolean now_wire_get_active(long *received, long *expected)
{
    if (!g_get.pending && !g_get.receiving) {
        return false;
    }
    if (received != NULL) {
        *received = g_get.receiving ? g_get.rx.received : 0;
    }
    if (expected != NULL) {
        *expected = g_get.expected;
    }
    return true;
}

int now_wire_get_host(const char *path, const char *name, char *err, long cap)
{
    char json[720];
    char esc[600];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_get.pending || g_get.receiving || wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_json_escape(path, esc, sizeof esc);
    ++g.offer_seq;
    g_get.id = g.offer_seq;
    g_get.expected = 0;
    snprintf(g_get.name, sizeof g_get.name, "%.31s", name != NULL ? name : "");
    snprintf(json, sizeof json,
             "{\"type\":\"file.get\",\"id\":%ld,\"path\":\"%s\"}",
             g_get.id, esc);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_get.pending = true;
    g_get.deadline = TickCount() + kGetTimeoutTicks;
    return 0;
}

/* The answer: bytes are coming. Opening the file here rather than at
   the end means a big file never has to be held in memory - the same
   rule an inbound push already follows. */
static void get_begin(const char *reply)
{
    char container_arg[16];
    char type[8], creator[8];
    short vref;
    long dir;
    FileContainer container = kContainerData;
    OSType file_type = 0, creator_code = 0;
    char name[64];
    char line[128];
    int rc;

    if (!g_get.pending || now_json_find_int(reply, "id", -1) != g_get.id) {
        return;
    }
    g_get.pending = false;
    g_get.expected = now_json_find_int(reply, "bytes", 0);

    /* The sender names the file; it has already made the name one this
       machine can hold. Ours was only a guess from the listing. */
    if (now_json_find_text(reply, "name", name, sizeof name)
        && name[0] != '\0') {
        snprintf(g_get.name, sizeof g_get.name, "%.31s", name);
    }
    if (now_json_find_string(reply, "container", container_arg,
                             sizeof container_arg)
        && strcmp(container_arg, "macbinary") == 0) {
        container = kContainerMacBinary;
    }
    type[0] = '\0';
    creator[0] = '\0';
    now_json_find_string(reply, "fileType", type, sizeof type);
    now_json_find_string(reply, "creator", creator, sizeof creator);
    if (strlen(type) == 4) {
        memcpy(&file_type, type, 4);
    }
    if (strlen(creator) == 4) {
        memcpy(&creator_code, creator, 4);
    }

    if (now_files_downloads(&vref, &dir) != kFilesOK) {
        get_cleanup(false);
        get_note("Cannot find the downloads folder");
        return;
    }
    /* No resume token on a pull yet: resuming is the sender's protocol
       and this side has never been the sender. A pull starts at zero. */
    rc = now_files_receive_begin_at(vref, dir, g_get.name, container,
                                    g_get.expected, file_type, creator_code,
                                    (unsigned long)now_json_find_int(
                                        reply, "modified", 0),
                                    false, NULL, 0, &g_get.rx);
    if (rc == kFilesExists) {
        /* Not an error and not a silent overwrite: the file is already
           there, and this machine keeps what it has. */
        get_cleanup(false);
        snprintf(line, sizeof line, "%.31s is already in the downloads folder",
                 g_get.name);
        get_note(line);
        return;
    }
    if (rc != kFilesOK) {
        get_cleanup(false);
        get_note(rc == kFilesTooBig ? "Not enough room on the disk"
                                    : "Could not create the file");
        return;
    }
    g_get.receiving = true;
    g_get.deadline = TickCount() + kGetTimeoutTicks;
    now_log(kLogInfo, "get", "#%ld %.31s, %ld bytes", g_get.id, g_get.name,
            g_get.expected);
    snprintf(line, sizeof line, "Getting %.31s...", g_get.name);
    get_note(line);
}

/* file.end for a pull: rename into place, or throw away the part. */
static void get_end(const char *reply)
{
    char line[128];

    if (!g_get.receiving || now_json_find_int(reply, "id", -1) != g_get.id) {
        return;
    }
    if (!now_json_find_bool(reply, "ok", 0)) {
        now_log(kLogWarn, "get", "#%ld ended early at %ld of %ld bytes",
                g_get.id, g_get.rx.received, g_get.expected);
        get_cleanup(false);
        get_note("The other Mac stopped sending");
        return;
    }
    if (now_files_receive_finish(&g_get.rx) != kFilesOK) {
        get_cleanup(false);
        get_note("Could not finish writing the file");
        return;
    }
    now_log(kLogInfo, "get", "#%ld %.31s complete, %ld bytes", g_get.id,
            g_get.name, g_get.rx.received);
    get_cleanup(true);
    {
        char where[64];

        now_files_downloads_name(where, sizeof where);
        snprintf(line, sizeof line, "Got %.31s - it is in %.31s",
                 g_get.name, where);
    }
    get_note(line);
}

static void service_get(void)
{
    if ((g_get.pending || g_get.receiving)
        && TickCount() > g_get.deadline) {
        get_cleanup(false);
        get_note("The other Mac stopped answering");
    }
}

/* --- sending a file to the host -----------------------------------------
   The mirror image of receiving one, and deliberately the same shape:
   we offer, the host answers, and only then do bytes move. The guest
   sends what a human picked in a standard dialog, so the file need not
   be anywhere near the share — sending is not browsing. */

enum { kSendTimeoutTicks = 60 * 20 };

static struct {
    Boolean active;                   /* offered, or sending */
    Boolean sending;                  /* the host said yes; bytes moving */
    /* The host says something is already there. The staged bytes stay
       put while a person decides; wire code cannot ask (pump.h), so it
       raises this and the event loop does the asking. */
    Boolean awaiting_confirm;
    char occupied_by[64];             /* what the host called the clash */
    long id;
    FileStage stage;
    char name[32];                    /* kept past the stage handoff */
    long total;
    long received;                    /* host-confirmed, when it reports */
    Boolean receiving_reports;
    long chunk;
    short pace_ms;
    unsigned long deadline;
} g_send;

static Boolean send_owns_transfer(long id)
{
    return g_send.active && g_send.sending && g_send.id == id;
}

SendPhase now_wire_send_state(long *sent, long *total,
                              char *name, long name_cap)
{
    if (!g_send.active) {
        return kSendNothing;
    }
    if (name != NULL && name_cap > 0) {
        strncpy(name, g_send.name, (size_t)name_cap - 1);
        name[name_cap - 1] = '\0';
    }
    if (total != NULL) {
        *total = g_send.total;
    }
    if (sent != NULL) {
        *sent = g_send.receiving_reports ? g_send.received
            : ((g_send.sending && g_xfer.active && g_xfer.id == g_send.id)
                ? g_xfer.offset : 0);
    }
    return g_send.sending ? kSendSending : kSendOffering;
}

static void send_cleanup(void)
{
    now_files_stage_dispose(&g_send.stage);
    g_send.active = false;
    g_send.sending = false;
    g_send.awaiting_confirm = false;
}

int now_wire_send_file(const FSSpec *spec, char *err, long cap)
{
    NowPrefs prefs;
    FileStage stage;
    char peer[40];
    char line[96];
    int rc;

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (wire_busy()) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    rc = now_files_stage_spec(spec, kContainerAuto, &stage);
    if (rc == kFilesNotAFolder) {
        snprintf(err, (size_t)cap, "Folders cannot be sent yet");
        return -1;
    }
    if (rc != kFilesOK) {
        snprintf(err, (size_t)cap, "Could not read that file");
        return -1;
    }

    now_prefs_load(&prefs);
    g_send.chunk = (long)prefs.chunk_kb * 1024;
    if (g_send.chunk < 1024 || g_send.chunk > kNowMaxPayload) {
        g_send.chunk = 8192;
    }
    g_send.pace_ms = prefs.pace_ms;
    g_send.stage = stage;
    strncpy(g_send.name, stage.name, sizeof g_send.name - 1);
    g_send.name[sizeof g_send.name - 1] = '\0';
    g_send.total = stage.total_bytes;
    g_send.received = 0;
    g_send.receiving_reports = false;
    g_send.sending = false;
    ++g.offer_seq;
    g_send.id = g.offer_seq;
    if (!send_offer(false)) {
        send_cleanup();
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_send.active = true;
    g_send.deadline = TickCount() + kSendTimeoutTicks;
    now_log(kLogInfo, "send", "#%ld offering %.31s, %ld bytes", g_send.id,
            stage.name, stage.total_bytes);
    conn_peer_label(peer, sizeof peer);
    snprintf(line, sizeof line, "Asking %.20s to accept %.31s...",
             peer, stage.name);
    note_file(line);
    return 0;
}

/* The offer itself. Sent once to ask, and again with overwrite set if
   the person says to replace what is already there. */
static Boolean send_offer(Boolean overwrite)
{
    char json[512];
    const FileStage stage = g_send.stage;

    {
        char type[8], creator[8];
        char esc_name[200], esc_type[40], esc_creator[40];

        memcpy(type, &stage.file_type, 4);
        type[4] = '\0';
        memcpy(creator, &stage.creator, 4);
        creator[4] = '\0';
        now_json_escape(stage.name, esc_name, sizeof esc_name);
        now_json_escape(type, esc_type, sizeof esc_type);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        /* path is REQUIRED by the contract — "" means the root of the
           receiver's share. Leaving it out cost a dropped connection:
           the host could not decode the frame at all. */
        snprintf(json, sizeof json,
                 "{\"type\":\"file.offer\",\"id\":%ld,\"name\":\"%s\","
                 "\"path\":\"\",\"container\":\"%s\",\"bytes\":%ld,"
                 "\"fileType\":\"%s\",\"creator\":\"%s\","
                 "\"modified\":%lu%s}",
                 g_send.id, esc_name,
                 stage.container == kContainerMacBinary ? "macbinary" : "data",
                 stage.total_bytes, esc_type, esc_creator, stage.modified,
                 overwrite ? ",\"overwrite\":true" : "");
    }
    return send_control(json);
}

/* The host said yes: announce the transfer, then hand the staged bytes
   to the same machine a pull uses. */
static void send_accepted(const char *reply)
{
    char json[512];
    unsigned short xfer;

    if (!g_send.active || now_json_find_int(reply, "id", -1) != g_send.id) {
        return;
    }
    xfer = next_xfer();
    {
        char esc_name[200];

        /* name and container are REQUIRED here as well; a frame the
           receiver cannot decode costs the whole connection. */
        now_json_escape(g_send.name, esc_name, sizeof esc_name);
        snprintf(json, sizeof json,
                 "{\"type\":\"file.begin\",\"id\":%ld,\"transfer\":%u,"
                 "\"name\":\"%s\",\"container\":\"%s\",\"bytes\":%ld}",
                 g_send.id, xfer, esc_name,
                 g_send.stage.container == kContainerMacBinary
                     ? "macbinary" : "data",
                 g_send.total);
    }
    if (!send_control(json)) {
        send_cleanup();
        return;
    }
    if (!arm_file_transfer(g_send.id, xfer, &g_send.stage,
                           g_send.chunk, g_send.pace_ms)) {
        file_start_failed(g_send.id, xfer);
        send_cleanup();
        note_file("Could not start the transfer");
        return;
    }
    now_files_stage_dispose(&g_send.stage);
    /* active stays true: the send is not over until the host's receipt,
       and until then the panel has something to report. */
    g_send.sending = true;
    {
        char line[96];
        char peer[40];

        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "Sending %.31s to %.20s...",
                 g_send.name, peer);
        note_file(line);
    }
}

static void send_refused(const char *reply)
{
    char reason[64];
    char code[32];
    char line[96];
    char peer[40];

    if (!g_send.active || now_json_find_int(reply, "id", -1) != g_send.id) {
        return;
    }
    conn_peer_label(peer, sizeof peer);

    /* "Something is already there" is a question for a person, not a
       failure. The staged bytes stay exactly where they are; the event
       loop asks, and answers by sending the same offer again. */
    code[0] = '\0';
    now_json_find_string(reply, "code", code, sizeof code);
    if (strcmp(code, "exists") == 0 && !g_send.sending) {
        g_send.awaiting_confirm = true;
        snprintf(g_send.occupied_by, sizeof g_send.occupied_by, "%.63s",
                 g_send.name);
        snprintf(line, sizeof line, "%.20s already has %.31s", peer,
                 g_send.name);
        note_file(line);
        return;
    }
    send_cleanup();
    if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.30s declined: %.50s", peer, reason);
    } else {
        snprintf(line, sizeof line, "%s declined the file", peer);
    }
    note_file(line);
}

/* The host's receipt. A send is not finished until the file exists at
   the other end, so this — not the last byte — is what we report. */
static void send_done(const char *reply)
{
    char reason[80];
    char line[112];
    char peer[40];

    if (!g_send.active) {
        return;                       /* not ours */
    }
    send_cleanup();
    conn_peer_label(peer, sizeof peer);
    /* "ok" is a BOOLEAN. now_json_find_int is strtol, and strtol on
       "true" is 0 — so reading it as an int reports every successful
       send as a failure, which is exactly what it did. */
    if (now_json_find_bool(reply, "ok", 0)) {
        snprintf(line, sizeof line, "Sent to %s", peer);
    } else if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "%.30s could not save it: %.60s",
                 peer, reason);
    } else {
        snprintf(line, sizeof line, "%s could not save it", peer);
    }
    note_file(line);
}

/* What the event loop needs to know to ask. Returns false when nothing
   is waiting on a person. */
Boolean now_wire_send_pending_replace(char *name, long cap)
{
    if (!g_send.awaiting_confirm) {
        return false;
    }
    if (name != NULL && cap > 0) {
        strncpy(name, g_send.occupied_by, (size_t)cap - 1);
        name[cap - 1] = '\0';
    }
    return true;
}

/* The answer. Replacing re-sends the SAME staged bytes with overwrite
   set, so nothing is read off the disk twice and the file cannot have
   changed underneath the question. */
void now_wire_send_resolve_replace(Boolean replace)
{
    char line[96];
    char peer[40];

    if (!g_send.awaiting_confirm) {
        return;
    }
    g_send.awaiting_confirm = false;
    conn_peer_label(peer, sizeof peer);
    if (!replace) {
        send_cleanup();
        note_file("Not sent");
        return;
    }
    if (!send_offer(true)) {
        send_cleanup();
        note_file("Connection lost");
        return;
    }
    g_send.deadline = TickCount() + kSendTimeoutTicks;
    snprintf(line, sizeof line, "Replacing %.31s on %.20s...",
             g_send.name, peer);
    note_file(line);
}

static void service_send(void)
{
    /* Only the ANSWER is on a clock. Once bytes are moving the transfer
       machine owns the deadline, and a slow file is not a dead host. */
    if (g_send.active && !g_send.sending && !g_send.awaiting_confirm
        && TickCount() > g_send.deadline) {
        char peer[40];
        char line[96];

        send_cleanup();
        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "%s did not answer", peer);
        note_file(line);
    }
}

/* --- receiving a put ----------------------------------------------------
   The host offers, the guest answers without prompting anyone, and the
   bytes then stream to disk as they arrive. Nothing is buffered: the
   app partition is smaller than the files people will send. */

static struct {
    Boolean active;                   /* accepted; bytes may arrive */
    long id;
    long reported;                    /* bytes announced with file.progress */
    FileReceive rx;
    /* The offer, kept because file.begin — not file.offer — is what
       finally says where the stream starts. The guest opens optimistically
       at the offset it reported as `have`, and a sender that starts
       somewhere else instead makes it reopen. */
    char path[224];
    char name[64];
    char token[96];
    FileContainer container;
    long bytes;
    OSType file_type, creator;
    unsigned long modified;
    Boolean create_parents;
    Boolean overwrite;
} g_put;

static Boolean wire_busy(void)
{
    return g_stream.active || g_xfer.active || g_offer.active
        || g_send.active || g_put.active;
}

/* A CRC-32 is a 32-bit unsigned value and routinely has its top bit
   set, which now_json_find_int cannot carry: it is strtol into a long,
   and long is 32 bits on this toolchain, so every CRC above 2^31-1
   saturates at LONG_MAX. Left alone, roughly half of all transfers
   would compare a real checksum against 0x7FFFFFFF and be declared
   corrupt. Parsed here as unsigned instead.

   A leading minus is folded rather than rejected: an encoder that
   serialises the value as a signed int32 writes -889275714 for
   0xCAFEBABE, and that is the same 32 bits, not a different format. A
   present-but-unparseable value reads as absent — "unchecked" is the
   honest answer there, and far better than a false "corrupt". */
static unsigned long json_find_u32(const char *json, const char *key,
                                   Boolean *found)
{
    const char *p = now_json_value(json, key);
    unsigned long v = 0;
    Boolean negative = false;

    *found = false;
    if (p == NULL) {
        return 0;
    }
    if (*p == '-') {
        negative = true;
        ++p;
    }
    if (*p < '0' || *p > '9') {
        return 0;
    }
    while (*p >= '0' && *p <= '9') {
        v = (v * 10UL + (unsigned long)(*p - '0')) & 0xFFFFFFFFUL;
        ++p;
    }
    *found = true;
    return negative ? (0UL - v) & 0xFFFFFFFFUL : v;
}

/* How often the guest says where it has got to. The write batch is the
   natural cadence — one report per flush — and on a 2.7 MB file that is
   about 85 control frames across several minutes, which is nothing next
   to the bulk stream they describe. */
/* How often the guest tells the host what it has taken.
 *
 * This is not only a progress bar: the host clocks its sender on these
 * reports and will not run more than a few of them ahead. So the step is
 * flow control, and a coarse one caps how tightly the sender can be
 * bounded — at 32 KB the host could not go below a 64 KB window without
 * deadlocking (it parks, then waits for a report needing bytes it has
 * decided not to send). Matching the host's 8 KB bulk frame means one
 * report per frame, which is what makes a ~24 KB in-flight bound work.
 *
 * Reports stay advisory and are still dropped when the control queue is
 * busy; `received` is cumulative, so a skipped one costs nothing. */
enum { kPutProgressStep = 8 * 1024 };

/* Tells the host what has actually landed. The sender cannot know this:
   its own completion fires when the local socket accepts a chunk, which
   on this link runs minutes ahead of the machine receiving it — the bar
   reached 100% with a third of the file delivered, and the put watchdog
   was being fed by that same lie, so a stalled guest looked healthy.

   Advisory on purpose. The control queue is eight slots deep and shared
   with the messages that carry meaning (pongs, file.done); progress is
   the one thing here that may be dropped, so it yields rather than
   crowding them out, and a skipped report costs the host nothing but a
   coarser bar. */
static void put_report_progress(Boolean force)
{
    char json[128];

    if (!force && g_ctlq.count >= kCtlQueueSlots / 2) {
        return;                       /* real traffic first */
    }
    g_put.reported = g_put.rx.received;
    snprintf(json, sizeof json,
             "{\"type\":\"file.progress\",\"id\":%ld,\"received\":%ld}",
             g_put.id, g_put.rx.received);
    send_control(json);               /* best effort: a drop is not a fault */
}

static void put_drop(void)
{
    if (g_put.active) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
    }
}

static void put_done(Boolean ok, const char *code, const char *reason,
                     const char *cleanup)
{
    char json[320];

    if (ok) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":true,"
                 "\"received\":%ld,\"crc32\":%lu,"
                 "\"finalization\":\"same-folder-rename\","
                 "\"cleanup\":\"temp-renamed\"}",
                 g_put.id, g_put.rx.received, g_put.rx.crc);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":false,"
                 "\"code\":\"%s\",\"reason\":\"%.100s\","
                 "\"received\":%ld,\"cleanup\":\"%s\"}",
                 g_put.id, code, reason, g_put.rx.received,
                 cleanup != NULL ? cleanup : "unknown");
    }
    send_control(json);
    g_put.active = false;
}

static void put_abort(const char *code, const char *reason)
{
    Boolean retained;

    if (!g_put.active) {
        return;
    }
    retained = g_put.rx.keep_partial && g_put.rx.received > 0;
    now_files_receive_abort(&g_put.rx);
    put_done(false, code, reason,
             retained ? "partial-retained" : "temp-discarded");
}

/* Called for every inbound bulk frame. */
static void take_bulk_in(const unsigned char *bytes, long len)
{
    int rc;

    /* A pull we asked for. Only one of these can be live at a time -
       the shared lane is one transfer wide - so which one is expecting
       bytes is never ambiguous. */
    if (g_get.receiving) {
        rc = now_files_receive_chunk(&g_get.rx, bytes, len);
        if (rc != kFilesOK) {
            get_cleanup(false);
            get_note("Could not write the file");
        }
        g_get.deadline = TickCount() + kGetTimeoutTicks;
        return;
    }
    if (!g_put.active) {
        return;                       /* nothing is expecting these */
    }
    rc = now_files_receive_chunk(&g_put.rx, bytes, len);
    if (rc != kFilesOK) {
        put_abort("io-error", "could not write the file");
        return;
    }
    /* The first chunk reports immediately: that is what tells the host
       this guest reports at all, so it can stop trusting its own send
       counter early rather than after the first 32 KB. */
    if (g_put.reported == 0
        || g_put.rx.received - g_put.reported >= kPutProgressStep) {
        put_report_progress(false);
    }
}

static void serve_file_offer(const char *request)
{
    char name[64];
    char path[224];
    char container_arg[16];
    char json[320];
    char note[128];
    long id = now_json_find_int(request, "id", 0);
    long bytes = now_json_find_int(request, "bytes", 0);
    long modified = now_json_find_int(request, "modified", 0);
    char type_arg[8], creator_arg[8];
    OSType file_type = 0, creator = 0;
    FileContainer container = kContainerData;
    Boolean overwrite;
    Boolean create_parents;
    long have;
    int rc;

    if (wire_busy()) {
        file_refuse(id, "busy", "a transfer is already in flight");
        return;
    }
    name[0] = '\0';
    path[0] = '\0';
    /* name and path are HFS identifiers the receiver opens; decode
       UTF-8 to MacRoman. container/fileType/creator below are ASCII
       tokens by contract and stay find_string. */
    now_json_find_text(request, "name", name, sizeof name);
    now_json_find_text(request, "path", path, sizeof path);
    if (now_json_find_string(request, "container", container_arg,
                             sizeof container_arg)
        && strcmp(container_arg, "macbinary") == 0) {
        container = kContainerMacBinary;
    }
    if (now_json_find_string(request, "fileType", type_arg, sizeof type_arg)
        && strlen(type_arg) == 4) {
        memcpy(&file_type, type_arg, 4);
    }
    if (now_json_find_string(request, "creator", creator_arg,
                             sizeof creator_arg)
        && strlen(creator_arg) == 4) {
        memcpy(&creator, creator_arg, 4);
    }
    overwrite = now_json_value(request, "overwrite") != NULL
        && *now_json_value(request, "overwrite") == 't';
    create_parents = now_json_value(request, "createParents") == NULL
        || *now_json_value(request, "createParents") == 't';

    memset(&g_put, 0, sizeof g_put);
    g_put.id = id;
    now_json_find_string(request, "resumeToken", g_put.token,
                         sizeof g_put.token);
    /* What we already hold under this token, and therefore where the
       sender should start. Zero for an offer with no token, which is
       every offer an older host makes. */
    have = now_files_partial_bytes(path, g_put.token, bytes);

    strncpy(g_put.path, path, sizeof g_put.path - 1);
    strncpy(g_put.name, name, sizeof g_put.name - 1);
    g_put.container = container;
    g_put.bytes = bytes;
    g_put.file_type = file_type;
    g_put.creator = creator;
    g_put.modified = (unsigned long)modified;
    g_put.create_parents = create_parents;
    g_put.overwrite = overwrite;

    rc = now_files_receive_begin(path, name, container, bytes, file_type,
                                 creator, (unsigned long)modified,
                                 create_parents, overwrite,
                                 g_put.token, have, &g_put.rx);
    if (rc != kFilesOK && have > 0) {
        /* The partial was there a moment ago and is not usable now.
           Losing it costs time, not correctness — start over rather
           than refuse the file. */
        have = 0;
        rc = now_files_receive_begin(path, name, container, bytes,
                                     file_type, creator,
                                     (unsigned long)modified,
                                     create_parents, overwrite,
                                     g_put.token, 0, &g_put.rx);
    }
    if (rc != kFilesOK) {
        switch (rc) {
        case kFilesExists:
            file_refuse(id, "exists", "a file of that name is already there");
            break;
        case kFilesBadPath:
            file_refuse(id, "bad-path", "that name or folder is not usable");
            break;
        case kFilesTooBig:
            file_refuse(id, "too-big", "not enough room on that disk");
            break;
        default:
            file_refuse(id, "io-error", "could not create the file");
            break;
        }
        return;
    }
    g_put.active = true;
    now_log(kLogInfo, "put", "#%ld %.31s, %ld bytes, into the share", id,
            name, bytes);
    /* `have` is omitted rather than sent as 0, so an accept to an old
       host looks exactly as it always did. */
    if (have > 0 && g_put.rx.free_before >= 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,\"have\":%ld,"
                 "\"freeBytes\":%ld,\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, have, g_put.rx.free_before, g_put.rx.reserved_bytes);
    } else if (have > 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,\"have\":%ld,"
                 "\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, have, g_put.rx.reserved_bytes);
    } else if (g_put.rx.free_before >= 0) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,"
                 "\"freeBytes\":%ld,\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, g_put.rx.free_before, g_put.rx.reserved_bytes);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.accept\",\"id\":%ld,"
                 "\"reservedBytes\":%ld,"
                 "\"staging\":\"same-folder-temp\"}",
                 id, g_put.rx.reserved_bytes);
    }
    if (!send_control(json)) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
        return;
    }
    if (have > 0) {
        snprintf(note, sizeof note, "Resuming %.31s...", name);
    } else {
        snprintf(note, sizeof note, "Receiving %.31s...", name);
    }
    note_shot(note);
}

/* file.begin is what actually fixes where the stream starts. Usually it
   agrees with the `have` just reported and there is nothing to do; a
   sender is free to start somewhere else, though, and then the file
   opened at the wrong offset has to be reopened at the right one before
   a single byte lands. Getting this wrong writes the tail of a file
   over the middle of it, which no checksum can repair — only detect. */
static void put_begin(const char *request)
{
    long offset;
    int rc;
    Boolean retained;

    if (!g_put.active) {
        return;
    }
    offset = now_json_find_int(request, "offset", 0);
    if (offset == g_put.rx.received) {
        return;                       /* the sender took our advice */
    }
    if (offset < 0 || offset > g_put.bytes) {
        put_abort("io-error", "the sender named an impossible offset");
        return;
    }
    retained = g_put.rx.keep_partial && g_put.rx.received > 0;
    now_files_receive_abort(&g_put.rx);   /* may keep a resumable partial */
    rc = now_files_receive_begin(g_put.path, g_put.name, g_put.container,
                                 g_put.bytes, g_put.file_type,
                                 g_put.creator, g_put.modified,
                                 g_put.create_parents, g_put.overwrite,
                                 g_put.token, offset,
                                 &g_put.rx);
    if (rc != kFilesOK) {
        put_done(false, "io-error", "could not start at that offset",
                 retained ? "partial-retained" : "temp-discarded");
        note_shot("Incoming file failed");
    }
}

/* The sender's file.end closes the transfer; the guest confirms only
   after the bytes are written and the file is stamped and named. */
static void finish_put(const char *reply)
{
    char note[128];
    unsigned long want_crc;
    Boolean has_crc;
    int rc;

    if (!g_put.active) {
        return;
    }
    if (now_json_value(reply, "ok") != NULL
        && !now_json_find_bool(reply, "ok", 1)) {
        now_log(kLogWarn, "put", "#%ld cancelled at %ld bytes", g_put.id,
                g_put.rx.received);
        put_abort("cancelled", "the sender stopped");
        note_shot("Incoming file cancelled");
        return;
    }
    /* The seam check. A resumed file is stitched from two sessions and
       nothing else looks at the join, so this is the one thing that can
       say the result is the file the sender meant. An absent crc32 is
       "unchecked" — the transfer still completes, it just completes
       without this proof. */
    want_crc = json_find_u32(reply, "crc32", &has_crc);
    if (has_crc && want_crc != g_put.rx.crc) {
        /* Deleted, not kept: bytes that failed their own checksum are
           not a resume candidate, and keeping them would invite the
           same wrong file to be appended to forever. */
        now_log(kLogError, "put", "#%ld checksum failed: wanted %08lX, "
                "got %08lX, %ld bytes discarded", g_put.id, want_crc,
                g_put.rx.crc, g_put.rx.received);
        now_files_receive_discard(&g_put.rx);
        put_done(false, "corrupt", "the checksum did not match",
                 "temp-discarded");
        note_shot("Incoming file was corrupt");
        return;
    }
    /* One last report before the confirmation, so the far side sees the
       count reach the total rather than stopping at whatever the 32 KB
       cadence last happened to land on. Forced past the yield rule: it
       is a single frame and it is the one that closes the bar. */
    put_report_progress(true);
    rc = now_files_receive_finish(&g_put.rx);
    if (rc != kFilesOK) {
        put_done(false, rc == kFilesExists ? "exists" : "io-error",
                 rc == kFilesExists
                    ? "a file of that name appeared during the transfer"
                    : "could not finish writing the file",
                 "temp-discarded");
        note_shot("Incoming file failed");
        return;
    }
    now_log(kLogInfo, "put", "#%ld complete, %ld bytes%s", g_put.id,
            g_put.rx.received, has_crc ? ", checksum ok" : ", unchecked");
    put_done(true, NULL, NULL, "temp-renamed");
    snprintf(note, sizeof note, "Received %.31s",
             g_put.rx.final.name + 1);
    note_shot(note);
}

/* Answer a census.request for THIS machine's own share. Whoever receives
   the request serves it (contract: censusExchange); the guest is the one
   with the hardware worth asking about. One bounded page per request, so a
   probe never does more than a page of work and the wire never stalls. */
static void serve_census(const char *request)
{
    char probe[24];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 0);
    CensusPage page;
    char out[kNowMaxControl];
    long n;

    if (!now_json_find_string(request, "probe", probe, sizeof probe)) {
        strcpy(probe, "?");
    }
    if (now_census_gather(probe, cursor, &page) != 0) {
        /* Unknown probe: a well-formed refusal, never a protocol error. */
        page.count = 0;
        page.outcome = kCensusRefused;
        page.more = 0;
        page.next_cursor = 0;
        page.total = -1;
        snprintf(page.note, sizeof page.note, "unknown probe \"%.15s\"",
                 probe);
    }
    n = census_report_json(probe, id, &page, out, sizeof out);
    if (n < 0) {
        /* The page overran the frame - a paging bug, never truncate onto
           the wire. Answer a failed report so the asker learns cleanly. */
        page.count = 0;
        page.outcome = kCensusFailed;
        page.more = 0;
        page.total = -1;
        snprintf(page.note, sizeof page.note, "census page too large");
        n = census_report_json(probe, id, &page, out, sizeof out);
    }
    /* An unknown probe or an oversized page is a warn - the asker learned,
       but something went wrong. present/absent/partial are the machine
       answering honestly and log as info. */
    now_log(page.outcome == kCensusRefused || page.outcome == kCensusFailed
                ? kLogWarn : kLogInfo,
            "census", "#%ld %.15s: %s, %d rows%s", id, probe,
            census_outcome_name(page.outcome), page.count,
            page.more ? " (more)" : "");
    if (n > 0) {
        send_control(out);
    }
}

static void serve_file_list(const char *request)
{
    enum { kPage = 16 };              /* control frames cap at 4 KB */
    FileEntry entries[kPage];
    char path[224];
    char json[3584];
    char esc[200];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    Boolean more = false;
    short next = 1;
    int n, i;
    long pos;

    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);
    if (cursor < 1) {
        cursor = 1;
    }
    n = now_files_list(path, (short)cursor, entries, kPage, &more, &next);
    if (n < 0) {
        file_refuse_rc(id, n);
        return;
    }
    now_json_escape(path, esc, sizeof esc);
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"file.listing\",\"id\":%ld,"
                   "\"path\":\"%s\",\"entries\":[", id, esc);
    for (i = 0; i < n; ++i) {
        char type[8], creator[8];
        char esc_type[40], esc_creator[40];

        memcpy(type, &entries[i].file_type, 4);
        type[4] = '\0';
        memcpy(creator, &entries[i].creator, 4);
        creator[4] = '\0';
        now_json_escape(entries[i].name, esc, sizeof esc);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"kind\":\"%s\"",
                        i > 0 ? "," : "", esc,
                        entries[i].folder ? "folder" : "file");
        if (!entries[i].folder) {
            now_json_escape(type, esc_type, sizeof esc_type);
            now_json_escape(creator, esc_creator, sizeof esc_creator);
            pos += snprintf(json + pos, sizeof json - (size_t)pos,
                            ",\"fileType\":\"%s\",\"creator\":\"%s\","
                            "\"dataBytes\":%ld,\"rsrcBytes\":%ld",
                            esc_type, esc_creator, entries[i].data_bytes,
                            entries[i].rsrc_bytes);
        }
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        ",\"modified\":%lu,\"identity\":\"%s\"}",
                        entries[i].modified, entries[i].identity);
    }
    pos += snprintf(json + pos, sizeof json - (size_t)pos,
                    "],\"more\":%s,\"cursor\":%d",
                    more ? "true" : "false", (int)next);
    /* Only the root listing carries it: it names the place, and a
       subfolder listing already knows where it is. */
    if (path[0] == '\0') {
        char root[160];
        char esc_root[336];
        char field[352];
        long len;

        now_files_root_name(root, sizeof root);
        now_json_escape(root, esc_root, sizeof esc_root);
        len = snprintf(field, sizeof field, ",\"root\":\"%s\"", esc_root);
        /* A page of long names can leave no room. Dropping the label is
           harmless; half a label would truncate mid-string and cost the
           asker the whole listing. */
        if (len > 0 && pos + len + 2 < (long)sizeof json) {
            memcpy(json + pos, field, (size_t)len);
            pos += len;
        }
    }
    snprintf(json + pos, sizeof json - (size_t)pos, "}");
    send_control(json);
}

/* Serve process.list from this guest's OWN Process Manager - the guest's
   share of the symmetric process family (the host serves its own list
   the same way). Read-only; a process list is no more than the
   Application menu already shows. Paginates: cursor is a 1-based
   position among readable processes, more/cursor continue it. */
static void serve_process_list(const char *request)
{
    enum { kPage = 16 };              /* control frames cap at 4 KB */
    /* One entry's worst case (a 31-char name escaped, two 4CCs, three
       numbers) is ~240 bytes; keep this much free for it plus the tail so
       a row never truncates mid-JSON - a truncated frame decodes to
       nothing and the send silently does nothing. */
    enum { kEntryMargin = 320 };
    /* Spelled-out 4CCs: multi-character char constants warn under
       -Werror, and these classify the process's kind. */
    const unsigned long kTypeFinder = 0x464E4452UL;   /* 'FNDR' */
    const unsigned long kSigFinder = 0x4D414353UL;    /* 'MACS' */
    char json[kNowMaxControl];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber front;
    ProcessSerialNumber me;
    Boolean have_front = GetFrontProcess(&front) == noErr;
    /* isSelf marks the one row that is NOW - the only identity a caller
       can trust for "the process on the other end of this connection".
       serve_process_act already computes it to refuse a self-quit; this
       reports the same fact instead of only acting on it, so a caller can
       name this process without deriving a file name from a version
       string (contract: ProcessListing.isSelf). */
    Boolean have_self = GetCurrentProcess(&me) == noErr;
    long pos;
    long index = 0;                   /* readable-process position, 1-based */
    int emitted = 0;
    Boolean more = false;

    if (cursor < 1) {
        cursor = 1;
    }
    pos = snprintf(json, sizeof json,
                   "{\"type\":\"process.listing\",\"id\":%ld,"
                   "\"processes\":[", id);
    while (GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        char cname[32];
        char code[8], creator[8];
        char esc_name[64], esc_code[40], esc_creator[40];
        const char *kind;
        Boolean is_front = false;
        Boolean is_self = false;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;                 /* unreadable: not a position */
        }
        ++index;
        if (index < cursor) {
            continue;                 /* before this page */
        }
        if (emitted >= kPage
            || pos > (long)sizeof json - kEntryMargin) {
            more = true;              /* this one starts the next page */
            break;
        }
        memcpy(cname, name + 1, name[0]);
        cname[name[0]] = '\0';
        memcpy(code, &info.processType, 4);
        code[4] = '\0';
        memcpy(creator, &info.processSignature, 4);
        creator[4] = '\0';
        if ((unsigned long)info.processType == kTypeFinder
            || (unsigned long)info.processSignature == kSigFinder) {
            kind = "finder";
        } else if ((info.processMode & modeOnlyBackground) != 0) {
            kind = "background";
        } else {
            kind = "application";
        }
        if (have_front) {
            (void)SameProcess(&psn, &front, &is_front);
        }
        if (have_self) {
            (void)SameProcess(&psn, &me, &is_self);
        }
        now_json_escape(cname, esc_name, sizeof esc_name);
        now_json_escape(code, esc_code, sizeof esc_code);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        /* isSelf only when true: the contract makes it optional and
           absence means false, so 24 rows do not each pay 15 bytes of a
           frame whose page size is derived from its size. */
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"kind\":\"%s\",\"code\":\"%s\","
                        "\"creator\":\"%s\",\"sizeKB\":%ld,\"front\":%s,"
                        "\"psnHigh\":%lu,\"psnLow\":%lu%s}",
                        emitted > 0 ? "," : "", esc_name, kind, esc_code,
                        esc_creator, (long)(info.processSize / 1024),
                        is_front ? "true" : "false",
                        (unsigned long)psn.highLongOfPSN,
                        (unsigned long)psn.lowLongOfPSN,
                        is_self ? ",\"isSelf\":true" : "");
        ++emitted;
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "],\"more\":%s,\"cursor\":%ld}", more ? "true" : "false",
             cursor + emitted);
    /* One line per refresh, not per page: a refresh that pages is still one
       event, and a list is read often enough that per-page logging would be
       the heartbeat the log is meant to avoid. The first page (cursor 1)
       stands for the whole walk. */
    if (cursor == 1) {
        now_log(kLogInfo, "proc", "#%ld listed %d processes%s", id, emitted,
                more ? " (more)" : "");
    }
    send_control(json);
}

/* Serve software.list from this guest's installed-software cache — the
   wire's paged reading of the same data layer the sw command flattens.
   Cursor 1 (re)builds the cache; for "apps" that is the whole blocking
   sweep, ~4 s on the real machine, which the asker's watchdog must
   outlive (the host allows 15 s). Entries carry the full path because
   the path is the launch key: the host launches by path, so the
   name-ambiguity refusal can never fire from a listing. */
static void serve_software_list(const char *request)
{
    enum { kPage = 10 };              /* paths are long; frames cap at 4 KB */
    /* Worst case per entry: a 31-char name and a 223-char path, both
       escaped (6x), plus the fixed fields and a version — call it 1750
       bytes. The margin below is what must remain BEFORE starting an
       entry, so a worst-case row plus the tail still fits. */
    enum { kEntryMargin = 1900 };
    char json[kNowMaxControl];
    SoftwareEntry entries[kPage];
    char domain[16];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    Boolean more = false;
    Boolean truncated = false;
    long pos;
    int n, i;
    int emitted = 0;

    domain[0] = '\0';
    if (!now_json_find_string(request, "domain", domain, sizeof domain)
        || domain[0] == '\0') {
        strcpy(domain, "apps");
    }
    if (cursor < 1) {
        cursor = 1;
    }
    n = now_software_page(domain, cursor, entries, kPage, &more,
                          &truncated);
    if (n < 0) {
        char esc[40];

        now_json_escape(domain, esc, sizeof esc);
        now_log(kLogWarn, "sw", "#%ld software.list refused: no domain "
                "%.15s", id, domain);
        pos = snprintf(json, sizeof json,
                       "{\"type\":\"software.listing\",\"id\":%ld,"
                       "\"domain\":\"%s\",\"entries\":[],\"more\":false,"
                       "\"note\":\"no such domain\"}", id, esc);
        send_control(json);
        return;
    }

    {
        char esc_domain[40];

        now_json_escape(domain, esc_domain, sizeof esc_domain);
        pos = snprintf(json, sizeof json,
                       "{\"type\":\"software.listing\",\"id\":%ld,"
                       "\"domain\":\"%s\",\"entries\":[", id, esc_domain);
    }
    for (i = 0; i < n; ++i) {
        char esc_name[400], esc_path[1400], esc_type[40], esc_creator[40];

        if (pos > (long)sizeof json - kEntryMargin) {
            more = true;              /* this one starts the next page */
            break;
        }
        now_json_escape(entries[i].name, esc_name, sizeof esc_name);
        now_json_escape(entries[i].path, esc_path, sizeof esc_path);
        now_json_escape(entries[i].type, esc_type, sizeof esc_type);
        now_json_escape(entries[i].creator, esc_creator,
                        sizeof esc_creator);
        pos += snprintf(json + pos, sizeof json - (size_t)pos,
                        "%s{\"name\":\"%s\",\"path\":\"%s\","
                        "\"type\":\"%s\",\"creator\":\"%s\","
                        "\"sizeK\":%ld,\"off\":%s,\"running\":%s",
                        emitted > 0 ? "," : "", esc_name, esc_path,
                        esc_type, esc_creator, entries[i].size_k,
                        entries[i].off ? "true" : "false",
                        entries[i].running ? "true" : "false");
        /* Optional on the wire: absence means "no readable 'vers'",
           which the schema spells out. */
        if (entries[i].version[0] != '\0') {
            char esc_ver[100];

            now_json_escape(entries[i].version, esc_ver, sizeof esc_ver);
            pos += snprintf(json + pos, sizeof json - (size_t)pos,
                            ",\"version\":\"%s\"", esc_ver);
        }
        pos += snprintf(json + pos, sizeof json - (size_t)pos, "}");
        ++emitted;
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "],\"more\":%s,\"cursor\":%ld%s}",
             more ? "true" : "false", cursor + emitted,
             truncated ? ",\"note\":\"inventory truncated at cache\"" : "");
    /* Cursor 1 stands for the whole refresh, the process.list rule —
       and for "apps" it is also the line that says the sweep ran. */
    if (cursor == 1) {
        now_log(kLogInfo, "sw", "#%ld software.list %.15s: %d served%s%s",
                id, domain, emitted, more ? " (more)" : "",
                truncated ? " (truncated)" : "");
    }
    send_control(json);
}

/* A drive verb: bring a process to front, or ask it to quit. The target
   is the PSN the host echoed from a listing; because that listing may be
   seconds stale, the PSN is re-validated against a live process first and
   a dead one fails closed rather than driving whatever now holds that
   serial. Both verbs answer with the one process.result shape. */
static void serve_process_act(const char *request, Boolean quit)
{
    char json[192];
    long id = now_json_find_int(request, "id", 0);
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;
    OSErr err = noErr;
    const char *reason = NULL;

    psn.highLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnHigh", 0);
    psn.lowLongOfPSN =
        (unsigned long)now_json_find_int(request, "psnLow", 0);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) != noErr) {
        reason = "that process is no longer running";
    } else if (quit) {
        ProcessSerialNumber self;
        Boolean is_self = false;
        /* Quitting NOW itself over the wire would sever the connection
           mid-reply - refuse it here, where the current PSN is known,
           rather than trusting the far end never to ask. */
        if (GetCurrentProcess(&self) == noErr) {
            (void)SameProcess(&psn, &self, &is_self);
        }
        if (is_self) {
            reason = "NOW will not ask itself to quit";
        } else {
            err = now_proc_ask_quit(&psn);
            if (err != noErr) {
                reason = "the Mac would not deliver the quit request";
            }
        }
    } else {
        err = now_proc_bring_to_front(&psn);
        if (err != noErr) {
            reason = "the Mac would not bring it to the front";
        }
    }

    /* A drive verb changes the machine's state, and its refusal reason
       lives nowhere else once the reply is off the wire - the log is where
       "asked Finder to quit, it declined" survives the window closing. */
    {
        char cname[32];
        const char *verb = quit ? "quit" : "front";

        if (name[0] > 0) {
            memcpy(cname, name + 1, name[0]);
            cname[name[0]] = '\0';
        } else {
            strcpy(cname, "?");
        }
        if (reason == NULL) {
            now_log(kLogInfo, "proc", "#%ld %s %.31s", id, verb, cname);
        } else {
            now_log(kLogWarn, "proc", "#%ld %s refused: %.60s",
                    id, verb, reason);
        }
    }

    if (reason == NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"process.result\",\"id\":%ld,\"ok\":true}", id);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"process.result\",\"id\":%ld,\"ok\":false,"
                 "\"reason\":\"%s\"}", id, reason);
    }
    send_control(json);
}

static void serve_file_get(const char *request)
{
    NowPrefs prefs;
    FileStage stage;
    char path[224];
    char container_arg[16];
    char json[512];
    long id = now_json_find_int(request, "id", 0);
    FileContainer want = kContainerAuto;
    long chunk;
    short pace_ms;
    Boolean pack_unused;
    unsigned short xfer;
    int rc;

    if (wire_busy()) {
        file_refuse(id, "busy", "a transfer is already in flight");
        return;
    }
    path[0] = '\0';
    now_json_find_text(request, "path", path, sizeof path);

    /* Resuming a PULL is not offered yet: the guest does not compute a
       token for its own files, so it can never prove the file it would
       send is the one the partial came from. The contract's answer for
       a token it cannot match is `changed`, and refusing costs a
       restart where the alternative is silent corruption — a whole file
       sent to a host expecting only the tail gets appended to the
       partial it already holds. */
    if (now_json_find_int(request, "offset", 0) > 0) {
        file_refuse(id, "changed",
                    "this Mac cannot prove the file is unchanged; "
                    "ask for it from the beginning");
        return;
    }
    if (now_json_find_string(request, "container", container_arg,
                             sizeof container_arg)) {
        if (strcmp(container_arg, "macbinary") == 0) {
            want = kContainerMacBinary;
        } else if (strcmp(container_arg, "data") == 0) {
            want = kContainerData;
        }
    }
    rc = now_files_stage(path, want, &stage);
    if (rc != kFilesOK) {
        file_refuse_rc(id, rc);
        return;
    }

    now_prefs_load(&prefs);
    tuning_from_json(request, &prefs, &chunk, &pace_ms, &pack_unused);
    xfer = next_xfer();
    {
        char type[8], creator[8];

        memcpy(type, &stage.file_type, 4);
        type[4] = '\0';
        memcpy(creator, &stage.creator, 4);
        creator[4] = '\0';
        char esc_name[200], esc_type[40], esc_creator[40];

        now_json_escape(stage.name, esc_name, sizeof esc_name);
        now_json_escape(type, esc_type, sizeof esc_type);
        now_json_escape(creator, esc_creator, sizeof esc_creator);
        snprintf(json, sizeof json,
                 "{\"type\":\"file.begin\",\"id\":%ld,\"transfer\":%u,"
                 "\"name\":\"%s\",\"container\":\"%s\","
                 "\"bytes\":%ld,\"dataBytes\":%ld,\"rsrcBytes\":%ld,"
                 "\"fileType\":\"%s\",\"creator\":\"%s\","
                 "\"modified\":%lu}",
                 id, xfer, esc_name,
                 stage.container == kContainerMacBinary ? "macbinary" : "data",
                 stage.total_bytes, stage.data_bytes, stage.rsrc_bytes,
                 esc_type, esc_creator, stage.modified);
    }
    if (!send_control(json)) {
        now_files_stage_dispose(&stage);
        return;
    }
    if (!arm_file_transfer(id, xfer, &stage, chunk, pace_ms)) {
        now_files_stage_dispose(&stage);
        file_start_failed(id, xfer);
        return;
    }
}

/* --- live stream ------------------------------------------------------- */

static void stream_pipeline_clear(void)
{
    if (g_stream.cap_active) {
        banded_capture_abort(&g_stream.cap);
        g_stream.cap_active = false;
    }
    if (g_stream.ready) {
        now_pixels_dispose(&g_stream.ready_blob);
        g_stream.ready = false;
    }
    if (g_stream.prev != NULL) {
        DisposePtr(g_stream.prev);
        g_stream.prev = NULL;
    }
}

static void stream_drop(void)
{
    stream_pipeline_clear();
    g_stream.active = false;
    g_stream.stopping = false;
    g_streamreq.pending = false;
}

static void stream_send_stopped(long id, const char *reason)
{
    char json[192];

    if (reason != NULL) {
        snprintf(json, sizeof json,
                 "{\"type\":\"stream.stopped\",\"id\":%ld,"
                 "\"reason\":\"%s\"}", id, reason);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"stream.stopped\",\"id\":%ld}", id);
    }
    send_control(json);
}

static void stream_end(const char *reason)
{
    if (!g_stream.active) {
        return;
    }
    stream_pipeline_clear();
    g_stream.active = false;
    g_stream.stopping = false;
    stream_send_stopped(g_stream.id, reason);
    note_shot("Streaming stopped");
}

/* The frame pump's floor, in ticks between frames.

   minIntervalMs keeps its contract meaning - a MINIMUM interval, the host's
   ceiling on frame rate - but "absent" no longer means "as fast as the wire
   allows". That was only ever a pace because every frame carried bulk
   pixels: an empty frame is a ~150-byte control pair that touches no
   transfer lane at all, so on a static screen with predictive capture on,
   nothing throttled the loop and the guest flooded the wire with thousands
   of control frames a second. Capture on this hardware tops out near 7 fps,
   so a default of ~15 fps is headroom, not a limit. */
enum {
    kStreamDefaultIntervalTicks = 4,  /* ~15 fps when the host says nothing */
    kStreamIdleIntervalTicks = 15     /* ~4 fps once the screen goes still */
};

static long stream_interval_ticks(long min_interval_ms)
{
    long ticks;

    if (min_interval_ms <= 0) {
        return kStreamDefaultIntervalTicks;
    }
    /* Round up: any interval the host asks for is a floor, and truncating
       10 ms to 0 ticks would hand back the unbounded loop. */
    ticks = (min_interval_ms * 60 + 999) / 1000;
    return ticks > 0 ? ticks : 1;
}

static void stream_start(const char *reply)
{
    NowPrefs prefs;
    long depth_arg;
    long id = now_json_find_int(reply, "id", 0);

    if (wire_busy()) {
        stream_send_stopped(id, "busy: a transfer is in flight");
        return;
    }
    now_prefs_load(&prefs);
    depth_arg = now_json_find_int(reply, "depth", 0);

    memset(&g_stream, 0, sizeof g_stream);
    g_stream.id = id;
    g_stream.depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    tuning_from_json(reply, &prefs, &g_stream.chunk, &g_stream.pace_ms,
                     &g_stream.pack);
    g_stream.predictive =
        json_find_flag(reply, "predictive", prefs.predictive) != 0;
    g_stream.interlace =
        json_find_flag(reply, "interlace", prefs.interlace) != 0;
    g_stream.min_interval_ticks =
        stream_interval_ticks(now_json_find_int(reply, "minIntervalMs", 0));
    g_stream.next_frame_tick = 0;
    g_stream.est_cap_ticks = 10;      /* ~165 ms until measured */
    g_stream.est_send_ticks = 0;      /* first capture starts at once */
    g_stream.force_key = true;        /* frame one is always whole */
    g_stream.active = true;
    g_streamreq.pending = false;
    {
        char peer[24];
        char line[64];

        conn_peer_label(peer, sizeof peer);
        snprintf(line, sizeof line, "Streaming to %.20s...", peer);
        note_shot(line);
    }
}

static void stream_stop(const char *reply)
{
    long id = now_json_find_int(reply, "id", -1);

    if (!g_stream.active || id != g_stream.id) {
        /* Answer anyway: if the guest lost the stream (reconnect, abort
           whose stream.stopped died with the old socket), an unanswered
           stop would wedge the host's bracket open forever. */
        stream_send_stopped(id, NULL);
        return;
    }
    if (g_xfer.active) {
        xfer_abort();
        if (g_xfer.active) {
            g_stream.stopping = true; /* stream.stopped follows the drain */
            return;
        }
    }
    stream_end(NULL);
}

/* Guest-initiated streaming: the guest can only ASK - the bracket stays
   host-owned (stream.start is the host's word), so both origins share one
   code path and one policy. The host answers stream.start or an error. */

int now_wire_stream_request(char *err, long cap)
{
    NowPrefs prefs;
    char json[96];

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected");
        return -1;
    }
    if (g_stream.active) {
        snprintf(err, (size_t)cap, "Already streaming");
        return -1;
    }
    if (g_xfer.active || g_offer.active || g_streamreq.pending) {
        snprintf(err, (size_t)cap, "A transfer is already in flight");
        return -1;
    }
    now_prefs_load(&prefs);
    snprintf(json, sizeof json,
             "{\"type\":\"stream.request\",\"depth\":%d}",
             (int)prefs.shot_depth);
    if (!send_control(json)) {
        snprintf(err, (size_t)cap, "Connection lost");
        return -1;
    }
    g_streamreq.pending = true;
    g_streamreq.deadline = TickCount() + kStreamReqTimeoutTicks;
    {
        char peer[40];
        char asked[96];

        conn_peer_label(peer, sizeof peer);
        snprintf(asked, sizeof asked, "Asked %s to stream...", peer);
        note_shot(asked);
    }
    return 0;
}

Boolean now_wire_stream_active(void)
{
    return g_stream.active;
}

long now_wire_stream_interval_ms(void)
{
    if (!g_stream.active) {
        return -1;
    }
    /* Ticks back to ms; the rounding-up at arrival means this can read
       a hair over what the host asked, which is the honest direction. */
    return g_stream.min_interval_ticks * 1000L / 60L;
}

/* The panel's Stop: guest ends its own bracket - stream.stopped without a
   reason reads as a clean stop on the host. */
void now_wire_stream_stop(void)
{
    if (!g_stream.active) {
        return;
    }
    if (g_xfer.active) {
        xfer_abort();
        if (g_xfer.active) {
            g_stream.stopping = true; /* stream.stopped follows the drain */
            return;
        }
    }
    stream_end(NULL);
}

enum { kStreamBands = 8 };            /* ~17 ms per event-loop bite */

/* When a send starts, aim the next capture to finish as the send does. */
static void stream_schedule_capture(void)
{
    long lead = g_stream.est_send_ticks - g_stream.est_cap_ticks;

    if (lead < 0) {
        lead = 0;
    }
    g_stream.cap_start_tick = TickCount() + (unsigned long)lead;
}

/* Abandons the frame in hand and makes the next capture a whole-screen
   keyframe. The escape hatch for the one case the exporter cannot serve:
   a key is the only correct frame, but what was captured is a field. */
static void stream_drop_frame(CaptureImage *image, unsigned long began)
{
    capture_image_dispose(image);
    g_stream.ready = false;
    g_stream.force_key = true;        /* next capture reads everything */
    g_stream.n_dirty_hist = 0;
    g_stream.sweep_pos = 0;
    g_stream.est_cap_ticks = (long)(TickCount() - began);
}

/* Finishes a completed banded capture: diff, then export + encode the
   right kind of frame, so it is ready the instant the lane frees.

   Two shapes meet here and must not be confused. The CANVAS is what the
   host paints - full screen height, and what the delta base (prev) always
   holds. The IMAGE is what this capture read: the same height at row_scale
   1, but HALF of it when interlace decimated 2:1 into a half-height
   GWorld. A delta carries rowStep so the host maps field rows back onto
   the canvas; a keyframe carries no such mapping - it replaces the host's
   canvas wholesale. So: a field capture may only ever leave here as a
   delta. Exporting one as a key is what made the host resize its canvas to
   half height and stay there. */
static void stream_finish_capture(unsigned long began)
{
    CaptureImage image = g_stream.cap.image;
    CaptureSpan cap_spans[kCaptureMaxBands];
    short n_cap_spans = g_stream.cap.n_spans;
    unsigned char palette[768];
    long palette_bytes;
    long height, canvas_height, canvas_bytes;
    short scale = g_stream.cap_scale > 1 ? g_stream.cap_scale : 1;
    Boolean field = scale > 1;
    int rc;

    memcpy(cap_spans, g_stream.cap.spans, sizeof cap_spans);
    memset(&g_stream.cap, 0, sizeof g_stream.cap);
    g_stream.cap_active = false;

    memset(&g_stream.ready_meta, 0, sizeof g_stream.ready_meta);
    g_stream.ready_meta.width =
        (short)(image.bounds.right - image.bounds.left);
    g_stream.ready_meta.height =
        (short)(image.bounds.bottom - image.bounds.top);
    g_stream.ready_meta.depth = image.depth;
    g_stream.ready_meta.row_bytes = image.row_bytes;
    g_stream.ready_meta.capture_ms =
        (long)((TickCount() - began) * 1000 / 60);
    height = g_stream.ready_meta.height;
    /* A field holds every other canvas row, so the canvas it diffs against
       is the one prev already describes - not this image's height. Sizing
       the base off the image instead was the second half of the half-screen
       bug: a field capture looked like a shape change, which threw the
       canvas-sized base away and re-made it half height. */
    canvas_height = field ? g_stream.prev_height : height;
    canvas_bytes = (long)image.row_bytes * canvas_height;
    if (field && (g_stream.prev == NULL || canvas_height <= 0)) {
        stream_drop_frame(&image, began);   /* no canvas to patch into */
        return;
    }

    /* A palette change invalidates every delta; so does a base buffer of
       the wrong shape (depth cannot change mid-stream, but composite
       garbage is the worst failure mode - be safe). */
    palette_bytes = now_pixels_palette(&image, palette, sizeof palette);
    if (g_stream.prev != NULL
        && (g_stream.prev_bytes != canvas_bytes
            || g_stream.prev_row_bytes != image.row_bytes
            || g_stream.prev_height != (short)canvas_height
            || palette_bytes != g_stream.prev_palette_bytes
            || memcmp(palette, g_stream.prev_palette,
                      (size_t)palette_bytes) != 0)) {
        g_stream.force_key = true;
        if (g_stream.prev_bytes != canvas_bytes) {
            DisposePtr(g_stream.prev);
            g_stream.prev = NULL;
        }
    }
    /* Whatever invalidated the base, only a whole-screen capture can
       rebuild it. */
    if (field && g_stream.force_key) {
        stream_drop_frame(&image, began);
        return;
    }
    if (g_stream.prev == NULL) {
        g_stream.prev = NewPtr(canvas_bytes);
        if (g_stream.prev == NULL) {
            capture_image_dispose(&image);
            stream_end("capture failed");
            return;
        }
        g_stream.prev_bytes = canvas_bytes;
        g_stream.prev_row_bytes = image.row_bytes;
        g_stream.prev_height = (short)canvas_height;
        g_stream.force_key = true;
    }

    memset(&g_stream.ready_blob, 0, sizeof g_stream.ready_blob);
    if (!g_stream.force_key) {
        long dirty_rows = 0;
        Boolean overflow = false;
        short n = now_pixels_diff(&image, g_stream.prev,
                                  g_stream.cap_full ? NULL : cap_spans,
                                  g_stream.cap_full ? 0 : n_cap_spans,
                                  scale, g_stream.cap_phase,
                                  g_stream.ready_meta.rects,
                                  kPixelMaxRects, &dirty_rows, &overflow);

        if (n < 0) {
            g_stream.force_key = true;
        } else if (overflow) {
            /* Too fragmented to describe: send every captured span whole.
               Correct (all captured), merely coarse. */
            short i;

            n = n_cap_spans;
            for (i = 0; i < n; ++i) {
                g_stream.ready_meta.rects[i].row = cap_spans[i].row;
                g_stream.ready_meta.rects[i].n_rows =
                    cap_spans[i].n_rows;
                g_stream.ready_meta.rects[i].col_off = 0;
                g_stream.ready_meta.rects[i].col_bytes = image.row_bytes;
            }
            g_stream.ready_meta.kind = kFrameDelta;
        } else if (n == 0) {
            g_stream.ready_meta.kind = kFrameEmpty;
        } else if (g_stream.cap_full && !field
                   && dirty_rows * 10 > height * 7) {
            g_stream.force_key = true;   /* mostly new screen: send whole */
        } else {
            g_stream.ready_meta.kind = kFrameDelta;
            g_stream.ready_meta.n_rects = n;
        }
        if (g_stream.ready_meta.kind == kFrameDelta && !g_stream.force_key) {
            short i;

            if (overflow) {
                g_stream.ready_meta.n_rects = n;
            }
            g_stream.ready_meta.row_scale = scale;
            g_stream.ready_meta.row_phase = g_stream.cap_phase;
            /* Remember where the dirt was, in canvas rows, for the next
               frame's prediction. */
            g_stream.n_dirty_hist = g_stream.ready_meta.n_rects;
            for (i = 0; i < g_stream.n_dirty_hist; ++i) {
                g_stream.dirty_hist[i].row = (short)
                    ((long)g_stream.ready_meta.rects[i].row * scale
                     + g_stream.cap_phase);
                g_stream.dirty_hist[i].n_rows = (short)
                    ((long)(g_stream.ready_meta.rects[i].n_rows - 1) * scale
                     + 1);
            }
            rc = now_pixels_export_rects(&image, g_stream.pack,
                                         g_stream.ready_meta.rects,
                                         g_stream.ready_meta.n_rects,
                                         &g_stream.ready_blob);
            if (rc != 0) {
                capture_image_dispose(&image);
                stream_end("capture failed");
                return;
            }
        }
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            g_stream.n_dirty_hist = 0;
        }
        if (g_stream.interlace) {
            g_stream.phase = (short)(g_stream.phase ^ 1);
        }
    }
    /* The invariant, stated once and enforced here: only a whole-screen,
       full-scale capture may leave as a keyframe. force_key is set at plan
       time for a real key (and stream_begin_capture then reads everything),
       but the diff can also raise it AFTER the capture is in hand - and by
       then the capture may be a field. Drop that frame rather than export a
       half-height image as a key; the next capture is whole. */
    if (g_stream.force_key && (field || !g_stream.cap_full)) {
        stream_drop_frame(&image, began);
        return;
    }
    if (g_stream.force_key) {
        g_stream.ready_meta.kind = kFrameKey;
        g_stream.ready_meta.n_rects = 0;
        g_stream.ready_meta.row_scale = 1;
        g_stream.ready_meta.row_phase = 0;
        g_stream.n_dirty_hist = 0;
        g_stream.sweep_pos = 0;
        rc = now_pixels_export(&image, g_stream.pack, &g_stream.ready_blob);
        if (rc != 0 || now_pixels_copy_raw(&image, g_stream.prev) != 0) {
            capture_image_dispose(&image);
            stream_end("capture failed");
            return;
        }
        memcpy(g_stream.prev_palette, palette, (size_t)palette_bytes);
        g_stream.prev_palette_bytes = palette_bytes;
        g_stream.force_key = false;
    }
    capture_image_dispose(&image);
    g_stream.ready = true;
    g_stream.est_cap_ticks = (long)(TickCount() - began);
}

/* An empty frame skips the bulk plane entirely: begin and end go out as
   a control pair (~150 bytes), keeping fps honest on a static screen. */
static void stream_send_empty_frame(void)
{
    char json[256];
    unsigned short xfer = next_xfer();

    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":0,\"paletteBytes\":0,"
             "\"encoding\":\"raw\",\"captureMs\":%ld,"
             "\"frame\":\"empty\"}",
             g_stream.id, xfer, (int)g_stream.ready_meta.width,
             (int)g_stream.ready_meta.height,
             (int)g_stream.ready_meta.depth,
             (int)g_stream.ready_meta.row_bytes,
             g_stream.ready_meta.capture_ms);
    send_control(json);
    snprintf(json, sizeof json,
             "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":true,\"sendMs\":0}", g_stream.id, xfer);
    send_control(json);
}

enum {
    kPredictMarginRows = 8,           /* canvas rows around old dirt */
    kSweepFrames = 8,                 /* whole screen swept every N */
    kSpanMergeGap = 5                 /* keep spans mergeable-safe apart */
};

/* Adds a canvas row range to a span list (canvas coords), merging spans
   closer than kSpanMergeGap so the diff's run-merging never straddles an
   uncaptured gap. */
static short span_add(CaptureSpan *spans, short count, long top,
                      long bottom, long limit)
{
    short i;

    if (top < 0) {
        top = 0;
    }
    if (bottom > limit) {
        bottom = limit;
    }
    if (top >= bottom) {
        return count;
    }
    for (i = 0; i < count; ++i) {
        long s_top = spans[i].row;
        long s_bot = spans[i].row + spans[i].n_rows;

        if (top <= s_bot + kSpanMergeGap && bottom + kSpanMergeGap >= s_top) {
            if (top < s_top) {
                s_top = top;
            }
            if (bottom > s_bot) {
                s_bot = bottom;
            }
            spans[i].row = (short)s_top;
            spans[i].n_rows = (short)(s_bot - s_top);
            return count;
        }
    }
    if (count < kCaptureMaxBands) {
        spans[count].row = (short)top;
        spans[count].n_rows = (short)(bottom - top);
        ++count;
    } else {
        /* Out of spans: widen the first to cover everything. Coarse but
           correct - it only ever costs read time. */
        long s_bot = spans[0].row + spans[0].n_rows;

        if (top < spans[0].row) {
            spans[0].row = (short)top;
        }
        if (bottom > s_bot) {
            s_bot = bottom;
        }
        spans[0].n_rows = (short)(s_bot - spans[0].row);
    }
    return count;
}

/* Chooses what the next capture reads and starts it. Keyframes read the
   whole screen at full scale; otherwise the interlace toggle picks the
   field and the predictive toggle narrows the rows. */
static int stream_begin_capture(void)
{
    CaptureSpan canvas[kCaptureMaxBands];
    CaptureSpan dst[kCaptureMaxBands];
    short n = 0;
    short scale = 1, phase = 0;
    long height = g_stream.prev_height > 0 ? g_stream.prev_height : 0x7FFF;
    short i;

    g_stream.cap_full = false;
    if (g_stream.force_key || g_stream.prev == NULL) {
        g_stream.cap_full = true;
        g_stream.cap_scale = 1;
        g_stream.cap_phase = 0;
        return banded_capture_begin(g_stream.depth, kStreamBands,
                                    &g_stream.cap) == kCaptureOK;
    }
    if (g_stream.interlace) {
        scale = 2;
        phase = g_stream.phase;
    }
    if (!g_stream.predictive) {
        n = span_add(canvas, 0, 0, height, height);
    } else {
        long slice = height / kSweepFrames + 1;

        for (i = 0; i < g_stream.n_dirty_hist; ++i) {
            n = span_add(canvas, n,
                         (long)g_stream.dirty_hist[i].row
                             - kPredictMarginRows,
                         (long)g_stream.dirty_hist[i].row
                             + g_stream.dirty_hist[i].n_rows
                             + kPredictMarginRows, height);
        }
        n = span_add(canvas, n, g_stream.sweep_pos,
                     g_stream.sweep_pos + slice, height);
        g_stream.sweep_pos += slice;
        if (g_stream.sweep_pos >= height) {
            g_stream.sweep_pos = 0;
        }
        if (n == 0) {
            n = span_add(canvas, 0, 0, height, height);
        }
    }
    /* Canvas rows -> destination (field) rows. */
    for (i = 0; i < n; ++i) {
        long top = canvas[i].row;
        long bottom = top + canvas[i].n_rows;
        long d_top = (top - phase + scale - 1) / scale;
        long d_bot = (bottom - phase + scale - 1) / scale;
        long d_limit = (height - phase + scale - 1) / scale;

        if (d_top < 0) {
            d_top = 0;
        }
        if (d_bot > d_limit) {
            d_bot = d_limit;
        }
        if (d_top >= d_limit) {
            d_top = d_limit - 1;
        }
        if (d_bot <= d_top) {
            d_bot = d_top + 1;
        }
        dst[i].row = (short)d_top;
        dst[i].n_rows = (short)(d_bot - d_top);
    }
    g_stream.cap_scale = scale;
    g_stream.cap_phase = phase;
    return banded_capture_begin_spans(g_stream.depth, dst, n, scale, phase,
                                      &g_stream.cap) == kCaptureOK;
}

/* The pipelined frame pump: while frame N sends, frame N+1 is captured a
   band at a time; when both halves are done the frame arms immediately. */
static void service_stream(void)
{
    static unsigned long cap_began;

    if (g_streamreq.pending && TickCount() > g_streamreq.deadline) {
        g_streamreq.pending = false;
        {
            char peer[40];
            char line[96];

            conn_peer_label(peer, sizeof peer);
            snprintf(line, sizeof line, "%s did not start streaming", peer);
            note_shot(line);
        }
    }
    if (!g_stream.active) {
        return;
    }
    if (g_stream.stopping) {
        if (!g_xfer.active) {
            g_stream.stopping = false;
            stream_end(NULL);
        }
        return;                       /* no new frames while stopping */
    }

    /* Arm a ready frame the moment the lane is free. */
    if (g_stream.ready && !g_xfer.active
        && TickCount() >= g_stream.next_frame_tick) {
        long interval = g_stream.min_interval_ticks;

        /* A still screen does not need fifteen updates a second. Back off
           after the second empty frame in a row; any real change snaps the
           pace back on the very next frame. The wait gates the capture too
           (a held frame stops the pump), so this bounds how stale the
           screen can get: a change is seen within one idle interval. */
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            ++g_stream.empty_run;
            if (g_stream.empty_run > 1
                && interval < kStreamIdleIntervalTicks) {
                interval = kStreamIdleIntervalTicks;
            }
        } else {
            g_stream.empty_run = 0;
        }
        g_stream.next_frame_tick = TickCount() + (unsigned long)interval;
        g_stream.ready = false;
        if (g_stream.ready_meta.kind == kFrameEmpty) {
            stream_send_empty_frame();
        } else if (!arm_transfer(g_stream.id, next_xfer(),
                                 &g_stream.ready_meta,
                                 &g_stream.ready_blob, g_stream.chunk,
                                 g_stream.pace_ms, false)) {
            stream_end("transfer failed");
            return;
        }
        ++g_stream.frames;
        stream_schedule_capture();
        return;
    }

    /* Pump the in-progress capture, a small slice per pass: at ~17 ms a
       band, per-pass loop overhead was costing ~1 fps at 1-bit. */
    if (g_stream.cap_active) {
        unsigned long slice_end = TickCount() + 2;
        int rc;

        do {
            rc = banded_capture_step(&g_stream.cap);
        } while (rc == kCaptureMoreBands && TickCount() < slice_end);
        if (rc == kCaptureOK) {
            stream_finish_capture(cap_began);
        } else if (rc != kCaptureMoreBands) {
            g_stream.cap_active = false;
            stream_end("capture failed");
        }
        return;
    }

    /* Begin the next capture once its scheduled moment arrives (or at
       once when nothing is in flight - the first frame, or an estimate
       that ran short). */
    if (!g_stream.ready
        && (!g_xfer.active || TickCount() >= g_stream.cap_start_tick)) {
        if (!stream_begin_capture()) {
            stream_end("capture failed");
            return;
        }
        g_stream.cap_active = true;
        cap_began = TickCount();
    }
}

/* Returns 0 if the connection should be torn down (bye/protocol error). */
static int handle_frame(const char *reply)
{
    if (reply[0] == '\0') {
        return 1;                    /* dropped non-control frame */
    }
    if (g.phase == kConnHandshaking) {
        if (now_json_type_is(reply, "hello")) {
            on_hello(reply);
            return 1;
        }
        if (now_json_type_is(reply, "refuse")) {
            char reason[96];
            if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
                snprintf(g.status, sizeof g.status, "Refused: %s", reason);
            } else {
                {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "Refused by %s", peer);
            }
            }
            return 0;
        }
        snprintf(g.status, sizeof g.status, "Unexpected reply");
        return 0;
    }
    /* connected */
    if (now_json_type_is(reply, "pong")) {
        g.pings_sent = 0;
        g.last_rtt_ms = (long)((TickCount() - g.ping_sent_tick) * 1000 / 60);
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s) - %ld ms",
                 g.peer_name, g.peer_version, g.last_rtt_ms);
        return 1;
    }
    if (now_json_type_is(reply, "capture.request")) {
        serve_capture(reply);
        return 1;
    }
    if (now_json_type_is(reply, "capture.cancel")) {
        xfer_abort();
        return 1;
    }
    if (now_json_type_is(reply, "file.list")) {
        serve_file_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "process.list")) {
        serve_process_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "software.list")) {
        serve_software_list(reply);
        return 1;
    }
    if (now_json_type_is(reply, "process.front")) {
        serve_process_act(reply, false);
        return 1;
    }
    if (now_json_type_is(reply, "process.quit")) {
        serve_process_act(reply, true);
        return 1;
    }
    if (now_json_type_is(reply, "process.shot")) {
        serve_process_shot(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.get")) {
        serve_file_get(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.cancel")) {
        if (g_put.active) {
            put_abort("cancelled", "the sender stopped");
            note_shot("Incoming file cancelled");
        } else {
            xfer_abort();
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.move")) {
        serve_file_move(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.trash")) {
        serve_file_trash(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.restore")) {
        serve_file_restore(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.mkdir")) {
        serve_file_mkdir(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.offer")) {
        serve_file_offer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.accept")) {
        send_accepted(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.listing")) {
        browse_listing(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.refuse")) {
        if (g_get.pending && now_json_find_int(reply, "id", -1) == g_get.id) {
            char reason[96];

            get_cleanup(false);
            if (!now_json_find_text(reply, "reason", reason, sizeof reason)) {
                strcpy(reason, "the other Mac refused");
            }
            get_note(reason);
        } else if (!browse_refused(reply)) {
            send_refused(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.progress")) {
        if (g_send.active
            && now_json_find_int(reply, "id", -1) == g_send.id) {
            long received = now_json_find_int(reply, "received", 0);

            if (received >= g_send.received && received <= g_send.total) {
                g_send.received = received;
                g_send.receiving_reports = true;
            }
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.done")) {
        send_done(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.begin")) {
        /* file.begin now announces two different things: a file we
           ASKED for, and one the other machine offered and we accepted.
           The pending pull decides, and only one can be live because
           the bulk lane is one transfer wide. */
        if (g_get.pending) {
            get_begin(reply);
        } else {
            put_begin(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "file.end")) {
        if (g_get.receiving) {
            get_end(reply);
        } else {
            finish_put(reply);
        }
        return 1;
    }
    if (now_json_type_is(reply, "stream.start")) {
        stream_start(reply);
        return 1;
    }
    if (now_json_type_is(reply, "stream.stop")) {
        stream_stop(reply);
        return 1;
    }
    if (now_json_type_is(reply, "stream.refresh")) {
        if (g_stream.active
            && now_json_find_int(reply, "id", -1) == g_stream.id) {
            g_stream.force_key = true;
        }
        return 1;
    }
    if (now_json_type_is(reply, "capture.accept")) {
        offer_accepted(reply);
        return 1;
    }
    if (now_json_type_is(reply, "capture.refuse")) {
        offer_refused(reply);
        return 1;
    }
    if (now_json_type_is(reply, "command.request")) {
        char name[48];
        char result[3072];
        long id = now_json_find_int(reply, "id", 0);

        if (!now_json_find_string(reply, "name", name, sizeof name)) {
            strcpy(name, "?");
        }
        now_command_run(name, reply, id, result, sizeof result);
        if (!send_control(result)) {
            fail("Connection lost");
            return 0;
        }
        return 1;
    }
    if (now_json_type_is(reply, "census.request")) {
        serve_census(reply);
        return 1;
    }
    if (now_json_type_is(reply, "error")) {
        if (g_streamreq.pending) {
            g_streamreq.pending = false;
            {
                char peer[40];
                char line[96];

                conn_peer_label(peer, sizeof peer);
                snprintf(line, sizeof line, "%s declined the stream", peer);
                note_shot(line);
            }
        }
        return 1;
    }
    if (now_json_type_is(reply, "bye")) {
        char reason[96];
        if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "%.39s disconnected: %.60s",
                         peer, reason);
            }
        } else {
            {
                char peer[40];

                conn_peer_label(peer, sizeof peer);
                snprintf(g.status, sizeof g.status, "%s disconnected", peer);
            }
        }
        return 0;
    }
    return 1;                        /* ignore anything else for now */
}

/* Read and drain in turns until nothing more is waiting, bounded by a
   slice so the app stays responsive. One read per event-loop pass was
   enough while everything inbound was a small control message; a file
   arriving needs far more than a bufferful per turn. */
enum { kIoSliceTicks = 3 };           /* ~50 ms */

static void service_connected_io(void)
{
    /* The contract caps a control frame at 4 KB, so the receiver has to
       be able to HOLD 4 KB. This was 1200 for as long as everything
       arriving was a pong or a request; the first listing off the wire
       overflowed it and took the connection down. A buffer smaller than
       the contract allows is a bug waiting for a big enough message. */
    char payload[kNowMaxControl + 4];
    unsigned long slice_end = TickCount() + kIoSliceTicks;
    int rc;

    for (;;) {
        long before = g.rx_len;
        long read_this_pass;

        if (!pump_rx()) {
            fail("Connection lost");
            return;
        }
        read_this_pass = g.rx_len - before;

        for (;;) {
            rc = next_frame(payload, sizeof payload);
            if (rc == 0) {
                break;
            }
            if (rc < 0) {
                fail("Protocol error");
                return;
            }
            if (!handle_frame(payload)) {
                /* Peer said goodbye or we rejected it: orderly release,
                   backoff. handle_frame set g.status to the specific
                   reason — keep it. */
                snprintf(g.last_fail, sizeof g.last_fail, "%s", g.status);
                gNowOT.sndOrderlyDisconnect(g.ep);
                enter_backoff();
                return;
            }
        }
        if (read_this_pass == 0 || TickCount() > slice_end) {
            return;
        }
    }
}

static void service_heartbeat(void)
{
    unsigned long now = TickCount();
    char ping[48];

    if (now - g.last_rx_tick > kDeadTicks) {
        fail("Reconnecting (no answer)");
        return;
    }
    if (now >= g.next_ping_tick) {
        ++g.ping_id;
        snprintf(ping, sizeof ping, "{\"type\":\"ping\",\"id\":%ld}",
                 g.ping_id);
        g.ping_sent_tick = now;
        if (!send_control(ping)) {
            fail("Connection lost");
            return;
        }
        ++g.pings_sent;
        g.next_ping_tick = now + kPingIntervalTicks;
    }
}

/* --- public API --------------------------------------------------------- */

void conn_init(void)
{
    NowPrefs prefs;

    memset(&g, 0, sizeof g);
    g.ep = kOTInvalidEndpointRef;
    g.last_rtt_ms = -1;
    now_prefs_load(&prefs);
    strncpy(g.host, prefs.host, sizeof g.host - 1);
    g.port = prefs.port;
    strcpy(g.status, "Not connected");
    /* The Connection page's "Connect when New Old World opens". Off
       means the target is loaded but nothing dials until asked. */
    if (prefs.auto_connect) {
        g.want_connection = true;
        start_connect();
    }
}

void conn_shutdown(void)
{
    if (g.ep != kOTInvalidEndpointRef) {
        if (g.phase == kConnConnected) {
            unsigned long flush_deadline = TickCount() + 60;

            send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
            while (g_ctlq.count > 0 && TickCount() < flush_deadline) {
                if (!service_ctl_tx()) {
                    break;
                }
            }
        }
        gNowOT.sndOrderlyDisconnect(g.ep);
        ctlq_clear();
        close_endpoint();
    }
    g.want_connection = false;
    g.phase = kConnIdle;
    if (g_connect_notifier != NULL) {
        DisposeOTNotifyUPP(g_connect_notifier);
        g_connect_notifier = NULL;
    }
}

void now_wire_pump(void)
{
    static Boolean pumping = false;

    if (pumping) {
        return;
    }
    pumping = true;
    conn_service();
    pumping = false;
}

void conn_service(void)
{
    ++g_service_passes;
    switch (g.phase) {
    case kConnConnecting:
        service_connecting();
        break;
    case kConnHandshaking:
        if (!service_ctl_tx()) {
            fail("Connection lost");
            break;
        }
        service_connected_io();
        if (g.phase == kConnHandshaking && TickCount() > g.phase_deadline) {
            fail("No hello reply (8s)");
        }
        break;
    case kConnConnected:
        if (!service_ctl_tx()) {
            fail("Connection lost");
            break;
        }
        service_connected_io();
        if (g.phase == kConnConnected) {
            service_offer();
    service_send();
    service_browse();
    service_get();
        }
        if (g.phase == kConnConnected) {
            service_stream();
        }
        if (g.phase == kConnConnected) {
            service_shot();
        }
        if (g.phase == kConnConnected) {
            service_transfer();
        }
        if (g.phase == kConnConnected) {
            service_heartbeat();
        }
        break;
    case kConnBackoff:
        if (TickCount() >= g.backoff_until) {
            start_connect();
        } else {
            unsigned long remain =
                (g.backoff_until - TickCount() + 59) / 60;
            if (g.last_fail[0] != '\0') {
                snprintf(g.status, sizeof g.status,
                         "%.100s - retry in %lus", g.last_fail, remain);
            } else {
                snprintf(g.status, sizeof g.status,
                         "Reconnecting in %lus...", remain);
            }
        }
        break;
    default:
        break;
    }
}

void conn_set_target(const char *host, unsigned short port)
{
    strncpy(g.host, host, sizeof g.host - 1);
    g.host[sizeof g.host - 1] = '\0';
    g.port = port;
    g.want_connection = true;
    g.backoff_ticks = 0;
    g.last_rtt_ms = -1;
    start_connect();
}

void conn_disconnect(void)
{
    if (g.ep != kOTInvalidEndpointRef && g.phase == kConnConnected) {
        unsigned long flush_deadline = TickCount() + 60;

        send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
        while (g_ctlq.count > 0 && TickCount() < flush_deadline) {
            if (!service_ctl_tx()) {
                break;
            }
        }
        gNowOT.sndOrderlyDisconnect(g.ep);
    }
    ctlq_clear();
    close_endpoint();
    g.want_connection = false;
    g.phase = kConnIdle;
    strcpy(g.status, "Not connected");
}

void conn_connect_now(void)
{
    g.want_connection = true;
    g.backoff_ticks = 0;
    start_connect();
}

long conn_rcv_window(void)
{
    return g_rcv_window;
}

long conn_rcv_peak(void)
{
    return g_rcv_peak;
}

long conn_service_passes(void)
{
    return g_service_passes;
}

void conn_peer_label(char *out, long cap)
{
    if (g.peer_name[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g.peer_name);
    } else {
        snprintf(out, (size_t)cap, "the other Mac");
    }
}

ConnPhase conn_phase(void)
{
    return g.phase;
}

Boolean conn_wants_fast_pump(void)
{
    return g_xfer.active || g_stream.active || g_offer.active
        || g_put.active || g_ctlq.count > 0;
}

Boolean conn_is_connected(void)
{
    return g.phase == kConnConnected;
}

void conn_status(char *out, long cap)
{
    snprintf(out, cap, "%s", g.status);
}

void conn_snapshot(ConnSnapshot *out)
{
    unsigned long now = TickCount();

    memset(out, 0, sizeof *out);
    out->phase = g.phase;
    strncpy(out->host, g.host, sizeof out->host - 1);
    out->port = g.port;
    strncpy(out->peer_name, g.peer_name, sizeof out->peer_name - 1);
    strncpy(out->peer_version, g.peer_version,
            sizeof out->peer_version - 1);
    strncpy(out->last_fail, g.last_fail, sizeof out->last_fail - 1);
    out->retry_in_secs = -1;
    out->connected_secs = -1;
    out->quiet_secs = -1;
    if (g.phase == kConnBackoff && g.backoff_until > now) {
        out->retry_in_secs = (long)((g.backoff_until - now + 59) / 60);
    }
    if (g.phase == kConnConnected && g.connected_tick != 0) {
        out->connected_secs = (long)((now - g.connected_tick) / 60);
    }
    if (g.last_rx_tick != 0) {
        out->quiet_secs = (long)((now - g.last_rx_tick) / 60);
    }
    out->contract_revision = kNowContractRevision;
    out->transfer_active = conn_wants_fast_pump();
}

long conn_last_rtt_ms(void)
{
    return g.last_rtt_ms;
}
