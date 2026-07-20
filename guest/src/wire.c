#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "commands.h"
#include "json.h"
#include "pixels.h"
#include "contract.h"
#include "ot_carbon.h"
#include "prefs.h"
#include "product_identity.h"

enum {
    kConnectTimeoutTicks = 60 * 10,   /* 10s to establish the socket */
    kHelloTimeoutTicks = 60 * 8,      /* 8s for the host's hello */
    kPingIntervalTicks = 60 * 30,     /* ping after 30s of silence */
    kDeadTicks = 60 * 65,             /* no traffic for 65s => dead */
    kBackoffMinTicks = 60 * 2,        /* 2s, doubling... */
    kBackoffMaxTicks = 60 * 30,       /* ...to 30s */
    kRxBufferSize = 2048
};

typedef struct {
    ConnPhase phase;
    char host[64];
    unsigned short port;
    Boolean want_connection;          /* false => stay disconnected */

    EndpointRef ep;
    UInt32 address;

    unsigned char rx[kRxBufferSize];
    long rx_len;

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
} ConnState;

static ConnState g;

static void send_hello(void);
static void xfer_cleanup(void);
static void offer_cleanup(void);
static void stream_drop(void);
static void note_shot(const char *line);

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

    if (g.ep == kOTInvalidEndpointRef || length > 4096) {
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
        gNowOT.unbind(g.ep);
        gNowOT.closeProvider(g.ep);
        g.ep = kOTInvalidEndpointRef;
    }
    g.rx_len = 0;
}

