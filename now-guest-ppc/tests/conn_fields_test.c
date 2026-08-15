/* Native test for the Connection page's field rules. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src conn_fields_test.c \
          ../src/conn_fields.c -o conn_fields_test && ./conn_fields_test
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "conn_fields.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

int main(void)
{
    /* Addresses wire revision 1 accepts. */
    check(now_conn_ipv4_valid("10.0.2.2"), "plain quad accepted");
    check(now_conn_ipv4_valid("255.255.255.255"), "octet ceiling accepted");
    check(now_conn_ipv4_valid("0.0.0.0"), "zeros accepted");

    /* And what it must refuse. */
    check(!now_conn_ipv4_valid(""), "empty refused");
    check(!now_conn_ipv4_valid("10.0.2"), "three octets refused");
    check(!now_conn_ipv4_valid("10.0.2.2.2"), "five octets refused");
    check(!now_conn_ipv4_valid("10.0.2.256"), "octet over 255 refused");
    check(!now_conn_ipv4_valid("10.0.2.1234"), "four digits refused");
    check(!now_conn_ipv4_valid("studio-mac.local"), "hostname refused");
    check(!now_conn_ipv4_valid("10.0.2.2 "), "trailing space refused");
    check(!now_conn_ipv4_valid("10..2.2"), "empty octet refused");
    check(!now_conn_ipv4_valid("10.0.2."), "trailing dot refused");

    check(now_conn_port_parse("5250") == 5250, "port parses");
    check(now_conn_port_parse("1") == 1, "port floor");
    check(now_conn_port_parse("65535") == 65535, "port ceiling");
    check(now_conn_port_parse("0") == -1, "port zero refused");
    check(now_conn_port_parse("65536") == -1, "port overflow refused");
    check(now_conn_port_parse("52x0") == -1, "port garbage refused");
    check(now_conn_port_parse("") == -1, "port empty refused");

    /* The Retry pop-up round-trips its own values... */
    check(now_conn_retry_secs_for_item(1) == 0, "item 1 is automatic");
    check(now_conn_retry_secs_for_item(2) == 2, "item 2 is 2 s");
    check(now_conn_retry_secs_for_item(3) == 5, "item 3 is 5 s");
    check(now_conn_retry_secs_for_item(4) == 10, "item 4 is 10 s");
    check(now_conn_retry_item_for_secs(0) == 1, "0 s maps to automatic");
    check(now_conn_retry_item_for_secs(2) == 2, "2 s maps back");
    check(now_conn_retry_item_for_secs(5) == 3, "5 s maps back");
    check(now_conn_retry_item_for_secs(10) == 4, "10 s maps back");
    /* ...and an old free-form value keeps an explicit cadence. */
    check(now_conn_retry_item_for_secs(4) == 3, "4 s rounds to 5 s");
    check(now_conn_retry_item_for_secs(300) == 4, "300 s pins to 10 s");

    /* The action button's words. */
    check(strcmp(now_conn_action_title(0), "Connect") == 0,
          "disconnected reads Connect");
    check(strcmp(now_conn_action_title(1), "Disconnect") == 0,
          "connected reads Disconnect");

    /* A page created while the wire is already up. The button is born
       reading "Connect" only if nothing consulted the wire; whichever
       way, the cache must be seeded from the TITLE, so the first sync
       corrects any button whose words do not match the wire. This is
       the G8 bug: seeded from the wire, the page agreed with itself and
       lied to the human forever. */
    {
        NowConnActionTitle st;

        now_conn_action_title_init(&st, "Connect");
        check(now_conn_action_title_next(&st, 1) != NULL,
              "page created connected but reading Connect restamps");
        check(strcmp(st.shown, "Disconnect") == 0,
              "and the cache follows the restamp");
        check(now_conn_action_title_next(&st, 1) == NULL,
              "a settled title is not restamped every tick");
    }

    /* And the same page created correctly is left alone. */
    {
        NowConnActionTitle st;

        now_conn_action_title_init(&st,
                                   now_conn_action_title(1));
        check(now_conn_action_title_next(&st, 1) == NULL,
              "a title born right needs no restamp");
        check(now_conn_action_title_next(&st, 0) != NULL,
              "dropping the connection restamps");
        check(strcmp(st.shown, "Connect") == 0, "back to Connect");
    }

    /* An untouched cache (a page whose controls never got made) still
       has to stamp rather than assume. */
    {
        NowConnActionTitle st;

        now_conn_action_title_init(&st, NULL);
        check(now_conn_action_title_next(&st, 0) != NULL,
              "unknown title always restamps");
    }

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("conn_fields: all checks passed\n");
    return EXIT_SUCCESS;
}
