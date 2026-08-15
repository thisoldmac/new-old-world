/* The offer table's two decisions, watched without a Macintosh: what a
   report says with nothing better to go on, and when a grab may be
   sent. Both are pure arithmetic over what the host last published, on
   purpose - this file runs no clock of its own (see the header). */
#include <stdio.h>
#include <string.h>

#include "now_continuity_offer.h"

#define CHECK(value) do { if (!(value)) {                                \
    fprintf(stderr, "offer table failed at line %d\n", __LINE__);        \
    return 1;                                                            \
} } while (0)

static NowContinuityOfferItem item_named(const char *name, long data_size,
                                         int folder)
{
    NowContinuityOfferItem it;

    memset(&it, 0, sizeof it);
    strcpy(it.name, name);
    it.data_size = data_size;
    it.is_folder = folder;
    if (!folder) {
        it.have_file_type = 1;
        memcpy(&it.file_type, "TEXT", 4);
        it.have_creator = 1;
        memcpy(&it.creator, "ttxt", 4);
    }
    return it;
}

int main(void)
{
    NowContinuityOfferTable table;
    NowContinuityOfferItem a = item_named("Report", 4096, 0);
    unsigned long epoch = 0, generation = 0;

    /* --- nothing has arrived yet --------------------------------------- */
    now_continuity_offer_reset(&table);
    CHECK(now_continuity_offer_report_kind(&table, 0) == kNowOfferReportNoEpoch);
    /* No live epoch refuses a grab even over a table that happens to hold
       something stale from a previous session. */
    table.epoch = 7;
    table.generation = 1;
    table.have_item = 1;
    table.item = a;
    CHECK(now_continuity_offer_report_kind(&table, 0) == kNowOfferReportNoEpoch);
    CHECK(!now_continuity_offer_grab_ready(&table, 0, &epoch, &generation));

    /* --- a live epoch, nothing published under it ----------------------- */
    now_continuity_offer_reset(&table);
    CHECK(now_continuity_offer_report_kind(&table, 7) == kNowOfferReportNoOffer);
    CHECK(!now_continuity_offer_grab_ready(&table, 7, &epoch, &generation));

    /* --- the host publishes ---------------------------------------------- */
    now_continuity_offer_apply(&table, 7, 1, &a);
    CHECK(table.epoch == 7 && table.generation == 1 && table.have_item);
    CHECK(strcmp(table.item.name, "Report") == 0);
    CHECK(now_continuity_offer_report_kind(&table, 7) == kNowOfferReportPresent);
    epoch = 0;
    generation = 0;
    CHECK(now_continuity_offer_grab_ready(&table, 7, &epoch, &generation));
    CHECK(epoch == 7 && generation == 1);

    /* A second publish under the same epoch replaces the item and moves
       the generation - the host counts, this table just applies. */
    {
        NowContinuityOfferItem b = item_named("Other", 10, 0);

        now_continuity_offer_apply(&table, 7, 2, &b);
        CHECK(table.generation == 2);
        CHECK(strcmp(table.item.name, "Other") == 0);
    }

    /* --- the host tears it down: absent item, fresh generation ---------- */
    now_continuity_offer_apply(&table, 7, 3, (const NowContinuityOfferItem *)0);
    CHECK(!table.have_item);
    CHECK(table.generation == 3);
    CHECK(now_continuity_offer_report_kind(&table, 7) == kNowOfferReportNoOffer);
    CHECK(!now_continuity_offer_grab_ready(&table, 7, &epoch, &generation));

    /* --- the epoch moves on out from under a held offer ------------------ */
    now_continuity_offer_apply(&table, 7, 4, &a);
    CHECK(now_continuity_offer_report_kind(&table, 7) == kNowOfferReportPresent);
    /* The live epoch advanced (a new arm/disarm cycle) without a fresh
       continuity.offer arriving yet - the table's own epoch is now
       behind, and that is exactly what "closed" means here. */
    CHECK(now_continuity_offer_report_kind(&table, 8) == kNowOfferReportClosed);
    CHECK(!now_continuity_offer_grab_ready(&table, 8, &epoch, &generation));

    /* A fresh offer under the new epoch clears the closed reading. */
    now_continuity_offer_apply(&table, 8, 1, &a);
    CHECK(now_continuity_offer_report_kind(&table, 8) == kNowOfferReportPresent);

    /* --- NULL is inert, not a crash --------------------------------------- */
    now_continuity_offer_reset((NowContinuityOfferTable *)0);
    now_continuity_offer_apply((NowContinuityOfferTable *)0, 1, 1, &a);
    CHECK(now_continuity_offer_report_kind((const NowContinuityOfferTable *)0, 7)
          == kNowOfferReportNoOffer);
    CHECK(!now_continuity_offer_grab_ready((const NowContinuityOfferTable *)0, 7,
                                           &epoch, &generation));

    printf("ok\n");
    return 0;
}
