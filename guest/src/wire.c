#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "commands.h"
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
    char peer_name[64];
    char peer_version[32];
    char status[128];
    char last_fail[128];
} ConnState;

static ConnState g;

static void send_hello(void);
static void xfer_cleanup(void);

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

/* Finds "key" and returns the first character of its value, skipping the
   colon and any whitespace. JSON permits spaces there; a peer using a
   pretty-printing encoder must not be silently ignored. */
static const char *json_value(const char *json, const char *key)
{
    char pattern[48];
    const char *p;

    snprintf(pattern, sizeof pattern, "\"%s\"", key);
    p = strstr(json, pattern);
    if (p == NULL) {
        return NULL;
    }
    p += strlen(pattern);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        ++p;
    }
    if (*p != ':') {
        return NULL;
    }
    ++p;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        ++p;
    }
    return p;
}

static int json_find_string(const char *json, const char *key,
                            char *out, long cap)
{
    const char *p = json_value(json, key);
    long n = 0;

    if (p == NULL || *p != '"') {
        return 0;
    }
    ++p;
    while (*p != '\0' && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return 1;
}

static long json_find_int(const char *json, const char *key, long fallback)
{
    const char *p = json_value(json, key);

    if (p == NULL) {
        return fallback;
    }
    return strtol(p, NULL, 10);
}

static int json_type_is(const char *json, const char *type)
{
    char value[48];

    if (!json_find_string(json, "type", value, sizeof value)) {
        return 0;
    }
    return strcmp(value, type) == 0;
}

/* One contiguous send per frame: back-to-back small writes are dropped by
   real classic NICs (PB1400c Farallon TX burst drop). */
static int send_control(const char *json)
{
    unsigned char buffer[4096 + kNowFrameHeaderBytes];
    unsigned long length = (unsigned long)strlen(json);
    OTResult sent;

    if (g.ep == kOTInvalidEndpointRef || length > 4096) {
        return 0;
    }
    buffer[0] = kNowChannelControl;
    buffer[1] = 0;
    buffer[2] = 0;
    buffer[3] = 0;
    buffer[4] = (unsigned char)((length >> 24) & 0xFF);
    buffer[5] = (unsigned char)((length >> 16) & 0xFF);
    buffer[6] = (unsigned char)((length >> 8) & 0xFF);
    buffer[7] = (unsigned char)(length & 0xFF);
    memcpy(buffer + kNowFrameHeaderBytes, json, length);
    sent = gNowOT.snd(g.ep, buffer, kNowFrameHeaderBytes + length, 0);
    return sent == (OTResult)(kNowFrameHeaderBytes + length);
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
    if (!json_find_string(reply, "name", g.peer_name, sizeof g.peer_name)) {
        strcpy(g.peer_name, "host");
    }
    if (!json_find_string(reply, "version", g.peer_version,
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

static struct {
    Boolean active;
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

        if (TickCount() < g_xfer.next_tick) {
            return;                   /* paced: resume later */
        }
        if (g_xfer.frame_sent >= g_xfer.frame_len) {
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

static void xfer_abort(void)
{
    if (g_xfer.active) {
        xfer_finish(false);
    }
}

/* Captures, exports wire pixels, announces with capture.begin, and arms the
   incremental sender. Returns immediately — the bytes go out from
   service_transfer so the app keeps running. */
static void serve_capture(const char *request)
{
    NowPrefs prefs;
    CaptureImage image;
    char json[512];
    long id = json_find_int(request, "id", 0);
    long depth_arg = json_find_int(request, "depth", 0);
    short depth;
    unsigned short xfer;
    long chunk;
    unsigned long t_start;
    long capture_ms;
    short width, height, row_bytes;
    int rc;

    if (g_xfer.active) {
        xfer_finish(false);           /* one transfer at a time */
    }
    now_prefs_load(&prefs);
    depth = capture_depth_is_supported((short)depth_arg)
        ? (short)depth_arg : prefs.shot_depth;
    chunk = (long)prefs.chunk_kb * 1024;
    if (chunk < 1024 || chunk > kNowMaxPayload) {
        chunk = 8192;
    }
    ++g.transfer_seq;
    if (g.transfer_seq == 0) {
        g.transfer_seq = 1;
    }
    xfer = g.transfer_seq;

    t_start = TickCount();
    rc = capture_screen(depth, &image);
    capture_ms = (long)((TickCount() - t_start) * 1000 / 60);
    if (rc != kCaptureOK) {
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }
    width = (short)(image.bounds.right - image.bounds.left);
    height = (short)(image.bounds.bottom - image.bounds.top);
    row_bytes = image.row_bytes;

    memset(&g_xfer, 0, sizeof g_xfer);
    if (now_pixels_export(&image, prefs.shot_pack, &g_xfer.blob) != 0) {
        capture_image_dispose(&image);
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }
    capture_image_dispose(&image);

    g_xfer.frame = NewPtr(chunk + kNowFrameHeaderBytes);
    if (g_xfer.frame == NULL) {
        now_pixels_dispose(&g_xfer.blob);
        snprintf(json, sizeof json,
                 "{\"type\":\"capture.end\",\"id\":%ld,\"transfer\":%u,"
                 "\"ok\":false}", id, xfer);
        send_control(json);
        return;
    }

    snprintf(json, sizeof json,
             "{\"type\":\"capture.begin\",\"id\":%ld,\"transfer\":%u,"
             "\"width\":%d,\"height\":%d,\"depth\":%d,"
             "\"rowBytes\":%d,\"bytes\":%ld,\"paletteBytes\":%ld,"
             "\"encoding\":\"%s\",\"captureMs\":%ld,\"encodeMs\":%ld}",
             id, xfer, (int)width, (int)height,
             (int)depth, (int)row_bytes, g_xfer.blob.total_bytes,
             g_xfer.blob.palette_bytes,
             g_xfer.blob.packed ? "packbits" : "raw",
             capture_ms, g_xfer.blob.encode_ms);
    if (!send_control(json)) {
        xfer_cleanup();
        return;
    }

    HLock(g_xfer.blob.data);
    g_xfer.active = true;
    g_xfer.total = g_xfer.blob.total_bytes;
    g_xfer.offset = 0;
    g_xfer.chunk = chunk;
    g_xfer.xfer = xfer;
    g_xfer.id = id;
    g_xfer.pace_ms = prefs.pace_ms;
    g_xfer.frame_len = kNowFrameHeaderBytes;   /* primes the first build */
    g_xfer.frame_sent = kNowFrameHeaderBytes;
    g_xfer.started = TickCount();
    g_xfer.next_tick = 0;
    g_xfer.deadline = TickCount() + kXferDeadlineTicks;
}

/* Returns 0 if the connection should be torn down (bye/protocol error). */
static int handle_frame(const char *reply)
{
    if (reply[0] == '\0') {
        return 1;                    /* dropped non-control frame */
    }
    if (g.phase == kConnHandshaking) {
        if (json_type_is(reply, "hello")) {
            on_hello(reply);
            return 1;
        }
        if (json_type_is(reply, "refuse")) {
            char reason[96];
            if (json_find_string(reply, "reason", reason, sizeof reason)) {
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
    if (json_type_is(reply, "pong")) {
        g.pings_sent = 0;
        g.last_rtt_ms = (long)((TickCount() - g.ping_sent_tick) * 1000 / 60);
        snprintf(g.status, sizeof g.status, "Connected: %s (v%s) - %ld ms",
                 g.peer_name, g.peer_version, g.last_rtt_ms);
        return 1;
    }
    if (json_type_is(reply, "capture.request")) {
        serve_capture(reply);
        return 1;
    }
    if (json_type_is(reply, "capture.cancel")) {
        xfer_abort();
        return 1;
    }
    if (json_type_is(reply, "command.request")) {
        char name[48];
        char result[3072];
        long id = json_find_int(reply, "id", 0);

        if (!json_find_string(reply, "name", name, sizeof name)) {
            strcpy(name, "?");
        }
        now_command_run(name, reply, id, result, sizeof result);
        if (!send_control(result)) {
            fail("Connection lost");
            return 0;
        }
        return 1;
    }
    if (json_type_is(reply, "bye")) {
        char reason[96];
        if (json_find_string(reply, "reason", reason, sizeof reason)) {
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
            send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
        }
        gNowOT.sndOrderlyDisconnect(g.ep);
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
        service_connected_io();
        if (g.phase == kConnHandshaking && TickCount() > g.phase_deadline) {
            fail("No hello reply (8s)");
        }
        break;
    case kConnConnected:
        service_connected_io();
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
        send_control("{\"type\":\"bye\",\"code\":\"normal\"}");
        gNowOT.sndOrderlyDisconnect(g.ep);
    }
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
