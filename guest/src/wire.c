#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "fileshare.h"
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
static void take_bulk_in(const unsigned char *bytes, long len);
static void put_drop(void);
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
        /* The guest's only inbound bulk is a file being put into the
           share; anything else has nowhere to go and is dropped. */
        take_bulk_in(g.rx + kNowFrameHeaderBytes, (long)length);
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
        g.peer_name[0] = '\0';
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
    XferKind kind;
    Handle data;                      /* the bytes on the wire; blob owns
                                         them for captures, we do for files */
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
    if (g_xfer.data != NULL) {
        HUnlock(g_xfer.data);
    }
    if (g_xfer.blob.data != NULL) {
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

    snprintf(json, sizeof json,
             "{\"type\":\"%s.end\",\"id\":%ld,\"transfer\":%u,"
             "\"ok\":%s,\"sendMs\":%ld}",
             g_xfer.kind == kXferFile ? "file" : "capture",
             g_xfer.id, g_xfer.xfer, ok ? "true" : "false",
             (long)((TickCount() - g_xfer.started) * 1000 / 60));
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
           *g_xfer.data + g_xfer.offset, (size_t)n);
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

/* Captures the screen and exports the wire pixels. On success the blob is
   the caller's to dispose. */
static int gather_shot(short depth, Boolean pack, PixelBlob *blob,
                       ShotMeta *meta)
{
    CaptureImage image;
    unsigned long t_start = TickCount();

    memset(meta, 0, sizeof *meta);    /* kind = kFrameStandalone */
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

/* Arms the sender over an arbitrary handle. The caller has already
   announced the transfer (capture.begin / file.begin); on success the
   transfer owns the handle. */
static int arm_blob_transfer(long id, unsigned short xfer, Handle data,
                             long total, long chunk, short pace_ms,
                             XferKind kind)
{
    Ptr frame = NewPtr(chunk + kNowFrameHeaderBytes);

    if (frame == NULL) {
        return 0;
    }
    memset(&g_xfer, 0, sizeof g_xfer);
    g_xfer.kind = kind;
    g_xfer.data = data;
    g_xfer.frame = frame;
    HLock(data);
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

    snprintf(json, sizeof json,
             "{\"type\":\"file.refuse\",\"id\":%ld,\"code\":\"%s\","
             "\"reason\":\"%.120s\"}", id, code, reason);
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
        file_refuse(id, "too-big", "not enough memory to stage the file");
        break;
    default:
        file_refuse(id, "io-error", "the File Manager refused");
        break;
    }
}

/* --- receiving a put ----------------------------------------------------
   The host offers, the guest answers without prompting anyone, and the
   bytes then stream to disk as they arrive. Nothing is buffered: the
   app partition is smaller than the files people will send. */

static struct {
    Boolean active;                   /* accepted; bytes may arrive */
    long id;
    FileReceive rx;
} g_put;

static void put_drop(void)
{
    if (g_put.active) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
    }
}

static void put_done(Boolean ok, const char *code, const char *reason)
{
    char json[256];

    if (ok) {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":true}",
                 g_put.id);
    } else {
        snprintf(json, sizeof json,
                 "{\"type\":\"file.done\",\"id\":%ld,\"ok\":false,"
                 "\"code\":\"%s\",\"reason\":\"%.100s\"}",
                 g_put.id, code, reason);
    }
    send_control(json);
    g_put.active = false;
}

static void put_abort(const char *code, const char *reason)
{
    if (!g_put.active) {
        return;
    }
    now_files_receive_abort(&g_put.rx);
    put_done(false, code, reason);
}

/* Called for every inbound bulk frame. */
static void take_bulk_in(const unsigned char *bytes, long len)
{
    int rc;

    if (!g_put.active) {
        return;                       /* nothing is expecting these */
    }
    rc = now_files_receive_chunk(&g_put.rx, bytes, len);
    if (rc != kFilesOK) {
        put_abort("io-error", "could not write the file");
    }
}

