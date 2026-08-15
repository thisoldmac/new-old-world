#include "web_accept.h"

#include <stdio.h>

NowWebAcceptDecision now_web_proxy_should_accept(unsigned long peer_host,
                                                 int busy,
                                                 int worker_open,
                                                 int worker_idle)
{
    /* Recorded by the caller, not judged here. See the header. */
    (void)peer_host;
    if (busy) return kNowWebRefuseBusy;
    if (!worker_open) return kNowWebRefuseNoWorker;
    if (!worker_idle) return kNowWebRefuseWorkerNotIdle;
    return kNowWebAcceptOk;
}

const char *now_web_proxy_refusal_reason(NowWebAcceptDecision decision)
{
    switch (decision) {
    case kNowWebAcceptOk: return "accepted";
    case kNowWebRefuseBusy: return "another page was already loading";
    case kNowWebRefuseNoWorker: return "no connection was free";
    case kNowWebRefuseWorkerNotIdle: return "the last connection had not closed";
    default: return "Open Transport declined the connection";
    }
}

void now_web_format_host(unsigned long host, char *out, long cap)
{
    if (out == NULL || cap <= 0) return;
    snprintf(out, (size_t)cap, "%lu.%lu.%lu.%lu",
             (host >> 24) & 0xffUL, (host >> 16) & 0xffUL,
             (host >> 8) & 0xffUL, host & 0xffUL);
}
