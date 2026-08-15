#ifndef NOW_CONTINUITY_OFFER_H
#define NOW_CONTINUITY_OFFER_H

/* What the host is holding out to this Macintosh, and the one question
   worth asking about it locally: is there something here worth a
   continuity.grab.
   ------------------------------------------------------------------
   This is continuity.selection's table, inverted and deliberately
   thinner (see now_continuity_selection.h, the sibling this file does
   not duplicate). Three differences follow from who is authoritative:

     - The HOST publishes both numbers here. The selection stub's
       generation is the GUEST's own count of what it saw; this table's
       epoch and generation are whatever the host last said, applied
       as-is - there is no local "did this change" decision to make,
       because the host already made it before sending.

     - AN ABSENT ITEM IS NOT A REFUSAL TO ANSWER. It is the host's own
       teardown instruction ("drop whatever drag you were drawing"),
       carried on a fresh generation exactly like a present item would
       be - see now_continuity_offer_apply.

     - THIS FILE RUNS NO TIMER. The offer's lifetime bound (30 s, or
       until a new-epoch offer, whichever first) is the HOST's clock,
       stated once on ContinuityOffer, and the contract is explicit
       that it is "the same NUMBER as the guest's grant window and NOT
       the same constant" - deriving one from the other is exactly the
       coupling that sentence exists to prevent. So this table's report
       reads as "closed" only from what it already knows locally (the
       offer's own epoch is behind the live one), never from a clock it
       kept itself.

   Toolbox-free, like its sibling: the wire JSON and the FSSpec-shaped
   staging destination live in now-guest-ppc, where a test cannot
   follow them. */

#define kNowContinuityOfferNameMax 32

enum {
    kNowContinuityOfferNameCrossed = 0,   /* absent on the wire: unchanged */
    kNowContinuityOfferNameTruncated = 1,
    kNowContinuityOfferNameTransliterated = 2,
    kNowContinuityOfferNameBoth = 3
};

typedef struct {
    char name[kNowContinuityOfferNameMax];
    int name_adjusted;            /* one of the kNowContinuityOfferName* */
    int have_file_type;
    unsigned long file_type;      /* OSType, held as raw bytes */
    int have_creator;
    unsigned long creator;        /* OSType, held as raw bytes */
    long data_size;
    int have_resource_size;
    long resource_size;
    int have_modified;
    unsigned long modified;       /* classic seconds since 1904 */
    int is_folder;
} NowContinuityOfferItem;

typedef struct {
    unsigned long epoch;
    unsigned long generation;
    int have_item;
    NowContinuityOfferItem item;
} NowContinuityOfferTable;

/* Drop everything: disconnect, or an epoch ending with nothing published
   under the next one. An offer cannot outlive the session that carried
   it, the same rule the selection stub follows for the other
   direction. */
void now_continuity_offer_reset(NowContinuityOfferTable *table);

/* Fold in one continuity.offer. `item` NULL is the host's own teardown
   instruction and is applied exactly like a present one — the table
   always ends at (epoch, generation) afterward, because the host is the
   sole authority over both numbers on this side of the bargain (unlike
   the selection stub, which the GUEST publishes and therefore counts
   for itself). */
void now_continuity_offer_apply(NowContinuityOfferTable *table,
                                unsigned long epoch, unsigned long generation,
                                const NowContinuityOfferItem *item);

enum {
    /* Continuity is not armed at all. */
    kNowOfferReportNoEpoch = 0,
    /* A live epoch, and nothing published under it — never offered, or
       withdrawn by an absent-item generation. */
    kNowOfferReportNoOffer = 1,
    /* The table holds an item, but under an epoch that is no longer the
       live one: what a closing offer looks like from here, whether or
       not the host's own 30-second window has actually run out. */
    kNowOfferReportClosed = 2,
    /* An item, published under the live epoch. */
    kNowOfferReportPresent = 3
};

int now_continuity_offer_report_kind(const NowContinuityOfferTable *table,
                                     unsigned long live_epoch);

/* May a continuity.grab be sent right now? The same test as
   report_kind == Present, spelled as a question with an answer rather
   than a fourth place that repeats it. epoch_out/generation_out are
   filled only when this returns 1. */
int now_continuity_offer_grab_ready(const NowContinuityOfferTable *table,
                                    unsigned long live_epoch,
                                    unsigned long *epoch_out,
                                    unsigned long *generation_out);

#endif /* NOW_CONTINUITY_OFFER_H */