static void serve_file_offer(const char *request)
{
    char name[64];
    char path[224];
    char container_arg[16];
    char json[256];
    char note[128];
    long id = now_json_find_int(request, "id", 0);
    long bytes = now_json_find_int(request, "bytes", 0);
    long modified = now_json_find_int(request, "modified", 0);
    char type_arg[8], creator_arg[8];
    OSType file_type = 0, creator = 0;
    FileContainer container = kContainerData;
    Boolean overwrite;
    int rc;

    if (g_stream.active || g_xfer.active || g_offer.active
        || g_put.active) {
        file_refuse(id, "busy", "a transfer is already in flight");
        return;
    }
    name[0] = '\0';
    path[0] = '\0';
    now_json_find_string(request, "name", name, sizeof name);
    now_json_find_string(request, "path", path, sizeof path);
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

    memset(&g_put, 0, sizeof g_put);
    g_put.id = id;
    rc = now_files_receive_begin(path, name, container, bytes, file_type,
                                 creator, (unsigned long)modified,
                                 overwrite, &g_put.rx);
    if (rc != kFilesOK) {
        switch (rc) {
        case kFilesExists:
            file_refuse(id, "exists", "a file of that name is already there");
            break;
        case kFilesBadPath:
            file_refuse(id, "bad-path", "that name or folder is not usable");
            break;
        default:
            file_refuse(id, "io-error", "could not create the file");
            break;
        }
        return;
    }
    g_put.active = true;
    snprintf(json, sizeof json,
             "{\"type\":\"file.accept\",\"id\":%ld}", id);
    if (!send_control(json)) {
        now_files_receive_abort(&g_put.rx);
        g_put.active = false;
        return;
    }
    snprintf(note, sizeof note, "Receiving %.31s...", name);
    note_shot(note);
}

/* The sender's file.end closes the transfer; the guest confirms only
   after the bytes are written and the file is stamped and named. */
static void finish_put(const char *reply)
{
    char note[128];
    int rc;

    if (!g_put.active) {
        return;
    }
    if (now_json_find_int(reply, "ok", 0) == 0
        && now_json_value(reply, "ok") != NULL
        && *now_json_value(reply, "ok") == 'f') {
        put_abort("cancelled", "the sender stopped");
        note_shot("Incoming file cancelled");
        return;
    }
    rc = now_files_receive_finish(&g_put.rx);
    if (rc != kFilesOK) {
        put_done(false, "io-error", "could not finish writing the file");
        note_shot("Incoming file failed");
        return;
    }
    put_done(true, NULL, NULL);
    snprintf(note, sizeof note, "Received %.31s",
             g_put.rx.final.name + 1);
    note_shot(note);
}

static void serve_file_list(const char *request)
{
    enum { kPage = 16 };              /* control frames cap at 4 KB */
    FileEntry entries[kPage];
    char path[224];
    char json[3072];
    char esc[200];
    long id = now_json_find_int(request, "id", 0);
    long cursor = now_json_find_int(request, "cursor", 1);
    Boolean more = false;
    short next = 1;
    int n, i;
    long pos;

    path[0] = '\0';
    now_json_find_string(request, "path", path, sizeof path);
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
                        ",\"modified\":%lu}", entries[i].modified);
    }
    snprintf(json + pos, sizeof json - (size_t)pos,
             "],\"more\":%s,\"cursor\":%d}",
             more ? "true" : "false", (int)next);
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

    if (g_stream.active || g_xfer.active || g_offer.active) {
        file_refuse(id, "busy", "a transfer is already in flight");
        return;
    }
    path[0] = '\0';
    now_json_find_string(request, "path", path, sizeof path);
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
    if (!arm_blob_transfer(id, xfer, stage.blob, stage.total_bytes,
                           chunk, pace_ms, kXferFile)) {
        now_files_stage_dispose(&stage);
        file_refuse(id, "io-error", "could not start the transfer");
        return;
    }
    stage.blob = NULL;                /* the transfer owns it now */
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
    if (now_json_type_is(reply, "file.offer")) {
        serve_file_offer(reply);
        return 1;
    }
    if (now_json_type_is(reply, "file.begin")) {
        return 1;                     /* announced; bytes follow on bulk */
    }
    if (now_json_type_is(reply, "file.end")) {
        finish_put(reply);
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
