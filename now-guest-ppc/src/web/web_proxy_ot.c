#include "web_proxy_ot.h"

#include <OpenTransport.h>
#include <OpenTptInternet.h>
#include <stdio.h>
#include <string.h>

#include "nowlog.h"
#include "ot_carbon.h"
#include "wire.h"
#include "web_accept.h"
#include "web_proxy_request.h"

enum {
    kLoopbackHost = 0x7f000001UL,
    kRequestCap = 3584,
    kHeaderCap = 384,
    kResponseCap = 512 * 1024,
    kResponseTimeoutTicks = 60 * 60
};

typedef struct {
    EndpointRef listener;
    EndpointRef worker;
    OTNotifyUPP notifier;
    InetAddress peer;
    TCall call;
    unsigned short port;
    Boolean running;
    Boolean accepted;
    Boolean active;
    Boolean data_ready;
    Boolean can_send;
    Boolean peer_closed;
    char request[kRequestCap + 1];
    long request_bytes;
    long request_id;
    unsigned long deadline;
    Ptr response;
    long response_expected;
    long response_received;
    long response_sent;
    long response_seq;
    char header[kHeaderCap];
    long header_bytes;
    long header_sent;
    char stage[128];
    /* What Open Transport GRANTED, not what was asked for. The shipped
       code asked for 127.0.0.1 and told the page it had got it; nothing
       ever looked. */
    unsigned long bound_host;
    unsigned short bound_port;
    Boolean bound_known;
    /* The last refused call, recorded raw. Formatting happens in
       now_web_proxy_status at task time - the notifier can run at
       deferred-task time and does no more work than it must. */
    Boolean refusal_seen;
    unsigned long refusal_host;
    NowWebAcceptDecision refusal_code;
    long refused_count;
    long served_count;
    /* The last thing the modern Mac said about a page. This is all the
       guest can honestly know about the host's Web service today: there
       is no host->guest status message, so a round trip is the evidence.
       See the ledger's web.status proposal. */
    char host_note[112];
} WebProxyState;

static WebProxyState g_web;

static void close_endpoint(EndpointRef *endpoint)
{
    if (*endpoint == kOTInvalidEndpointRef) return;
    gNowOT.removeNotifier(*endpoint);
    (void)gNowOT.sndOrderlyDisconnect(*endpoint);
    (void)gNowOT.unbind(*endpoint);
    (void)gNowOT.closeProvider(*endpoint);
    *endpoint = kOTInvalidEndpointRef;
}

static void dispose_response(void)
{
    if (g_web.response != NULL) DisposePtr(g_web.response);
    g_web.response = NULL;
    g_web.response_expected = 0;
    g_web.response_received = 0;
    g_web.response_sent = 0;
    g_web.response_seq = 0;
    g_web.header_bytes = 0;
    g_web.header_sent = 0;
}

static void clear_exchange(void)
{
    dispose_response();
    g_web.request_bytes = 0;
    g_web.request[0] = '\0';
    g_web.request_id = 0;
    g_web.deadline = 0;
}

static OSStatus open_worker(void)
{
    OSStatus err = -1;

    g_web.worker = gNowOT.openEndpoint(
        OTCreateConfiguration(kTCPName), 0, NULL, &err, gNowOTContext);
    if (err != noErr || g_web.worker == kOTInvalidEndpointRef) return err;
    if ((err = gNowOT.installNotifier(
             g_web.worker, g_web.notifier, &g_web.worker)) != noErr
        || (err = gNowOT.bind(g_web.worker, NULL, NULL)) != noErr
        || (err = gNowOT.setAsynchronous(g_web.worker)) != noErr
        || (err = gNowOT.setNonBlocking(g_web.worker)) != noErr) {
        close_endpoint(&g_web.worker);
        return err;
    }
    return noErr;
}

