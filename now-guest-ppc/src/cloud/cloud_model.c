#include "cloud_model.h"

#include <stdio.h>
#include <string.h>

#include "json.h"

/* The iCloud page's store: parsers only, no Toolbox, so the whole file
   runs under the host cc (cloud_model_test.c). Strings a person reads
   come through now_json_find_text and arrive MacRoman; protocol tokens
   (service keys, states, item ids) come through find_string and stay
   ASCII, because they go back on the wire verbatim. */

void cloud_store_reset(CloudStore *store)
{
    memset(store, 0, sizeof *store);
    store->cursor = 1;
}

void cloud_store_reset_rows(CloudStore *store, const char *service)
{
    store->row_count = 0;
    store->more = 0;
    store->cursor = 1;
    store->listed_service[0] = '\0';
    if (service != NULL) {
        strncpy(store->listed_service, service,
                sizeof store->listed_service - 1);
        store->listed_service[sizeof store->listed_service - 1] = '\0';
    }
    cloud_store_reset_card(store);
}

void cloud_store_reset_card(CloudStore *store)
{
    store->card_count = 0;
    store->card_item[0] = '\0';
}

int cloud_parse_report(const char *reply, CloudStore *store)
{
    char object[256];
    const char *p;

    store->service_count = 0;
    p = now_json_array(reply, "services");
    while (p != NULL && store->service_count < kCloudMaxServices) {
        CloudService *service = &store->services[store->service_count];

        p = now_json_next_object(p, object, sizeof object);
        if (p == NULL) {
            break;
        }
        memset(service, 0, sizeof *service);
        now_json_find_string(object, "service", service->service,
                             sizeof service->service);
        if (service->service[0] == '\0') {
            continue;                 /* unaddressable, so unusable */
        }
        now_json_find_text(object, "label", service->label,
                           sizeof service->label);
        if (service->label[0] == '\0') {
            strcpy(service->label, service->service);
        }
        now_json_find_string(object, "state", service->state,
                             sizeof service->state);
        now_json_find_text(object, "detail", service->detail,
                           sizeof service->detail);
        ++store->service_count;
    }
    return store->service_count;
}

int cloud_parse_listing(const char *reply, CloudStore *store)
{
    char object[512];
    char service[24];
    const char *p;
    int appended = 0;

    /* Rows accumulate across pages, so a listing for a service other
       than the one the store is collecting is a stale answer — the
       person has already switched the dropdown. Drop it. */
    service[0] = '\0';
    now_json_find_string(reply, "service", service, sizeof service);
    if (strcmp(service, store->listed_service) != 0) {
        return 0;
    }
    p = now_json_array(reply, "entries");
    while (p != NULL && store->row_count < kCloudMaxRows) {
        CloudRow *row = &store->rows[store->row_count];

        p = now_json_next_object(p, object, sizeof object);
        if (p == NULL) {
            break;
        }
        memset(row, 0, sizeof *row);
        now_json_find_string(object, "item", row->item, sizeof row->item);
        now_json_find_text(object, "title", row->title,
                           sizeof row->title);
        if (row->item[0] == '\0' || row->title[0] == '\0') {
            continue;                 /* not addressable or not drawable */
        }
        now_json_find_text(object, "subtitle", row->subtitle,
                           sizeof row->subtitle);
        row->bytes = now_json_find_int(object, "bytes", 0);
        row->modified =
            (unsigned long)now_json_find_int(object, "modified", 0);
        row->width = now_json_find_int(object, "width", 0);
        row->height = now_json_find_int(object, "height", 0);
        ++store->row_count;
        ++appended;
    }
    store->more = now_json_find_bool(reply, "more", 0) ? 1 : 0;
    store->cursor = now_json_find_int(reply, "cursor",
                                      store->row_count + 1);
    return appended;
}

