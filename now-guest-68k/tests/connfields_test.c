/* Host-side test for the Connection tab field validators.
 *
 *   cc -std=c99 -Wall -Wextra -Werror -pedantic \
 *      connfields.c connfields_test.c -o connfields_test && ./connfields_test
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "connfields.h"

static int g_checks;

/* Every assertion below pins the REASON string, not just ok/fail - a
 * validator that rejects everything for the wrong reason passes a
 * bare ok-check just as easily as a correct one. */
static void expect_ok_host(const char *text, unsigned long addr)
{
    ConnHostResult r = now_conn_host_validate(text);
    g_checks++;
    if (!r.ok || r.addr != addr || strcmp(r.reason, "ok") != 0) {
        fprintf(stderr, "FAIL host accept \"%s\": ok=%d addr=%lu reason=\"%s\"\n",
                text, r.ok, r.addr, r.reason);
        assert(0);
    }
}

static void expect_fail_host(const char *text, const char *reason)
{
    ConnHostResult r = now_conn_host_validate(text);
    g_checks++;
    if (r.ok || strcmp(r.reason, reason) != 0) {
        fprintf(stderr, "FAIL host reject \"%s\": ok=%d reason=\"%s\" (want \"%s\")\n",
                text, r.ok, r.reason, reason);
        assert(0);
    }
}

static void expect_ok_port(const char *text, unsigned short port)
{
    ConnPortResult r = now_conn_port_validate(text);
    g_checks++;
    if (!r.ok || r.port != port || strcmp(r.reason, "ok") != 0) {
        fprintf(stderr, "FAIL port accept \"%s\": ok=%d port=%u reason=\"%s\"\n",
                text, r.ok, r.port, r.reason);
        assert(0);
    }
}

static void expect_fail_port(const char *text, const char *reason)
{
    ConnPortResult r = now_conn_port_validate(text);
    g_checks++;
    if (r.ok || strcmp(r.reason, reason) != 0) {
        fprintf(stderr, "FAIL port reject \"%s\": ok=%d reason=\"%s\" (want \"%s\")\n",
                text, r.ok, r.reason, reason);
        assert(0);
    }
}

static void expect_ok_timeout(const char *text, short seconds)
{
    ConnTimeoutResult r = now_conn_timeout_validate(text);
    g_checks++;
    if (!r.ok || r.seconds != seconds || strcmp(r.reason, "ok") != 0) {
        fprintf(stderr, "FAIL timeout accept \"%s\": ok=%d s=%d reason=\"%s\"\n",
                text, r.ok, r.seconds, r.reason);
        assert(0);
    }
}

static void expect_fail_timeout(const char *text, const char *reason)
{
    ConnTimeoutResult r = now_conn_timeout_validate(text);
    g_checks++;
    if (r.ok || strcmp(r.reason, reason) != 0) {
        fprintf(stderr, "FAIL timeout reject \"%s\": ok=%d reason=\"%s\" (want \"%s\")\n",
                text, r.ok, r.reason, reason);
        assert(0);
    }
}

int main(void)
{
    /* ---- Host: acceptance ---- */
    expect_ok_host("10.0.2.2", 0x0A000202UL);
    expect_ok_host("255.255.255.255", 0xFFFFFFFFUL);
    expect_ok_host("0.0.0.0", 0x00000000UL);
    expect_ok_host("192.168.1.1", 0xC0A80101UL);
    expect_ok_host("1.2.3.4", 0x01020304UL);

    /* ---- Host: rejection, one case per named failure mode ---- */
    expect_fail_host("", "address is empty");
    expect_fail_host("10.0.2", "too few octets");                /* too few octets */
    expect_fail_host("10.0.2.2.2", "too many octets");           /* too many octets */
    expect_fail_host("10.0.2.256", "octet over 255");            /* over-255 octet */
    expect_fail_host("310.0.2.2", "octet over 255");             /* over-255 first octet */
    expect_fail_host("10.0.2.1234", "octet has too many digits");/* 4-digit octet */

    /* A leading zero on a multi-digit octet is ACCEPTED and read as
     * decimal. This pins agreement with the shipping PPC guest's
     * now_conn_ipv4_valid (now/now-guest-ppc/src/connection/conn_fields.c), which parses
     * octets by hand the same way (never calls scanf, never branches
     * on a base prefix) and has always accepted "010" as 10. A change
     * to either parser that reintroduces a leading-zero rejection, or
     * that starts reading it as octal, must fail here - the two NOW
     * clients must not disagree about whether the same address on the
     * same LAN is valid. */
    expect_ok_host("10.0.02.2", 0x0A000202UL);   /* leading zero, interior octet */
    expect_ok_host("010.0.2.2", 0x0A000202UL);   /* leading zero, first octet */
    expect_ok_host("192.168.001.010", 0xC0A8010AUL); /* same address the PPC guest accepts */

    expect_fail_host("10..2.2", "empty octet");                  /* empty octet mid-string */
    expect_fail_host("10.0.2.", "empty octet");                  /* trailing dot */
    expect_fail_host(".10.0.2.2", "empty octet");                /* leading dot */
    expect_fail_host("10.0.2.2 ", "trailing garbage");           /* trailing space */
    expect_fail_host("10.0.2.2x", "trailing garbage");           /* trailing char */
    expect_fail_host(" 10.0.2.2", "non-digit character");        /* leading space */
    expect_fail_host("studio-mac.local", "non-digit character"); /* hostname, no DNS */
    expect_fail_host("-1.0.0.1", "non-digit character");         /* negative */
    expect_fail_host("a.b.c.d", "non-digit character");          /* all garbage */

    /* ---- Port: acceptance, including the NOT-floored-at-1024 choice ---- */
    expect_ok_port("5250", kNowDefaultHostPort);   /* the NOW contract default */
    expect_ok_port("1", 1);                        /* floor: 1, deliberately not 1024 */
    expect_ok_port("80", 80);                       /* below 1024 - dial-out, not a bind */
    expect_ok_port("65535", 65535);                 /* ceiling */

    /* ---- Port: rejection ---- */
    expect_fail_port("", "port is empty");
    expect_fail_port("0", "port must be at least 1");
    expect_fail_port("65536", "port over 65535");
    expect_fail_port("999999", "port over 65535");
    expect_fail_port("52x0", "non-digit character");
    expect_fail_port(" 5250", "non-digit character");
    expect_fail_port("5250 ", "non-digit character"); /* trailing space is a non-digit char */

    /* ---- Connect timeout: acceptance ---- */
    expect_ok_timeout("15", kConnTimeoutDefaultSecs);
    expect_ok_timeout("1", kConnTimeoutMinSecs);
    expect_ok_timeout("60", kConnTimeoutMaxSecs);

    /* ---- Connect timeout: rejection ---- */
    expect_fail_timeout("", "timeout is empty");
    expect_fail_timeout("0", "timeout must be at least 1 s");
    expect_fail_timeout("61", "timeout over 60 s");
    expect_fail_timeout("999", "timeout over 60 s");
    expect_fail_timeout("5s", "non-digit character");

    printf("connfields: %d checks passed\n", g_checks);
    return 0;
}