static void finish_client(void)
{
    if (g_web.request_id > 0 && g_web.deadline != 0) {
        now_wire_web_cancel(g_web.request_id);
    }
    close_endpoint(&g_web.worker);
    g_web.active = false;
    g_web.accepted = false;
    g_web.data_ready = false;
    g_web.can_send = false;
    g_web.peer_closed = false;
    clear_exchange();
    if (g_web.running && open_worker() != noErr) {
        snprintf(g_web.stage, sizeof g_web.stage,
                 "The loopback listener could not re-arm.");
        now_web_proxy_stop();
    }
}

/* Called from the notifier: record only, format later. A refusal that
   says nothing is indistinguishable from "no browser has tried yet",
   which is exactly how this module's whole failure hid. */
static void note_refusal(unsigned long peer, NowWebAcceptDecision why)
{
    g_web.refusal_seen = true;
    g_web.refusal_host = peer;
    g_web.refusal_code = why;
    ++g_web.refused_count;
}

static void refuse_call(void)
{
    if (gNowOT.sndDisconnect(g_web.listener, &g_web.call) == kOTLookErr) {
        (void)gNowOT.rcvDisconnect(g_web.listener, NULL);
    }
}

static pascal void web_notifier(void *context, OTEventCode code,
                                OTResult result, void *cookie)
{
    EndpointRef *which = (EndpointRef *)context;
    (void)result;
    (void)cookie;
    if (which == &g_web.listener) {
        if (code == T_LISTEN) {
            OTMemzero(&g_web.call, sizeof g_web.call);
            g_web.call.addr.buf = (UInt8 *)&g_web.peer;
            g_web.call.addr.maxlen = sizeof g_web.peer;
            if (gNowOT.listen(g_web.listener, &g_web.call) != noErr) return;
            {
                Boolean worker_open =
                    (Boolean)(g_web.worker != kOTInvalidEndpointRef);
                NowWebAcceptDecision decision = now_web_proxy_should_accept(
                    (unsigned long)g_web.peer.fHost, g_web.active,
                    worker_open,
                    worker_open
                        && gNowOT.getEndpointState(g_web.worker) == T_IDLE);
                if (decision == kNowWebAcceptOk
                    && gNowOT.accept(g_web.listener, g_web.worker,
                                     &g_web.call) == noErr) {
                    g_web.accepted = true;
                } else {
                    note_refusal((unsigned long)g_web.peer.fHost,
                                 decision == kNowWebAcceptOk
                                     ? kNowWebRefuseEndpointError
                                     : decision);
                    refuse_call();
                }
            }
        } else if (code == T_ACCEPTCOMPLETE && result != noErr) {
            note_refusal((unsigned long)g_web.peer.fHost,
                         kNowWebRefuseEndpointError);
            refuse_call();
        }
        return;
    }
    if (which != &g_web.worker) return;
    if (code == T_PASSCON) {
        g_web.active = true;
        g_web.accepted = false;
        g_web.can_send = true;
        clear_exchange();
    } else if (code == T_DATA) {
        g_web.data_ready = true;
    } else if (code == T_GODATA) {
        g_web.can_send = true;
    } else if (code == T_DISCONNECT || code == T_ORDREL) {
        g_web.peer_closed = true;
        g_web.data_ready = true;
    }
}

