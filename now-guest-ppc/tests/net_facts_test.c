/* Native test for the networking module's value core (src/network/net_facts.c).
 *
 * The Open Transport calls cannot run here, which is exactly why this
 * file exists: the things most likely to be wrong on a networking page
 * are not the API calls, they are the arithmetic (a byte order), the
 * formatting (a duration), and the vocabulary of ABSENCE — and all three
 * are reachable from the host's cc with no Macintosh in the loop.
 *
 * Mutation check, each watched failing 2026-08-01:
 *   - clear() leaves `connections` as Present            -> 2 fail
 *   - clear() leaves the plane states as Present         -> 1 fail
 *   - format_ip walks the bytes in the other order       -> 2 fail
 *   - the Undocumented sentence says "unavailable"       -> 1 fail
 *   - uptime rounds seconds up into minutes              -> 1 fail
 *   - two states share one token                         -> 1 fail
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "net_facts.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL: %s (got \"%s\", want \"%s\")\n", what, got, want);
        ++g_failures;
    }
}

static void ip_is(unsigned long addr, const char *want, const char *what)
{
    char buf[kNetAddrMax];

    now_net_format_ip(addr, buf, sizeof buf);
    check_str(buf, want, what);
}

static void uptime_is(unsigned long secs, const char *want, const char *what)
{
    char buf[24];

    now_net_format_duration(secs, buf, sizeof buf);
    check_str(buf, want, what);
}

int main(void)
{
    NetFacts f;

    /* ---- a cleared NetFacts describes an unasked Mac, not a dead one ---- */
    memset(&f, 0xAB, sizeof f);          /* poison, so clear() must write */
    now_net_facts_clear(&f);

    check(f.ot == kNetFactNotServed, "cleared: OT is not-served, not present");
    check(f.link.state == kNetFactNotServed, "cleared: link is not-served");
    check(f.inet.state == kNetFactNotServed, "cleared: interface is not-served");
    check(f.ports_state == kNetFactNotServed, "cleared: ports are not-served");
    check(f.port_count == 0, "cleared: no ports claimed");

    /* The one fact known before any probe, and known permanently. It must
       NOT read as not-served: nothing will ever serve it, and a page that
       says "not measured yet" invites someone to go looking for the
       button that measures it. */
    check(f.connections == kNetFactUndocumented,
          "cleared: the connection table is undocumented, not unmeasured");

    /* ---- the byte order, which is wrong on the first try ---- */
    ip_is(0x0A5B0573UL, "10.91.5.115", "an address off this lab's network");
    ip_is(0x7F000001UL, "127.0.0.1", "loopback");
    ip_is(0xFFFFFF00UL, "255.255.255.0", "a netmask, where every byte is high");
    ip_is(0x00000000UL, "0.0.0.0", "the unset address still formats");
    /* Asymmetric on purpose: a palindromic address would pass with the
       bytes walked in either direction, which is the mutation this is
       here to catch. */
    ip_is(0x01020304UL, "1.2.3.4", "an asymmetric address pins the direction");

    /* ---- durations, the page's one moving number ---- */
    uptime_is(0UL, "0s", "a link that just came up");
    uptime_is(59UL, "59s", "just under a minute stays in seconds");
    uptime_is(60UL, "1m", "exactly a minute");
    uptime_is(90UL * 60UL, "1h 30m", "hours carry their minutes");
    uptime_is(2UL * 3600UL, "2h", "a whole hour drops the zero");
    /* Four seconds is not "1m". The page would rather say a small true
       thing than a rounder false one. */
    uptime_is(4UL, "4s", "seconds do not round up into minutes");

    /* ---- absence has a vocabulary, and the words matter ---- */
    check(now_net_state_sentence(kNetFactPresent)[0] == '\0',
          "a present fact needs no sentence");
    check(strstr(now_net_state_sentence(kNetFactNoOT), "CarbonLib") != NULL,
          "the OT-absent sentence names the fix");

    /* The sentence a person reads when we cannot list connections must
       exonerate the machine. "Unavailable" reads as a broken Mac; the
       truth is that Open Transport publishes no way to ask. */
    check(strstr(now_net_state_sentence(kNetFactUndocumented),
                 "Not a fault on this Mac") != NULL,
          "the undocumented sentence exonerates the machine");
    check(strstr(now_net_state_sentence(kNetFactUndocumented),
                 "Open Transport") != NULL,
          "and names what is actually missing");

    /* ---- tokens are a matched surface; a collision is silent ---- */
    {
        const NetFactState all[] = { kNetFactPresent, kNetFactNoOT,
                                     kNetFactRefused, kNetFactNotServed,
                                     kNetFactUndocumented };
        int i;
        int j;
        int n = (int)(sizeof all / sizeof all[0]);

        for (i = 0; i < n; ++i) {
            check(now_net_state_token(all[i])[0] != '\0',
                  "every state has a token");
            for (j = i + 1; j < n; ++j) {
                if (strcmp(now_net_state_token(all[i]),
                           now_net_state_token(all[j])) == 0) {
                    fprintf(stderr, "FAIL: two states share the token \"%s\"\n",
                            now_net_state_token(all[i]));
                    ++g_failures;
                }
            }
        }
    }

    /* ---- hardware addresses, where the length is not six ---- */
    {
        static const unsigned char enet[6] =
            { 0x00, 0x05, 0x02, 0x1A, 0x2B, 0x3C };
        static const unsigned char shortaddr[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
        char buf[kNetNameMax];
        char small[8];

        now_net_format_hw(enet, 6, buf, sizeof buf);
        check_str(buf, "00:05:02:1a:2b:3c", "a six-byte Ethernet address");

        /* OT hands fHWAddrLen alongside the pointer and does not promise
           six. A formatter that assumes Ethernet reads two bytes past a
           four-byte address, which is a read off the end of somebody
           else's memory rather than a cosmetic bug. */
        now_net_format_hw(shortaddr, 4, buf, sizeof buf);
        check_str(buf, "de:ad:be:ef", "a four-byte address stops at four");

        /* Half an address is indistinguishable from a whole one, so a
           buffer that cannot hold the result yields nothing at all. */
        now_net_format_hw(enet, 6, small, (long)sizeof small);
        check_str(small, "", "a too-small buffer refuses rather than truncates");

        now_net_format_hw(NULL, 6, buf, sizeof buf);
        check_str(buf, "", "no address is an empty string, not a crash");
        now_net_format_hw(enet, 0, buf, sizeof buf);
        check_str(buf, "", "a zero-length address writes nothing");
    }

    /* Degenerate inputs fail closed rather than writing past a buffer. */
    {
        char tiny[4];

        now_net_format_ip(0x0A5B0573UL, tiny, (long)sizeof tiny);
        check(tiny[sizeof tiny - 1] == '\0', "a short buffer stays terminated");
        now_net_format_duration(600UL, tiny, (long)sizeof tiny);
        check(tiny[sizeof tiny - 1] == '\0', "uptime respects its cap too");
        now_net_format_ip(0UL, NULL, 0);      /* must not crash */
        now_net_facts_clear(NULL);            /* must not crash */
    }

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("net_facts: all checks passed\n");
    return EXIT_SUCCESS;
}
