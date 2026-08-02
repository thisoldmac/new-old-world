/* The iCloud page's parsers, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/core -I ../src/cloud \
        cloud_model_test.c ../src/cloud/cloud_model.c ../src/core/json.c \
        -o /tmp/t && /tmp/t
   Four things are worth proving off-metal: a report fills the
   dropdown's model whatever the states are, listing pages accumulate
   and stale answers drop, card rows survive the [label, value] shape
   including MacRoman decoding, and a capped listing reads honestly as
   a bounded prefix of a larger library, not as the whole of it. */

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

static void fill_rows(CloudStore *store, const char *service, int n,
                      Boolean more)
{
    int i;

    cloud_store_reset_rows(store, service);
    for (i = 0; i < n && i < kCloudMaxRows; ++i) {
        CloudRow *row = &store->rows[store->row_count];

        memset(row, 0, sizeof *row);
        sprintf(row->item, "a-%d", i);
        strcpy(row->title, "row");
        ++store->row_count;
    }
    store->more = more;
}

static void test_status_reads_a_capped_photo_library_as_a_prefix(void)
{
    CloudStore store;
    char line[64];

    cloud_store_reset(&store);

    /* Hitting the cap while the host still has more must never read as
       "the whole list" - the difference this task exists to fix. */
    fill_rows(&store, "photos", kCloudMaxRows, 1);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "128 of many, newest first") == 0);

    /* A service whose order this store does not know gets the honest
       generic wording, not a borrowed claim about order. */
    fill_rows(&store, "contacts", kCloudMaxRows, 1);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "128 of many (more not shown)") == 0);

    /* Finishing under the cap - an ordinary count, no "many" language:
       this store genuinely holds everything the host has. */
    fill_rows(&store, "photos", 40, 0);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "40 rows") == 0);

    fill_rows(&store, "photos", 1, 0);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "1 row") == 0);

    fill_rows(&store, "photos", 0, 0);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "Empty") == 0);

    /* more==true but still under the cap is the auto-paging state the
       module itself intercepts before ever calling this - not this
       function's case to get right, but it must not crash or claim
       "many" before the cap is actually reached. */
    fill_rows(&store, "photos", 64, 1);
    cloud_listing_status(&store, line, sizeof line);
    assert(strcmp(line, "64 rows") == 0);
}

static void test_size_popup_maps_items_to_contract_tokens(void)
{
    /* MENU 136's order is load-bearing: 1-3 are the contract's three
       tokens, 4 (Host default) and anything the popup cannot produce
       are NULL — the omitted field, which asks for the host's own
       setting rather than inventing one. */
    assert(strcmp(cloud_size_token(1), "original") == 0);
    assert(strcmp(cloud_size_token(2), "fit1024") == 0);
    assert(strcmp(cloud_size_token(3), "fit640") == 0);
    assert(cloud_size_token(4) == 0);
    assert(cloud_size_token(0) == 0);
    assert(cloud_size_token(5) == 0);
    assert(cloud_size_token(-1) == 0);
}

static void test_dl_bar_value_scales_and_clamps(void)
{
    /* No honest total = no honest bar: -1 says "do not show one". */
    assert(cloud_dl_bar_value(0, 0) == -1);
    assert(cloud_dl_bar_value(500, -3) == -1);

    /* The 0..1000 scale, exact in the small range... */
    assert(cloud_dl_bar_value(0, 400) == 0);
    assert(cloud_dl_bar_value(200, 400) == 500);
    assert(cloud_dl_bar_value(1, 1000) == 1);
    assert(cloud_dl_bar_value(400, 400) == 1000);
    assert(cloud_dl_bar_value(500, 400) == 1000);

    /* ...and within one part in fifty past the exact-arithmetic range
       (a 3MB photo mid-transfer), never past the end of the scale.
       long is 32 bits on the guest toolchain, which is why the exact
       form cannot simply be used everywhere. */
    {
        int v = cloud_dl_bar_value(3000000, 6000000);

        assert(v >= 490 && v <= 510);
    }
    assert(cloud_dl_bar_value(5999999, 6000000) <= 1000);
    assert(cloud_dl_bar_value(5999999, 6000000) >= 990);
}

static void test_dl_bytes_line_reads_kilobytes(void)
{
    char line[48];

    cloud_dl_bytes_line(319488, 3276800, line, sizeof line);
    assert(strcmp(line, "312K of 3200K") == 0);

    /* Rounded UP so a transfer never claims 0K of something real. */
    cloud_dl_bytes_line(1, 1025, line, sizeof line);
    assert(strcmp(line, "1K of 2K") == 0);

    /* An unstated total states only what has landed. */
    cloud_dl_bytes_line(2048, 0, line, sizeof line);
    assert(strcmp(line, "2K") == 0);

    cloud_dl_bytes_line(0, 4096, line, sizeof line);
    assert(strcmp(line, "0K of 4K") == 0);
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
    test_status_reads_a_capped_photo_library_as_a_prefix();
    test_size_popup_maps_items_to_contract_tokens();
    test_dl_bar_value_scales_and_clamps();
    test_dl_bytes_line_reads_kilobytes();
    test_malformed_frames_read_as_zero();
    printf("cloud_model_test: all assertions passed\n");
    return 0;
}