int now_web_proxy_start(unsigned short port, char *reason, long cap)
{
    OSStatus err = -1;
    InetAddress address;
    InetAddress granted;
    TBind bind;
    TBind bound;
    char host_text[24];

    if (g_web.running && g_web.port == port) return 0;
    now_web_proxy_stop();
    memset(&g_web, 0, sizeof g_web);
    g_web.listener = g_web.worker = kOTInvalidEndpointRef;
    g_web.port = port;
    if (port == 0 || now_ot_ensure_inited() != noErr) {
        snprintf(reason, (size_t)cap, "Open Transport is unavailable");
        return -1;
    }
    g_web.notifier = NewOTNotifyUPP(web_notifier);
    if (g_web.notifier == NULL) {
        snprintf(reason, (size_t)cap, "Not enough memory for Web Proxy");
        return -1;
    }
    g_web.listener = gNowOT.openEndpoint(
        OTCreateConfiguration(kTCPName), 0, NULL, &err, gNowOTContext);
    if (err != noErr || g_web.listener == kOTInvalidEndpointRef) goto fail;
    if ((err = gNowOT.installNotifier(
             g_web.listener, g_web.notifier, &g_web.listener)) != noErr)
        goto fail;
    OTInitInetAddress(&address, port, (InetHost)kLoopbackHost);
    OTMemzero(&bind, sizeof bind);
    bind.addr.buf = (UInt8 *)&address;
    bind.addr.len = sizeof address;
    bind.qlen = 1;
    /* Ask what Open Transport actually GAVE us. The shipped code passed
       NULL here and then told the page it was listening on 127.0.0.1
       because that is what it had asked for - so no boot could ever
       disagree with the request. Three lines, one boot, one bug. */
    OTMemzero(&granted, sizeof granted);
    OTMemzero(&bound, sizeof bound);
    bound.addr.buf = (UInt8 *)&granted;
    bound.addr.maxlen = sizeof granted;
    if ((err = gNowOT.bind(g_web.listener, &bind, &bound)) != noErr
        || (err = gNowOT.setAsynchronous(g_web.listener)) != noErr
        || (err = gNowOT.setNonBlocking(g_web.listener)) != noErr
        || (err = open_worker()) != noErr) goto fail;
    if (bound.addr.len >= (UInt32)sizeof granted) {
        g_web.bound_host = (unsigned long)granted.fHost;
        g_web.bound_port = granted.fPort;
        g_web.bound_known = true;
    } else {
        /* OT answered without an address. Say what was asked for, and do
           not pretend it was confirmed. */
        g_web.bound_host = (unsigned long)kLoopbackHost;
        g_web.bound_port = port;
        g_web.bound_known = false;
    }
    g_web.running = true;
    now_web_format_host(g_web.bound_host, host_text, sizeof host_text);
    now_log(kLogInfo, "web", "bind asked %u got host %s port %u%s",
            (unsigned)port, host_text, (unsigned)g_web.bound_port,
            g_web.bound_known ? "" : " (not reported)");
    snprintf(g_web.stage, sizeof g_web.stage, "Listening on %s:%u%s",
             host_text, (unsigned)g_web.bound_port,
             g_web.bound_known ? "" : " (address not confirmed)");
    return 0;
fail:
    snprintf(reason, (size_t)cap, "Could not open loopback proxy (OT %ld)",
             (long)err);
    now_web_proxy_stop();
    return -1;
}

void now_web_proxy_stop(void)
{
    if (g_web.request_id > 0 && g_web.deadline != 0) {
        now_wire_web_cancel(g_web.request_id);
    }
    if (gNowOT.closeProvider != NULL) {
        close_endpoint(&g_web.worker);
        close_endpoint(&g_web.listener);
    } else {
        g_web.worker = g_web.listener = kOTInvalidEndpointRef;
    }
    dispose_response();
    if (g_web.notifier != NULL) DisposeOTNotifyUPP(g_web.notifier);
    g_web.notifier = NULL;
    g_web.running = g_web.active = false;
}

static void read_request(void)
{
    OTFlags flags;
    while (g_web.request_bytes < kRequestCap) {
        char ignored_method[8], ignored_target[2049];
        int parsed;
        OTResult n = gNowOT.rcv(
            g_web.worker, g_web.request + g_web.request_bytes,
            (OTByteCount)(kRequestCap - g_web.request_bytes), &flags);
        if (n <= 0) break;
        g_web.request_bytes += (long)n;
        g_web.request[g_web.request_bytes] = '\0';
        parsed = now_web_proxy_parse_request(
            g_web.request, (size_t)g_web.request_bytes,
            ignored_method, sizeof ignored_method,
            ignored_target, sizeof ignored_target);
        if (parsed != kNowWebRequestIncomplete) break;
    }
    g_web.data_ready = false;
    if (g_web.request_id == 0) {
        char method[8];
        char target[2049];
        char reason[128];
        int parsed = now_web_proxy_parse_request(
            g_web.request, (size_t)g_web.request_bytes,
            method, sizeof method, target, sizeof target);

        if (parsed == kNowWebRequestIncomplete) return;
        if (parsed != kNowWebRequestReady) {
            now_web_proxy_response_end(0, false, "Invalid browser request");
            return;
        }
        if (now_wire_web_request(method, target, &g_web.request_id,
                                 reason, sizeof reason) != 0) {
            now_web_proxy_response_end(0, false, reason);
            return;
        }
        g_web.deadline = TickCount() + kResponseTimeoutTicks;
        strcpy(g_web.stage, "Loading through this Mac...");
    }
}

