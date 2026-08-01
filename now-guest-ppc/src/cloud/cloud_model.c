#include "cloud_model.h"

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
        ++store->row_count;
        ++appended;
    }
    store->more = now_json_find_bool(reply, "more", 0) ? 1 : 0;
    store->cursor = now_json_find_int(reply, "cursor",
                                      store->row_count + 1);
    return appended;
}

int cloud_parse_card(const char *reply, CloudStore *store)
{
    char pair[224];
    const char *p;

    store->card_count = 0;
    store->card_item[0] = '\0';
    now_json_find_string(reply, "item", store->card_item,
                         sizeof store->card_item);
    p = now_json_array(reply, "rows");
    while (p != NULL && store->card_count < kCloudMaxCardRows) {
        CloudCardRow *row = &store->card[store->card_count];

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
        ++store->card_count;
    }
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
