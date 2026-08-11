/* Native test for the Networking page's layout and row model
 * (src/network/net_layout.c).
 *
 * The rules worth pinning are not the rectangles, they are the claims the
 * page makes by including or omitting a row: an absent gateway is not
 * "0.0.0.0", a zero reset count is not a row, and the Connections
 * section offers no control because nothing can be asked.
 *
 * Mutation check, each watched failing 2026-08-01:
 *   - a gateway-less interface still counts a Router row   -> 2 fail
 *   - resets are always counted                            -> 1 fail
 *   - Connections gains a Refresh button                   -> 1 fail
 *   - a section with no rows gets zero body height         -> 1 fail
 *   - the link section requires Open Transport             -> 2 fail
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "net_layout.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* A fully-configured Mac: address, router, name server, Ethernet. */
static void fully_configured(NetFacts *f)
{
    now_net_facts_clear(f);
    f->ot = kNetFactPresent;

    f->link.state = kNetFactPresent;
    strcpy(f->link.peer, "10.91.5.2");
    f->link.port = 1400;
    f->link.up_secs = 90UL * 60UL;
    f->link.rtt_ms = 31;
    f->link.rcv_window = 8192;
    f->link.rcv_peak = 8192;
    f->link.quiet_secs = 2;
    f->link.has_rtt = 1;
    f->link.has_window = 1;

    f->inet.state = kNetFactPresent;
    strcpy(f->inet.address, "10.91.5.115");
    strcpy(f->inet.netmask, "255.255.255.0");
    strcpy(f->inet.broadcast, "10.91.5.255");
    strcpy(f->inet.gateway, "10.91.5.1");
    strcpy(f->inet.dns, "10.91.5.1");
    strcpy(f->inet.hw_address, "00:05:02:1a:2b:3c");
    f->inet.mtu = 1500;
    f->inet.has_gateway = 1;
    f->inet.has_dns = 1;
    f->inet.has_hw = 1;
    f->inet.has_mtu = 1;

    f->ports_state = kNetFactPresent;
    f->port_count = 2;
    strcpy(f->ports[0].name, "enet");
    strcpy(f->ports[0].device, "DP83916");
    strcpy(f->ports[0].slot, "E");
    strcpy(f->ports[1].name, "modem");
    strcpy(f->ports[1].device, "serial");
}

static int has_row_labelled(NetSection s, const NetFacts *f, const char *want)
{
    char label[48];
    char value[64];
    short i;
    short n = now_net_section_rows(s, f);

    for (i = 0; i < n; ++i) {
        if (now_net_row(s, f, i, label, sizeof label, value, sizeof value)
            && strcmp(label, want) == 0) {
            return 1;
        }
    }
    return 0;
}

