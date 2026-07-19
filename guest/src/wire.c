#include "wire.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "contract.h"
#include "ot_carbon.h"
#include "product_identity.h"

enum {
    kConnectDeadlineTicks = 60 * 10,  /* 10s to connect */
    kReplyDeadlineTicks = 60 * 5      /* 5s for the host's hello */
};

/* --- tiny JSON helpers -------------------------------------------------- */
/* The control payloads are flat objects with simple string/number values
   and no escapes we ever emit; a scanner is enough and stays auditable. */

static int json_find_string(const char *json, const char *key,
                            char *out, long cap)
{
    char pattern[48];
    const char *p;
    long n = 0;

    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    p = strstr(json, pattern);
    if (p == NULL) {
        return 0;
    }
    p += strlen(pattern);
    while (*p != '\0' && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return 1;
}

static int json_type_is(const char *json, const char *type)
{
    char pattern[48];

    snprintf(pattern, sizeof pattern, "\"type\":\"%s\"", type);
    return strstr(json, pattern) != NULL;
}

/* --- dotted-quad parsing ------------------------------------------------ */

static int parse_ipv4(const char *text, UInt32 *out)
{
    unsigned long parts[4];
    int i = 0;
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

/* --- frame I/O with deadlines ------------------------------------------ */

static void put_frame_header(unsigned char *dst, unsigned char channel,
                             unsigned char flags, unsigned short transfer,
                             unsigned long length)
{
    dst[0] = channel;
    dst[1] = flags;
    dst[2] = (unsigned char)(transfer >> 8);
    dst[3] = (unsigned char)(transfer & 0xFF);
    dst[4] = (unsigned char)((length >> 24) & 0xFF);
    dst[5] = (unsigned char)((length >> 16) & 0xFF);
    dst[6] = (unsigned char)((length >> 8) & 0xFF);
    dst[7] = (unsigned char)(length & 0xFF);
}

/* One contiguous send per frame: back-to-back small writes are dropped by
   real classic NICs (PB1400c Farallon TX burst drop). */
static int send_control(EndpointRef ep, const char *json)
{
    unsigned char buffer[512 + kNowFrameHeaderBytes];
    unsigned long length = (unsigned long)strlen(json);
    OTResult sent;

    if (length > 512) {
        return 0;
    }
    put_frame_header(buffer, kNowChannelControl, 0, 0, length);
    memcpy(buffer + kNowFrameHeaderBytes, json, length);
    sent = gNowOT.snd(ep, buffer, kNowFrameHeaderBytes + length, 0);
    return sent == (OTResult)(kNowFrameHeaderBytes + length);
}

/* Accumulates exactly one control frame, polling with a deadline. Returns 1
   on success, 0 on timeout/error. */
static int receive_control(EndpointRef ep, char *payload_out, long cap,
                           unsigned long deadline_ticks)
{
    unsigned char header[kNowFrameHeaderBytes];
    long have = 0;
    unsigned long payload_len = 0;
    unsigned long deadline = TickCount() + deadline_ticks;
    OTFlags flags = 0;
    OTResult got;

    while (have < kNowFrameHeaderBytes) {
        got = gNowOT.rcv(ep, header + have,
                         (OTByteCount)(kNowFrameHeaderBytes - have), &flags);
        if (got > 0) {
            have += got;
        } else if (got != kOTNoDataErr) {
            return 0;
        }
        if (TickCount() > deadline) {
            return 0;
        }
    }
    payload_len = ((unsigned long)header[4] << 24)
        | ((unsigned long)header[5] << 16)
        | ((unsigned long)header[6] << 8)
        | (unsigned long)header[7];
    if (header[0] != kNowChannelControl || payload_len + 1 > (unsigned long)cap) {
        return 0;
    }
    have = 0;
    while ((unsigned long)have < payload_len) {
        got = gNowOT.rcv(ep, payload_out + have,
                         (OTByteCount)(payload_len - (unsigned long)have),
                         &flags);
        if (got > 0) {
            have += got;
        } else if (got != kOTNoDataErr) {
            return 0;
        }
        if (TickCount() > deadline) {
            return 0;
        }
    }
    payload_out[payload_len] = '\0';
    return 1;
}

/* --- the test ----------------------------------------------------------- */

int now_wire_test(const char *host_ip, unsigned short port,
                  char *status_out, long status_cap)
{
    UInt32 address = 0;
    EndpointRef ep = kOTInvalidEndpointRef;
    OSStatus err, open_err = -1;
    InetAddress inet;
    TCall call;
    char json[512];
    char reply[512];
    char peer_name[64];
    char peer_version[32];
    unsigned long started, deadline;
    unsigned long rtt_ms;
    int result = kNowTestProtocolError;

    status_out[0] = '\0';
    if (!parse_ipv4(host_ip, &address)) {
        snprintf(status_out, status_cap,
                 "Host must be a numeric address like 10.0.2.2");
        return kNowTestBadAddress;
    }
    err = now_ot_resolve();
    if (err != noErr) {
        snprintf(status_out, status_cap,
                 "Networking needs CarbonLib 1.6 (error %ld)", (long)err);
        return kNowTestNoCarbonLib;
    }
    err = now_ot_ensure_inited();
    if (err != noErr) {
        snprintf(status_out, status_cap,
                 "Open Transport failed to start (error %ld)", (long)err);
        return kNowTestOTInitFailed;
    }

    ep = gNowOT.openEndpoint(OTCreateConfiguration(kTCPName), 0, NULL,
                             &open_err, gNowOTContext);
    if (ep == kOTInvalidEndpointRef) {
        snprintf(status_out, status_cap,
                 "Could not open a TCP endpoint (error %ld)", (long)open_err);
        return kNowTestOTInitFailed;
    }
    gNowOT.setNonBlocking(ep);
    err = gNowOT.bind(ep, NULL, NULL);
    if (err != noErr) {
        snprintf(status_out, status_cap, "Bind failed (error %ld)", (long)err);
        gNowOT.closeProvider(ep);
        return kNowTestConnectFailed;
    }

    memset(&inet, 0, sizeof inet);
    inet.fAddressType = AF_INET;
    inet.fPort = port;
    inet.fHost = address;
    memset(&call, 0, sizeof call);
    call.addr.buf = (UInt8 *)&inet;
    call.addr.len = sizeof inet;

    started = TickCount();
    err = gNowOT.connect(ep, &call, NULL);
    if (err != noErr && err != kOTNoDataErr) {
        snprintf(status_out, status_cap,
                 "Could not connect (error %ld)", (long)err);
        goto fail_unbind;
    }
    deadline = TickCount() + kConnectDeadlineTicks;
    for (;;) {
        OTResult look = gNowOT.look(ep);
        if (look == T_CONNECT) {
            gNowOT.rcvConnect(ep, NULL);
            break;
        }
        if (look == T_DISCONNECT) {
            gNowOT.rcvDisconnect(ep, NULL);
            snprintf(status_out, status_cap,
                     "Connection refused by %s:%u", host_ip, port);
            goto fail_unbind;
        }
        if (TickCount() > deadline) {
            snprintf(status_out, status_cap,
                     "No answer from %s:%u (10s)", host_ip, port);
            goto fail_unbind;
        }
    }

    snprintf(json, sizeof json,
             "{\"type\":\"hello\",\"contract\":%d,\"side\":\"guest\","
             "\"version\":\"%s\",\"name\":\"%s\",\"os\":\"9\","
             "\"chunk\":%d}",
             kNowContractRevision, PRODUCT_VERSION, PRODUCT_DISPLAY_NAME,
             kNowDefaultChunk);
    if (!send_control(ep, json)) {
        snprintf(status_out, status_cap, "Sending hello failed");
        goto fail_disconnect;
    }
    if (!receive_control(ep, reply, sizeof reply, kReplyDeadlineTicks)) {
        snprintf(status_out, status_cap,
                 "Connected, but no hello reply (5s)");
        result = kNowTestNoReply;
        goto fail_disconnect;
    }
    rtt_ms = (TickCount() - started) * 1000 / 60;

    if (json_type_is(reply, "hello")) {
        if (!json_find_string(reply, "name", peer_name, sizeof peer_name)) {
            strcpy(peer_name, "host");
        }
        if (!json_find_string(reply, "version", peer_version,
                              sizeof peer_version)) {
            strcpy(peer_version, "?");
        }
        snprintf(status_out, status_cap, "Connected: %s (v%s) - %lu ms",
                 peer_name, peer_version, rtt_ms);
        result = kNowTestOK;
    } else if (json_type_is(reply, "refuse")) {
        if (json_find_string(reply, "reason", peer_name, sizeof peer_name)) {
            snprintf(status_out, status_cap, "Refused: %s", peer_name);
        } else {
            snprintf(status_out, status_cap, "Refused by host");
        }
        result = kNowTestRefused;
    } else {
        snprintf(status_out, status_cap, "Unexpected reply from host");
        result = kNowTestProtocolError;
    }

    if (result == kNowTestOK) {
        send_control(ep, "{\"type\":\"bye\",\"code\":\"normal\"}");
    }

fail_disconnect:
    /* Orderly release; unannounced closes leak T_DISCONNECT indications on
       OS 9 (the listener-wedge campaign). Best-effort with no waiting. */
    gNowOT.sndOrderlyDisconnect(ep);
fail_unbind:
    gNowOT.unbind(ep);
    gNowOT.closeProvider(ep);
    return result;
}
