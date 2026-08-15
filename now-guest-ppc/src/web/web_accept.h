#ifndef NOW_WEB_ACCEPT_H
#define NOW_WEB_ACCEPT_H

/* The Web proxy's accept decision, lifted out of the Open Transport
   notifier so the host compiler can exercise it.

   Toolbox-free on purpose. The defect this seam exists for was a peer
   address condition in the notifier that nothing could reach without a
   Macintosh: on Mac OS 9 Open Transport reports a loopback connection's
   peer as the machine's PRIMARY interface address (observed 10.0.2.15),
   so `peer == 127.0.0.1` refused every real browser and looked exactly
   like nothing listening. */

typedef enum {
    kNowWebAcceptOk = 0,
    kNowWebRefuseBusy,
    kNowWebRefuseNoWorker,
    kNowWebRefuseWorkerNotIdle,
    /* Never returned by now_web_proxy_should_accept: recorded when Open
       Transport itself declines a call the decision had approved. It
       shares this table so a refusal has exactly one place to get its
       words from. */
    kNowWebRefuseEndpointError
} NowWebAcceptDecision;

/* peer_host is deliberately NOT part of the decision. The bind to
   127.0.0.1 is the network boundary — measured to be one — and the peer
   address is recorded, never judged. It is a parameter so a test can
   assert precisely that a non-loopback peer is still accepted. */
NowWebAcceptDecision now_web_proxy_should_accept(unsigned long peer_host,
                                                 int busy,
                                                 int worker_open,
                                                 int worker_idle);

/* Human words for a refusal, for the Web page's status area. */
const char *now_web_proxy_refusal_reason(NowWebAcceptDecision decision);

/* Dotted quad of a host address in host byte order. */
void now_web_format_host(unsigned long host, char *out, long cap);

#endif /* NOW_WEB_ACCEPT_H */