static int base64_value(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static long decode_base64(const char *src, unsigned char *dst, long cap)
{
    long out = 0;
    int value = 0, bits = -8;
    while (*src != '\0' && *src != '=') {
        int digit = base64_value((unsigned char)*src++);
        if (digit < 0) return -1;
        value = (value << 6) | digit;
        bits += 6;
        if (bits >= 0) {
            if (out >= cap) return -1;
            dst[out++] = (unsigned char)((value >> bits) & 0xff);
            bits -= 8;
        }
    }
    return out;
}

static void send_response(void)
{
    while (g_web.header_sent < g_web.header_bytes) {
        OTResult n = gNowOT.snd(
            g_web.worker, g_web.header + g_web.header_sent,
            (OTByteCount)(g_web.header_bytes - g_web.header_sent), 0);
        if (n == kOTFlowErr || n == kOTNoDataErr) return;
        if (n <= 0) { finish_client(); return; }
        g_web.header_sent += (long)n;
    }
    while (g_web.response_sent < g_web.response_received) {
        OTResult n = gNowOT.snd(
            g_web.worker, g_web.response + g_web.response_sent,
            (OTByteCount)(g_web.response_received - g_web.response_sent), 0);
        if (n == kOTFlowErr || n == kOTNoDataErr) return;
        if (n <= 0) { finish_client(); return; }
        g_web.response_sent += (long)n;
    }
    if (g_web.header_bytes > 0
        && g_web.response_sent == g_web.response_expected) {
        ++g_web.served_count;
        strcpy(g_web.stage, "Ready for the next browser request");
        finish_client();
    }
}

void now_web_proxy_service(void)
{
    if (!g_web.running) return;
    if (g_web.peer_closed) { finish_client(); return; }
    if (g_web.active && (g_web.data_ready || g_web.request_id == 0)) {
        read_request();
    }
    if (g_web.active && g_web.deadline != 0
        && TickCount() > g_web.deadline) {
        now_wire_web_cancel(g_web.request_id);
        /* A silence is a host observation too, and it is the guest's own,
           not a wire code. */
        strcpy(g_web.host_note, "did not answer the last page");
        now_web_proxy_response_end(g_web.request_id, false,
                                   "The host renderer did not answer");
    }
    if (g_web.active && g_web.can_send) send_response();
}

Boolean now_web_proxy_is_running(void) { return g_web.running; }
Boolean now_web_proxy_is_busy(void) { return g_web.active; }

void now_web_proxy_endpoint(char *out, long cap)
{
    char host[24];
    if (out == NULL || cap <= 0) return;
    if (!g_web.running) { out[0] = '\0'; return; }
    now_web_format_host(g_web.bound_host, host, sizeof host);
    snprintf(out, (size_t)cap, "%s:%u", host, (unsigned)g_web.bound_port);
}

void now_web_proxy_status(char *out, long cap)
{
    char text[320];
    long used;

    if (out == NULL || cap <= 0) return;
    used = (long)snprintf(text, sizeof text, "%s",
                          g_web.stage[0] != '\0'
                              ? g_web.stage : "The loopback proxy is stopped");
    if (g_web.refusal_seen) {
        char host[24];
        now_web_format_host(g_web.refusal_host, host, sizeof host);
        used += (long)snprintf(text + used, sizeof text - (size_t)used,
                               " - refused a browser request from %s (%s)",
                               host,
                               now_web_proxy_refusal_reason(g_web.refusal_code));
    } else if (g_web.running && g_web.served_count == 0 && !g_web.active) {
        /* Not decoration: silence here used to mean either "nobody has
           tried" or "every request was refused", and a browser cannot
           tell those apart either. */
        used += (long)snprintf(text + used, sizeof text - (size_t)used,
                               " - no browser has connected yet");
    }
    if (g_web.host_note[0] != '\0') {
        (void)snprintf(text + used, sizeof text - (size_t)used,
                       " - Modern Mac: %s", g_web.host_note);
    }
    strncpy(out, text, (size_t)cap - 1); out[cap - 1] = '\0';
}

void now_web_proxy_note_host(Boolean ok, const char *code, const char *reason)
{
    /* The only honest host-side status the guest has today. There is no
       host->guest Web status message in the contract, so what the modern
       Mac last SAID about a page is the evidence - and `code` was already
       declared on web.response.end and simply never read here. Absent
       means unknown, and unknown renders as nothing. */
    if (ok) {
        strcpy(g_web.host_note, "answered the last page");
        return;
    }
    if (reason != NULL && reason[0] != '\0') {
        snprintf(g_web.host_note, sizeof g_web.host_note, "%s", reason);
    } else if (code != NULL && code[0] != '\0') {
        snprintf(g_web.host_note, sizeof g_web.host_note,
                 "refused the last page (%s)", code);
    } else {
        strcpy(g_web.host_note, "refused the last page");
    }
}

void now_web_proxy_response_begin(long id, long status,
                                  const char *content_type, long bytes)
{
    if (!g_web.active || id != g_web.request_id || bytes < 0
        || bytes > kResponseCap) return;
    dispose_response();
    g_web.response = NewPtr(bytes > 0 ? bytes : 1);
    if (g_web.response == NULL) {
        now_web_proxy_response_end(id, false, "Not enough memory for this page");
        return;
    }
    g_web.response_expected = bytes;
    g_web.header_bytes = snprintf(
        g_web.header, sizeof g_web.header,
        "HTTP/1.0 %ld NOW Web\r\nContent-Type: %.95s; charset=us-ascii\r\n"
        "Content-Length: %ld\r\nCache-Control: no-store\r\n\r\n",
        status, content_type != NULL ? content_type : "text/html", bytes);
}

void now_web_proxy_response_chunk(long id, long seq, const char *base64)
{
    long decoded;
    if (id != g_web.request_id || g_web.response == NULL
        || seq != g_web.response_seq) return;
    decoded = decode_base64(
        base64, (unsigned char *)g_web.response + g_web.response_received,
        g_web.response_expected - g_web.response_received);
    if (decoded < 0) {
        now_web_proxy_response_end(id, false, "The page arrived malformed");
        return;
    }
    g_web.response_received += decoded;
    ++g_web.response_seq;
    g_web.deadline = TickCount() + kResponseTimeoutTicks;
}

void now_web_proxy_response_end(long id, Boolean ok, const char *reason)
{
    static const char failure_head[] =
        "<html><head><title>NOW Web Error</title></head><body>"
        "<h1>NOW Web could not load this page</h1><p>";
    static const char failure_tail[] = "</p></body></html>";
    long bytes;
    if (!g_web.active || (id != 0 && id != g_web.request_id)) return;
    if (ok && g_web.response != NULL
        && g_web.response_received == g_web.response_expected) {
        g_web.deadline = 0;
        g_web.can_send = true;
        return;
    }
    dispose_response();
    bytes = (long)strlen(failure_head) + (long)strlen(failure_tail)
        + (long)strlen(reason != NULL ? reason : "The service is unavailable");
    g_web.response = NewPtr(bytes);
    if (g_web.response == NULL) { finish_client(); return; }
    sprintf(g_web.response, "%s%s%s", failure_head,
            reason != NULL ? reason : "The service is unavailable",
            failure_tail);
    g_web.response_expected = g_web.response_received = bytes;
    g_web.header_bytes = snprintf(
        g_web.header, sizeof g_web.header,
        "HTTP/1.0 503 Service Unavailable\r\nContent-Type: text/html; "
        "charset=us-ascii\r\nContent-Length: %ld\r\n"
        "Cache-Control: no-store\r\n\r\n", bytes);
    g_web.deadline = 0;
    g_web.can_send = true;
}
