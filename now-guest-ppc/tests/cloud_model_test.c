/* The iCloud page's parsers, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/core -I ../src/cloud \
        cloud_model_test.c ../src/cloud/cloud_model.c ../src/core/json.c \
        -o /tmp/t && /tmp/t
   Three things are worth proving off-metal: a report fills the
   dropdown's model whatever the states are, listing pages accumulate
   and stale answers drop, and card rows survive the [label, value]
   shape including MacRoman decoding. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "cloud_model.h"

static void test_report_fills_services_whatever_their_state(void)
{
    CloudStore store;
    int n;

    cloud_store_reset(&store);
    n = cloud_parse_report(
        "{\"type\":\"cloud.report\",\"id\":4,\"services\":["
        "{\"service\":\"drive\",\"label\":\"iCloud Drive\","
        "\"state\":\"serving\",\"detail\":\"Shared - browse it in Files\"},"
        "{\"service\":\"photos\",\"label\":\"Photos\","
        "\"state\":\"no-access\",\"detail\":\"Grant access on the host\"},"
        "{\"service\":\"contacts\",\"label\":\"Contacts\","
        "\"state\":\"off\"}]}",
        &store);
    assert(n == 3);
    assert(strcmp(store.services[0].service, "drive") == 0);
    assert(strcmp(store.services[1].state, "no-access") == 0);
    assert(strcmp(store.services[2].label, "Contacts") == 0);
    assert(store.services[2].detail[0] == '\0');

    /* Drive serves but is not listable; photos is listable but not
       serving. Nothing qualifies. */
    assert(cloud_first_listable(&store) == -1);

    /* Flip photos to serving and it becomes the initial selection. */
    strcpy(store.services[1].state, "serving");
    assert(cloud_first_listable(&store) == 1);
}

static void test_listing_accumulates_and_drops_stale_answers(void)
{
    CloudStore store;
    int n;

    cloud_store_reset(&store);
    cloud_store_reset_rows(&store, "photos");
    n = cloud_parse_listing(
        "{\"type\":\"cloud.listing\",\"id\":5,\"service\":\"photos\","
        "\"entries\":[{\"item\":\"a-1\",\"title\":\"IMG_1234.jpg\","
        "\"subtitle\":\"Jul 4, 2026\",\"bytes\":2048000},"
        "{\"item\":\"a-2\",\"title\":\"IMG_1233.jpg\"}],"
        "\"more\":true,\"cursor\":3}",
        &store);
    assert(n == 2);
    assert(store.row_count == 2);
    assert(store.more);
    assert(store.cursor == 3);
    assert(store.rows[0].bytes == 2048000);

    /* The next page APPENDS. */
    n = cloud_parse_listing(
        "{\"type\":\"cloud.listing\",\"id\":6,\"service\":\"photos\","
        "\"entries\":[{\"item\":\"a-3\",\"title\":\"IMG_1232.jpg\"}],"
        "\"more\":false,\"cursor\":4}",
        &store);
    assert(n == 1);
    assert(store.row_count == 3);
    assert(!store.more);

    /* An answer for a service the person has switched away from is
       stale, not data. */
    cloud_store_reset_rows(&store, "contacts");
    n = cloud_parse_listing(
        "{\"type\":\"cloud.listing\",\"id\":7,\"service\":\"photos\","
        "\"entries\":[{\"item\":\"a-9\",\"title\":\"late.jpg\"}],"
        "\"more\":false}",
        &store);
    assert(n == 0);
    assert(store.row_count == 0);
}

static void test_rows_without_identity_or_title_are_skipped(void)
{
    CloudStore store;

    cloud_store_reset(&store);
    cloud_store_reset_rows(&store, "contacts");
    cloud_parse_listing(
        "{\"type\":\"cloud.listing\",\"id\":8,\"service\":\"contacts\","
        "\"entries\":[{\"title\":\"No id\"},{\"item\":\"c-2\"},"
        "{\"item\":\"c-3\",\"title\":\"Ada Lovelace\"}],"
        "\"more\":false}",
        &store);
    assert(store.row_count == 1);
    assert(strcmp(store.rows[0].item, "c-3") == 0);
}

static void test_card_rows_decode_the_pair_shape(void)
{
    CloudStore store;
    int n;

    cloud_store_reset(&store);
    n = cloud_parse_card(
        "{\"type\":\"cloud.card\",\"id\":9,\"service\":\"contacts\","
        "\"item\":\"c-3\",\"rows\":[[\"Name\",\"Ada Lovelace\"],"
        "[\"work\",\"ada@example.com\"],"
        "[\"home\",\"caf\\u00e9 street 12\"]]}",
        &store);
    assert(n == 3);
    assert(strcmp(store.card_item, "c-3") == 0);
    assert(strcmp(store.card[0].label, "Name") == 0);
    assert(strcmp(store.card[1].value, "ada@example.com") == 0);
    /* é arrives as one MacRoman byte, not two UTF-8 ones. */
    assert(strcmp(store.card[2].value, "caf\x8e street 12") == 0);
}

static void test_malformed_frames_read_as_zero(void)
{
    CloudStore store;

    cloud_store_reset(&store);
    assert(cloud_parse_report("{\"type\":\"cloud.report\"}", &store) == 0);
    cloud_store_reset_rows(&store, "photos");
    assert(cloud_parse_listing(
        "{\"type\":\"cloud.listing\",\"service\":\"photos\","
        "\"entries\":[{\"item\":\"x\",\"title\":\"y\"", &store) == 0);
    assert(cloud_parse_card("{\"rows\":[[", &store) == 0);
}

int main(void)
{
    test_report_fills_services_whatever_their_state();
    test_listing_accumulates_and_drops_stale_answers();
    test_rows_without_identity_or_title_are_skipped();
    test_card_rows_decode_the_pair_shape();
    test_malformed_frames_read_as_zero();
    printf("cloud_model_test: all assertions passed\n");
    return 0;
}
