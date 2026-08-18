#include "continuity_offer_intake.h"

#include <string.h>

#include "json.h"
#include "nowlog.h"

static NowContinuityOfferTable g_offer;

const NowContinuityOfferTable *now_continuity_offer_table(void)
{
    return &g_offer;
}

void now_continuity_offer_forget(void)
{
    now_continuity_offer_reset(&g_offer);
}

static int name_adjusted_code(const char *request)
{
    char word[24];

    if (!now_json_find_string(request, "nameAdjusted", word, sizeof word)) {
        return kNowContinuityOfferNameCrossed;
    }
    if (strcmp(word, "truncated") == 0) {
        return kNowContinuityOfferNameTruncated;
    }
    if (strcmp(word, "transliterated") == 0) {
        return kNowContinuityOfferNameTransliterated;
    }
    if (strcmp(word, "both") == 0) {
        return kNowContinuityOfferNameBoth;
    }
    return kNowContinuityOfferNameCrossed;
}

/* None of the keys this reads collide with ContinuityOffer's top-level
   ones (type, version, epoch, generation) or with each other, so the
   flat scanner needs no bounding to the "item" object — unlike
   file.offer's Mirror-key collision (see wire.c's now_json_next_object
   comment), nothing else in this message is named "name" or
   "dataSize". */
void now_continuity_offer_intake(const char *request)
{
    unsigned long epoch = (unsigned long)now_json_find_int(request, "epoch", 0);
    unsigned long generation =
        (unsigned long)now_json_find_int(request, "generation", 0);
    const char *item_at = now_json_value(request, "item");
    NowContinuityOfferItem item;
    char code[8];
    long rsrc;

    if (item_at == NULL || *item_at != '{') {
        /* Absent item + fresh generation: the host's own instruction to
           tear down whatever drag this Mac was drawing, applied exactly
           like a present item — see now_continuity_offer_apply. */
        now_continuity_offer_apply(&g_offer, epoch, generation,
                                   (const NowContinuityOfferItem *)0);
        now_log(kLogInfo, "mirror", "offer withdrawn epoch=%lu gen=%lu",
                epoch, generation);
        return;
    }

    memset(&item, 0, sizeof item);
    now_json_find_text(request, "name", item.name, sizeof item.name);
    item.name_adjusted = name_adjusted_code(request);
    if (now_json_find_string(request, "fileType", code, sizeof code)
        && strlen(code) == 4) {
        memcpy(&item.file_type, code, 4);
        item.have_file_type = 1;
    }
    if (now_json_find_string(request, "creator", code, sizeof code)
        && strlen(code) == 4) {
        memcpy(&item.creator, code, 4);
        item.have_creator = 1;
    }
    item.data_size = now_json_find_int(request, "dataSize", 0);
    if (now_json_read_int(request, "resourceSize", &rsrc) == kNowJsonIntOk) {
        item.have_resource_size = 1;
        item.resource_size = rsrc;
    }
    item.modified = now_json_find_u32(request, "modifiedAt", 0);
    item.have_modified = now_json_value(request, "modifiedAt") != NULL;
    item.is_folder = now_json_find_bool(request, "isFolder", 0);

    now_continuity_offer_apply(&g_offer, epoch, generation, &item);
    now_log(kLogInfo, "mirror", "offer epoch=%lu gen=%lu %.31s %ld bytes%s",
            epoch, generation, item.name, item.data_size,
            item.is_folder ? " (folder)" : "");
}