int cloud_parse_card_rows(const char *reply, char *item_out, long item_cap,
                          CloudCardRow *rows_out, int rows_cap)
{
    char pair[224];
    const char *p;
    int count = 0;

    if (item_out != NULL && item_cap > 0) {
        item_out[0] = '\0';
        now_json_find_string(reply, "item", item_out, item_cap);
    }
    p = now_json_array(reply, "rows");
    while (p != NULL && count < rows_cap) {
        CloudCardRow *row = &rows_out[count];

        p = now_json_next_array(p, pair, sizeof pair);
        if (p == NULL) {
            break;
        }
        memset(row, 0, sizeof *row);
        if (!now_json_array_string(pair, 0, row->label,
                                   sizeof row->label)) {
            continue;
        }
        now_json_array_string(pair, 1, row->value, sizeof row->value);
        ++count;
    }
    return count;
}

int cloud_parse_card(const char *reply, CloudStore *store)
{
    store->card_count = cloud_parse_card_rows(reply, store->card_item,
                                              sizeof store->card_item,
                                              store->card,
                                              kCloudMaxCardRows);
    return store->card_count;
}

Boolean cloud_service_listable(const char *service)
{
    /* Drive's browsing lives in the Files page: the registry
       (contract x-cloud) says so, and asking anyway would earn a
       not-listable refusal. Everything else is assumed listable until
       the host refuses — additive registry, so an unknown future
       service is a question, not a table entry here. */
    return strcmp(service, "drive") != 0 ? 1 : 0;
}

void cloud_listing_status(const CloudStore *store, char *out, long cap)
{
    if (store->more && store->row_count >= kCloudMaxRows) {
        /* The cap was hit while the host still had rows to send. 128
           rows is the Files browser's own bound (memory, not honesty:
           128 CloudRow entries cost under 24KB on a 6MB partition), so
           it does not rise for a large library - the wording carries
           the honesty instead. "newest first" is stated only where the
           order is actually known to this store: the registry sorts
           photos that way (docs/icloud.md), but a future listable
           service is not assumed to share it. */
        if (strcmp(store->listed_service, "photos") == 0) {
            snprintf(out, (size_t)cap, "%d of many, newest first",
                     store->row_count);
        } else {
            snprintf(out, (size_t)cap, "%d of many (more not shown)",
                     store->row_count);
        }
    } else if (store->row_count == 0) {
        strncpy(out, "Empty", (size_t)cap);
        out[cap - 1] = '\0';
    } else {
        snprintf(out, (size_t)cap, "%d row%s", store->row_count,
                 store->row_count == 1 ? "" : "s");
    }
}

int cloud_first_listable(const CloudStore *store)
{
    int i;

    for (i = 0; i < store->service_count; ++i) {
        if (strcmp(store->services[i].state, "serving") == 0
            && cloud_service_listable(store->services[i].service)) {
            return i;
        }
    }
    return -1;
}

/* --- the download-size popup and the download read-out ------------------ */

const char *cloud_size_token(int menu_item)
{
    /* MENU 136's order is load-bearing the way MENU 134's is for
       software_module: items 1-3 are the contract's three tokens,
       item 4 is Host default — NULL, which omits the field, which IS
       the host-default ask by contract. Out of range reads as Host
       default too: the popup cannot produce it, and a guess would be
       a size nobody chose. */
    switch (menu_item) {
    case 1:  return "original";
    case 2:  return "fit1024";
    case 3:  return "fit640";
    default: return 0;
    }
}

int cloud_dl_bar_value(long received, long expected)
{
    if (expected <= 0) {
        return -1;                    /* nothing honest to show */
    }
    if (received <= 0) {
        return 0;
    }
    if (received >= expected) {
        return 1000;
    }
    /* long is 32 bits on the guest toolchain, so received * 1000 is
       exact only below ~2MB; past that the division moves to the
       other operand, which costs at most one part in two thousand of
       accuracy on a multi-megabyte photo — invisible at 12 pixels a
       percent-tenth wide. */
    if (received <= 0x1FFFFFL) {
        return (int)((received * 1000L) / expected);
    }
    {
        int v = (int)(received / (expected / 1000L));

        return v > 1000 ? 1000 : v;
    }
}

void cloud_dl_bytes_line(long received, long expected,
                         char *out, long cap)
{
    long rk = received >= 0 ? (received + 1023) / 1024 : 0;
    long ek = expected > 0 ? (expected + 1023) / 1024 : 0;

    if (expected > 0) {
        snprintf(out, (size_t)cap, "%ldK of %ldK", rk, ek);
    } else {
        snprintf(out, (size_t)cap, "%ldK", rk);
    }
}
