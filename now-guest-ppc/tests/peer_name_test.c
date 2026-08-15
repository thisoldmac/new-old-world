/* Native (host-side) test for now-guest-ppc/src/core/peer_name.c.

   G-8: the guest calls itself "This Mac" and the connected machine by
   its own reported name, falling back to "Other Mac" when disconnected
   or unnamed - never the retired "the other Mac" phrasing. The fallback
   is the one rule worth pinning here; a test cannot fake a live wire, so
   the function takes the fact (`raw_peer_name`) instead of reaching for
   one - the same shape as wire_sleep_test.c next to it. */

#include <assert.h>
#include <string.h>
#include <stdio.h>

#include "peer_name.h"

static void test_self_is_always_this_mac(void)
{
    char out[32];

    now_self_name(out, sizeof out);
    assert(strcmp(out, "This Mac") == 0);
}

static void test_known_peer_uses_its_reported_name(void)
{
    char out[64];

    now_peer_name("Power Mac G3", out, sizeof out);
    assert(strcmp(out, "Power Mac G3") == 0);
}

static void test_empty_peer_falls_back_to_other_mac(void)
{
    char out[32];

    now_peer_name("", out, sizeof out);
    assert(strcmp(out, "Other Mac") == 0);
}

static void test_null_peer_falls_back_to_other_mac(void)
{
    /* NULL is treated the same as "" - "no name known" has one spelling,
       not two a caller could get half right. */
    char out[32];

    now_peer_name(NULL, out, sizeof out);
    assert(strcmp(out, "Other Mac") == 0);
}

static void test_fallback_is_never_the_retired_phrasing(void)
{
    /* The regression this exists to catch: "the other Mac" (lowercase,
       with the article) is the phrasing G-8 retires. A future edit that
       reintroduces it anywhere near this function should fail here
       first, not get discovered by someone reading a status line. */
    char out[32];

    now_peer_name(NULL, out, sizeof out);
    assert(strstr(out, "the other") == NULL);
    assert(strcmp(out, "Other Mac") == 0);
}

static void test_truncation_is_bounded_not_undefined(void)
{
    char out[6];

    now_peer_name("A Very Long Machine Name", out, sizeof out);
    assert(strlen(out) == 5);          /* cap - 1 */

    now_peer_name(NULL, out, sizeof out);
    assert(strlen(out) <= 5);
}

int main(void)
{
    test_self_is_always_this_mac();
    test_known_peer_uses_its_reported_name();
    test_empty_peer_falls_back_to_other_mac();
    test_null_peer_falls_back_to_other_mac();
    test_fallback_is_never_the_retired_phrasing();
    test_truncation_is_bounded_not_undefined();
    printf("peer_name_test: all assertions passed\n");
    return 0;
}