/* Move to backoff after a failure; status keeps the reason already set. */
static void enter_backoff(void)
{
    xfer_cleanup();                   /* a dropped link cancels any transfer */
    offer_cleanup();
    stream_drop();                    /* no stopped message on a dead wire */
    ctlq_clear();
    close_endpoint();
    if (!g.want_connection) {
        g.phase = kConnIdle;
        return;
    }
    if (g.backoff_ticks == 0) {
        g.backoff_ticks = kBackoffMinTicks;
    } else {
        g.backoff_ticks *= 2;
        if (g.backoff_ticks > kBackoffMaxTicks) {
            g.backoff_ticks = kBackoffMaxTicks;
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

/* --- connect ------------------------------------------------------------ */

static void start_connect(void)
{
    OSStatus err, open_err = -1;
    InetAddress inet;
    TCall call;

    close_endpoint();
    g.rx_len = 0;
    g.pings_sent = 0;

    if (!parse_ipv4(g.host, &g.address)) {
        fail("Host must be a numeric address like 10.0.2.2");
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
    g.ep = gNowOT.openEndpoint(OTCreateConfiguration(kTCPName), 0, NULL,
                               &open_err, gNowOTContext);
    if (g.ep == kOTInvalidEndpointRef) {
        fail("Could not open a TCP endpoint");
        return;
    }
    gNowOT.setNonBlocking(g.ep);
    if (gNowOT.bind(g.ep, NULL, NULL) != noErr) {
        fail("Bind failed");
        return;
    }

    memset(&inet, 0, sizeof inet);
    inet.fAddressType = AF_INET;
    inet.fPort = g.port;
    inet.fHost = g.address;
    memset(&call, 0, sizeof call);
    call.addr.buf = (UInt8 *)&inet;
    call.addr.len = sizeof inet;

    err = gNowOT.connect(g.ep, &call, NULL);
    g.phase_deadline = TickCount() + kConnectTimeoutTicks;
    snprintf(g.status, sizeof g.status, "Connecting to %s:%u...",
             g.host, g.port);
    if (err == noErr) {
        /* Loopback can complete synchronously; OTRcvConnect would then be
           out-of-state (-3155), so go straight to the handshake. */
        g.phase = kConnHandshaking;
        g.phase_deadline = TickCount() + kHelloTimeoutTicks;
        send_hello();
    } else if (err == kOTNoDataErr) {
        g.phase = kConnConnecting;
    } else {
        fail("Could not connect");
    }
}

static void service_connecting(void)
{
    OSStatus err = gNowOT.rcvConnect(g.ep, NULL);

    if (err == noErr) {
        g.phase = kConnHandshaking;
        g.phase_deadline = TickCount() + kHelloTimeoutTicks;
        send_hello();
        return;
    }
    if (err == kOTLookErr) {
        OTResult look = gNowOT.look(g.ep);
        if (look == T_DISCONNECT) {
            gNowOT.rcvDisconnect(g.ep, NULL);
            fail("Connection refused");
            return;
        }
    } else if (err != kOTNoDataErr) {
        fail("Connect failed");
        return;
    }
    if (TickCount() > g.phase_deadline) {
        fail("No answer (10s)");
    }
}

static void send_hello(void)
{
    char json[256];

    snprintf(json, sizeof json,
             "{\"type\":\"hello\",\"contract\":%d,\"side\":\"guest\","
             "\"version\":\"%s\",\"name\":\"%s\",\"os\":\"9\",\"chunk\":%d}",
             kNowContractRevision, PRODUCT_VERSION, PRODUCT_DISPLAY_NAME,
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

    for (;;) {
        if (g.rx_len >= kRxBufferSize) {
            return 0;                 /* overrun: control frames are tiny */
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

    if (g.rx_len < kNowFrameHeaderBytes) {
        return 0;
    }
    channel = g.rx[0];
    length = ((unsigned long)g.rx[4] << 24) | ((unsigned long)g.rx[5] << 16)
        | ((unsigned long)g.rx[6] << 8) | (unsigned long)g.rx[7];
    if (length + 1 > (unsigned long)cap || length > kNowMaxPayload) {
        return -1;
    }
    total = kNowFrameHeaderBytes + (long)length;
    if (g.rx_len < total) {
        return 0;
    }
    if (channel != kNowChannelControl) {
        /* No bulk transfers arrive in this slice; drop the frame's bytes. */
        memmove(g.rx, g.rx + total, g.rx_len - total);
        g.rx_len -= total;
        payload_out[0] = '\0';
        return 1;
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
        strcpy(g.peer_name, "host");
    }
    if (!now_json_find_string(reply, "version", g.peer_version,
                          sizeof g.peer_version)) {
        strcpy(g.peer_version, "?");
    }
    g.phase = kConnConnected;
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
    kXferDeadlineTicks = 60 * 120     /* give up on a stuck transfer */
};

typedef struct {
    short width, height, depth, row_bytes;
    long capture_ms;
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
    unsigned long cap_start_tick;
    long est_send_ticks;
    long est_cap_ticks;               /* capture + encode, measured */
} g_stream;

enum { kStreamReqTimeoutTicks = 60 * 10 };

static struct {
    Boolean pending;                  /* asked the host to open a bracket */
    unsigned long deadline;
} g_streamreq;

static struct {
    Boolean active;
    Boolean pushed;                   /* guest-initiated: report to panel */
    Boolean aborting;                 /* drain to the frame boundary, then
                                         end ok:false - never mid-frame */
    PixelBlob blob;
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
    if (g_xfer.blob.data != NULL) {
        HUnlock(g_xfer.blob.data);
    }
    now_pixels_dispose(&g_xfer.blob);
    g_xfer.active = false;
}

static void xfer_finish(Boolean ok)
{
    char json[256];

    snprintf(json, sizeof json,
             "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":%s,\"sendMs\":%ld}",
             g_xfer.id, g_xfer.xfer, ok ? "true" : "false",
             (long)((TickCount() - g_xfer.started) * 1000 / 60));
    send_control(json);
    if (ok && g_stream.active && g_xfer.id == g_stream.id) {
        g_stream.est_send_ticks = (long)(TickCount() - g_xfer.started);
    }
    if (g_xfer.pushed) {
        if (ok) {
            snprintf(json, sizeof json, "Sent to host (%ld ms)",
                     (long)((TickCount() - g_xfer.started) * 1000 / 60));
            note_shot(json);
        } else {
            note_shot("Send to host failed");
        }
    }
    xfer_cleanup();
}

static void xfer_build_frame(void)
{
    long n = g_xfer.total - g_xfer.offset;
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
    memcpy(g_xfer.frame + kNowFrameHeaderBytes,
           *g_xfer.blob.data + g_xfer.offset, (size_t)n);
    g_xfer.frame_len = kNowFrameHeaderBytes + n;
    g_xfer.frame_sent = 0;
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
            xfer_build_frame();
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

static unsigned short next_xfer(void)
{
    ++g.transfer_seq;
    if (g.transfer_seq == 0) {
        g.transfer_seq = 1;
    }
    return g.transfer_seq;
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
    meta->capture_ms = (long)((TickCount() - t_start) * 1000 / 60);
    meta->width = (short)(image.bounds.right - image.bounds.left);
    meta->height = (short)(image.bounds.bottom - image.bounds.top);
    meta->depth = depth;
    meta->row_bytes = image.row_bytes;
    if (now_pixels_export(&image, pack, blob) != 0) {
        capture_image_dispose(&image);
        return 0;
    }
    capture_image_dispose(&image);
    return 1;
}

/* Announces capture.begin and arms the incremental sender. Takes ownership
   of the blob either way; on failure the host gets capture.end ok:false so
   it never waits on a transfer that will not come. */
static int arm_transfer(long id, unsigned short xfer, const ShotMeta *meta,
                        PixelBlob *blob, long chunk, short pace_ms,
                        Boolean pushed)
{
    char json[512];

    memset(&g_xfer, 0, sizeof g_xfer);
    g_xfer.blob = *blob;
    memset(blob, 0, sizeof *blob);

    g_xfer.frame = NewPtr(chunk + kNowFrameHeaderBytes);
    if (g_xfer.frame == NULL) {
        now_pixels_dispose(&g_xfer.blob);
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return 0;
    }

    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld}",
             id, xfer, (int)meta->width, (int)meta->height,
             (int)meta->depth, (int)meta->row_bytes, g_xfer.blob.total_bytes,
             g_xfer.blob.palette_bytes,
             g_xfer.blob.packed ? "packbits" : "raw",
             meta->capture_ms, g_xfer.blob.encode_ms);
    if (!send_control(json)) {
        xfer_cleanup();
        return 0;
    }

    HLock(g_xfer.blob.data);
    g_xfer.active = true;
    g_xfer.pushed = pushed;
    g_xfer.total = g_xfer.blob.total_bytes;
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
    chunk = (long)prefs.chunk_kb * 1024;
    if (chunk < 1024 || chunk > kNowMaxPayload) {
        chunk = 8192;
    }
    xfer = next_xfer();

    memset(&blob, 0, sizeof blob);
    if (!gather_shot(depth, prefs.shot_pack, &blob, &meta)) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }
    arm_transfer(id, xfer, &meta, &blob, chunk, prefs.pace_ms, false);
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

    if (g.phase != kConnConnected) {
        snprintf(err, (size_t)cap, "Not connected to a host");
        return -1;
    }
    if (g_stream.active) {
        snprintf(err, (size_t)cap, "Streaming to the host");
        return -1;
    }
    if (g_xfer.active || g_offer.active) {
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
    snprintf(line, sizeof line, "Offered %ld KB to host...",
             g_offer.blob.total_bytes / 1024);
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
        note_shot("Sending to host...");
    } else {
        note_shot("Send to host failed");
    }
}

static void offer_refused(const char *reply)
{
    char reason[64];
    char line[96];

    if (!g_offer.active || now_json_find_int(reply, "id", -1) != g_offer.id) {
        return;
    }
    offer_cleanup();
    if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
        snprintf(line, sizeof line, "Host declined: %.60s", reason);
    } else {
        snprintf(line, sizeof line, "Host declined the screenshot");
    }
    note_shot(line);
}

static void service_offer(void)
{
    if (g_offer.active && TickCount() > g_offer.deadline) {
        offer_cleanup();
        note_shot("Host did not answer the offer");
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

static void stream_start(const char *reply)
{
    NowPrefs prefs;
    long depth_arg;
    long id = now_json_find_int(reply, "id", 0);

    if (g_stream.active || g_xfer.active || g_offer.active) {
        stream_send_stopped(id, "busy: a transfer is in flight");
        return;
    }
    now_prefs_load(&prefs);
    depth_arg = now_json_find_int(reply, "depth", 0);

    memset(&g_stream, 0, sizeof g_stream);
    g_stream.id = id;
    g_stream.depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    g_stream.pack = prefs.shot_pack;
    g_stream.chunk = (long)prefs.chunk_kb * 1024;
    if (g_stream.chunk < 1024 || g_stream.chunk > kNowMaxPayload) {
        g_stream.chunk = 8192;
    }
    g_stream.pace_ms = prefs.pace_ms;
    g_stream.min_interval_ticks =
        now_json_find_int(reply, "minIntervalMs", 0) * 60 / 1000;
    g_stream.next_frame_tick = 0;
    g_stream.est_cap_ticks = 10;      /* ~165 ms until measured */
    g_stream.est_send_ticks = 0;      /* first capture starts at once */
    g_stream.active = true;
    g_streamreq.pending = false;
    note_shot("Streaming to host...");
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
        snprintf(err, (size_t)cap, "Not connected to a host");
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
    note_shot("Asked host to stream...");
    return 0;
}

Boolean now_wire_stream_active(void)
{
    return g_stream.active;
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

/* Finishes a completed banded capture: export + encode now, so the frame
   is ready the instant the lane frees. */
static void stream_finish_capture(unsigned long began)
{
    CaptureImage image = g_stream.cap.image;

    memset(&g_stream.cap, 0, sizeof g_stream.cap);
    g_stream.cap_active = false;

    g_stream.ready_meta.width =
        (short)(image.bounds.right - image.bounds.left);
    g_stream.ready_meta.height =
        (short)(image.bounds.bottom - image.bounds.top);
    g_stream.ready_meta.depth = image.depth;
    g_stream.ready_meta.row_bytes = image.row_bytes;
    g_stream.ready_meta.capture_ms =
        (long)((TickCount() - began) * 1000 / 60);
    memset(&g_stream.ready_blob, 0, sizeof g_stream.ready_blob);
    if (now_pixels_export(&image, g_stream.pack,
                          &g_stream.ready_blob) != 0) {
        capture_image_dispose(&image);
        stream_end("capture failed");
        return;
    }
    capture_image_dispose(&image);
    g_stream.ready = true;
    g_stream.est_cap_ticks = (long)(TickCount() - began);
}

/* The pipelined frame pump: while frame N sends, frame N+1 is captured a
   band at a time; when both halves are done the frame arms immediately. */
static void service_stream(void)
{
    static unsigned long cap_began;

    if (g_streamreq.pending && TickCount() > g_streamreq.deadline) {
        g_streamreq.pending = false;
        note_shot("Host did not start streaming");
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
        g_stream.next_frame_tick =
            TickCount() + g_stream.min_interval_ticks;
        g_stream.ready = false;
        if (!arm_transfer(g_stream.id, next_xfer(), &g_stream.ready_meta,
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
        if (banded_capture_begin(g_stream.depth, kStreamBands,
                                 &g_stream.cap) != kCaptureOK) {
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
                snprintf(g.status, sizeof g.status, "Refused by host");
            }
            return 0;
        }
        snprintf(g.status, sizeof g.status, "Unexpected reply from host");
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
    if (now_json_type_is(reply, "stream.start")) {
        stream_start(reply);
        return 1;
    }
    if (now_json_type_is(reply, "stream.stop")) {
        stream_stop(reply);
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
    if (now_json_type_is(reply, "error")) {
        if (g_streamreq.pending) {
            g_streamreq.pending = false;
            note_shot("Host declined the stream");
        }
        return 1;
    }
    if (now_json_type_is(reply, "bye")) {
        char reason[96];
        if (now_json_find_string(reply, "reason", reason, sizeof reason)) {
            snprintf(g.status, sizeof g.status, "Host disconnected: %s",
                     reason);
        } else {
            snprintf(g.status, sizeof g.status, "Host disconnected");
        }
        return 0;
    }
    return 1;                        /* ignore anything else for now */
}

static void service_connected_io(void)
{
    char payload[512];
    int rc;

    if (!pump_rx()) {
        fail("Connection lost");
        return;
    }
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
            /* Peer said goodbye or we rejected it: orderly release, backoff.
               handle_frame set g.status to the specific reason — keep it. */
            snprintf(g.last_fail, sizeof g.last_fail, "%s", g.status);
            gNowOT.sndOrderlyDisconnect(g.ep);
            enter_backoff();
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
    g.want_connection = true;
    strcpy(g.status, "Not connected");
    start_connect();
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
}

void conn_service(void)
{
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
        }
        if (g.phase == kConnConnected) {
            service_stream();
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

ConnPhase conn_phase(void)
{
    return g.phase;
}

Boolean conn_wants_fast_pump(void)
{
    return g_xfer.active || g_stream.active || g_offer.active
        || g_ctlq.count > 0;
}

Boolean conn_is_connected(void)
{
    return g.phase == kConnConnected;
}

void conn_status(char *out, long cap)
{
    snprintf(out, cap, "%s", g.status);
}

long conn_last_rtt_ms(void)
{
    return g.last_rtt_ms;
}
