/* The accept decision the Web proxy's Open Transport notifier makes.
 *
 * This test exists because of one shipped condition nothing exercised:
 * the notifier required the connection's peer to be 127.0.0.1, and on
 * Mac OS 9 Open Transport reports a genuine loopback connection's peer
 * as the machine's PRIMARY interface address (observed 10.0.2.15 on the
 * emulator). Every browser request was refused, and a refusal looks to a
 * browser exactly like nothing listening. The first assertion below is
 * the one that would have caught it.
 *
 *     cc -Wall -Wextra -Werror -I ../src/web web_accept_test.c \
 *        ../src/web/web_accept.c -o /tmp/web_accept_test
 */

#include "web_accept.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *name)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", name);
        failures++;
    }
}

enum {
    kIdleWorker = 1,
    kOpenWorker = 1,
    kNotBusy = 0
};

int main(void)
{
    char text[32];

    /* The regression. 0x0a00020f is 10.0.2.15 - the address OT actually
       reported for a connection made to 127.0.0.1. */
    check(now_web_proxy_should_accept(0x0a00020fUL, kNotBusy, kOpenWorker,
                                      kIdleWorker) == kNowWebAcceptOk,
          "a non-loopback peer is accepted");
    check(now_web_proxy_should_accept(0x7f000001UL, kNotBusy, kOpenWorker,
                                      kIdleWorker) == kNowWebAcceptOk,
          "a loopback peer is accepted too");
    check(now_web_proxy_should_accept(0xc0a80114UL, kNotBusy, kOpenWorker,
                                      kIdleWorker) == kNowWebAcceptOk,
          "a LAN peer is accepted - the bind is the boundary, not this");
    check(now_web_proxy_should_accept(0UL, kNotBusy, kOpenWorker,
                                      kIdleWorker) == kNowWebAcceptOk,
          "an unreported peer address is not a reason to refuse");

    /* The conditions that DO refuse still refuse, whatever the peer. */
    check(now_web_proxy_should_accept(0x0a00020fUL, 1, kOpenWorker,
                                      kIdleWorker) == kNowWebRefuseBusy,
          "a second browser is refused while a page is loading");
    check(now_web_proxy_should_accept(0x7f000001UL, kNotBusy, 0,
                                      kIdleWorker) == kNowWebRefuseNoWorker,
          "no worker endpoint refuses");
    check(now_web_proxy_should_accept(0x7f000001UL, kNotBusy, kOpenWorker, 0)
              == kNowWebRefuseWorkerNotIdle,
          "a worker that is not T_IDLE refuses");
    /* Busy outranks the rest: it is the one a person will see. */
    check(now_web_proxy_should_accept(0x0a00020fUL, 1, 0, 0)
              == kNowWebRefuseBusy,
          "busy is reported ahead of the endpoint state");

    check(strcmp(now_web_proxy_refusal_reason(kNowWebRefuseBusy),
                 "another page was already loading") == 0,
          "a refusal has words a person can read");
    check(now_web_proxy_refusal_reason(kNowWebRefuseEndpointError)[0] != '\0',
          "an Open Transport refusal has words too");

    now_web_format_host(0x0a00020fUL, text, sizeof text);
    check(strcmp(text, "10.0.2.15") == 0, "dotted quad");
    now_web_format_host(0x7f000001UL, text, sizeof text);
    check(strcmp(text, "127.0.0.1") == 0, "loopback dotted quad");
    now_web_format_host(0xffffffffUL, text, sizeof text);
    check(strcmp(text, "255.255.255.255") == 0, "high octets do not sign-extend");
    now_web_format_host(0x0a00020fUL, text, 5);
    check(text[4] == '\0', "bounded formatting");

    if (failures) return 1;
    puts("web accept: ok");
    return 0;
}
