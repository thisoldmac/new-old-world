#include "now_continuity_offer.h"

#include <string.h>

void now_continuity_offer_reset(NowContinuityOfferTable *table)
{
    if (table == NULL) {
        return;
    }
    memset(table, 0, sizeof *table);
}

void now_continuity_offer_apply(NowContinuityOfferTable *table,
                                unsigned long epoch, unsigned long generation,
                                const NowContinuityOfferItem *item)
{
    if (table == NULL) {
        return;
    }
    table->epoch = epoch;
    table->generation = generation;
    if (item == NULL) {
        table->have_item = 0;
        memset(&table->item, 0, sizeof table->item);
        return;
    }
    table->have_item = 1;
    table->item = *item;
}

int now_continuity_offer_report_kind(const NowContinuityOfferTable *table,
                                     unsigned long live_epoch)
{
    if (live_epoch == 0) {
        return kNowOfferReportNoEpoch;
    }
    if (table == NULL || !table->have_item || table->epoch == 0) {
        return kNowOfferReportNoOffer;
    }
    if (table->epoch != live_epoch) {
        /* Held an item once, under an epoch that has since moved on. */
        return kNowOfferReportClosed;
    }
    return kNowOfferReportPresent;
}

int now_continuity_offer_grab_ready(const NowContinuityOfferTable *table,
                                    unsigned long live_epoch,
                                    unsigned long *epoch_out,
                                    unsigned long *generation_out)
{
    if (now_continuity_offer_report_kind(table, live_epoch)
        != kNowOfferReportPresent) {
        return 0;
    }
    if (epoch_out != NULL) {
        *epoch_out = table->epoch;
    }
    if (generation_out != NULL) {
        *generation_out = table->generation;
    }
    return 1;
}