int main(void)
{
    NetFacts f;
    NetLayout lay;
    Rect body;

    body.top = 0; body.left = 0; body.bottom = 400; body.right = 520;

    /* ---- the flat network: no router, no name server ---- */
    fully_configured(&f);
    f.inet.has_gateway = 0;
    f.inet.has_dns = 0;
    f.inet.gateway[0] = '\0';
    f.inet.dns[0] = '\0';

    check(!has_row_labelled(kNetSectionInet, &f, "Router"),
          "a Mac with no router shows no Router row");
    check(!has_row_labelled(kNetSectionInet, &f, "Name server"),
          "a Mac with no name server shows no Name server row");
    check(has_row_labelled(kNetSectionInet, &f, "Address"),
          "but it still shows its address");

    /* ---- the configured network ---- */
    fully_configured(&f);
    check(has_row_labelled(kNetSectionInet, &f, "Router"),
          "a router is shown when there is one");
    check(has_row_labelled(kNetSectionInet, &f, "Hardware address"),
          "the hardware address comes from the ordinary client call");
    check(has_row_labelled(kNetSectionInet, &f, "MTU"), "and the MTU");

    /* A round trip that has never completed is -1, and the wire keeps 0
       for "Open Transport chose the window". Both are absences, and a
       row reading "-1 ms" is a measurement that never happened wearing
       the clothes of one that did. */
    check(has_row_labelled(kNetSectionLink, &f, "Round trip"),
          "a completed ping is shown");
    f.link.has_rtt = 0;
    f.link.rtt_ms = -1;
    check(!has_row_labelled(kNetSectionLink, &f, "Round trip"),
          "a ping that never completed shows no row");
    f.link.has_window = 0;
    f.link.rcv_window = 0;
    check(!has_row_labelled(kNetSectionLink, &f, "Receive window"),
          "and OT's default window is not a measurement either");

    /* ---- the link needs no Open Transport ---- */
    fully_configured(&f);
    f.ot = kNetFactNoOT;
    f.inet.state = kNetFactNoOT;
    f.ports_state = kNetFactNoOT;
    check(now_net_section_rows(kNetSectionLink, &f) > 0,
          "the link is still measured on a Mac with no Open Transport");
    check(has_row_labelled(kNetSectionLink, &f, "Peer"),
          "and it still names its peer");
    /* No OT means no control that could work. */
    check(now_net_button_title(kNetSectionInet, &f) == NULL,
          "no Refresh is offered when Open Transport is absent");

    /* ---- Connections: one sentence, no rows, no control, ever ---- */
    fully_configured(&f);
    check(f.connections == kNetFactUndocumented,
          "connections stay undocumented even on a fully configured Mac");
    check(now_net_section_rows(kNetSectionConnections, &f) == 0,
          "the connections section has no rows");
    check(now_net_button_title(kNetSectionConnections, &f) == NULL,
          "and no button - nothing can be asked, so nothing is offered");

    /* ---- the count and the rows must agree ----
       now_net_section_rows and now_net_row guard their fields
       SEPARATELY, so a count that is one too high yields a card with a
       blank line at the bottom and a layout taller than its content.
       net_layout.h claims the two cannot disagree; this is what makes
       that true. Found by a mutation that survived: inflating the TCP/IP
       count passed every other check in this file. */
    {
        static const NetFacts *cases[3];
        NetFacts flat;
        NetFacts full;
        NetFacts bare;
        int c;

        fully_configured(&full);
        fully_configured(&flat);
        flat.inet.has_gateway = 0;
        flat.inet.has_dns = 0;
        flat.inet.has_hw = 0;
        flat.inet.has_mtu = 0;
        now_net_facts_clear(&bare);

        cases[0] = &full;
        cases[1] = &flat;
        cases[2] = &bare;

        for (c = 0; c < 3; ++c) {
            int s;
            for (s = 0; s < (int)kNetSectionCount; ++s) {
                short n = now_net_section_rows((NetSection)s, cases[c]);
                short i;
                char label[48];
                char value[64];

                for (i = 0; i < n; ++i) {
                    if (!now_net_row((NetSection)s, cases[c], i,
                                     label, sizeof label,
                                     value, sizeof value)) {
                        fprintf(stderr, "FAIL: case %d section %d claims %d "
                                        "rows but row %d does not exist\n",
                                c, s, (int)n, (int)i);
                        ++g_failures;
                    } else if (label[0] == '\0') {
                        fprintf(stderr, "FAIL: case %d section %d row %d has "
                                        "no label\n", c, s, (int)i);
                        ++g_failures;
                    }
                }
                /* And one past the end must refuse, so the count is a
                   ceiling rather than a suggestion. */
                check(!now_net_row((NetSection)s, cases[c], n,
                                   label, sizeof label, value, sizeof value),
                      "one past the last row does not exist");
            }
        }
    }

    /* ---- layout: every section has a body, including the empty one ---- */
    now_net_layout_compute(&body, &f, &lay);
    {
        int i;
        for (i = 0; i < (int)kNetSectionCount; ++i) {
            const NetSectionLayout *s = &lay.sections[i];
            check(s->card.bottom > s->card.top, "every card has height");
            check(s->body.bottom > s->body.top,
                  "every card has a body - including the one that is "
                  "nothing but a sentence");
            check(s->card.right > s->card.left, "and width");
        }
        check(lay.content_height > 0, "the page has content height");
        check(lay.scrollbar.left == lay.canvas.right,
              "the scrollbar sits against the canvas");
    }

    /* A button never overlaps its title. */
    {
        const NetSectionLayout *s = &lay.sections[kNetSectionInet];
        check(s->button.right > s->button.left, "TCP/IP has a Refresh button");
        check(s->title.right <= s->button.left,
              "and the title stops before it");
    }

    /* ---- the placard ---- */
    {
        char st[96];

        fully_configured(&f);
        now_net_status_text(&f, st, sizeof st);
        check(strstr(st, "10.91.5.115") != NULL,
              "the placard leads with the address");

        f.ot = kNetFactNoOT;
        now_net_status_text(&f, st, sizeof st);
        check(strstr(st, "Open Transport") != NULL,
              "and names Open Transport when it is missing");

        now_net_facts_clear(&f);
        f.ot = kNetFactPresent;
        f.inet.state = kNetFactRefused;
        now_net_status_text(&f, st, sizeof st);
        check(strstr(st, "not configured") != NULL,
              "an unconfigured stack is not an error");
    }

    /* Degenerate inputs. */
    {
        char l[8];
        char v[8];

        check(now_net_row(kNetSectionInet, NULL, 0, l, sizeof l, v, sizeof v)
                  == 0, "no facts yields no row");
        check(now_net_row(kNetSectionInet, &f, -1, l, sizeof l, v, sizeof v)
                  == 0, "a negative index yields no row");
        check(now_net_section_rows(kNetSectionInet, NULL) == 0,
              "no facts yields no rows");
        now_net_layout_compute(NULL, &f, &lay);   /* must not crash */
        now_net_status_text(&f, NULL, 0);         /* must not crash */
    }

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("net_layout: all checks passed\n");
    return EXIT_SUCCESS;
}
