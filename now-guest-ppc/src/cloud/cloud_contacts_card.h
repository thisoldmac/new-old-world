#ifndef NOW_CLOUD_CONTACTS_CARD_H
#define NOW_CLOUD_CONTACTS_CARD_H

#include "cloud_model.h"

/* Pure, Toolbox-free decisions for the Contacts card. Kept out of
   cloud_contacts_view.c the way cloud_layout.c is kept out of the
   module: the host cc can run these against fixtures no PowerPC ever
   has to build.

   The contract (x-cloud, contacts) says a card's [label, value] rows
   carry phones, emails and addresses "in the person's own labels
   ('home', 'work')" -- the SAME label text on a phone row and an
   email row alike (cloud_model_test.c's fixture uses "work" for an
   email). So which group a row belongs to can only come from the
   VALUE, never the label, and that is what classify_row and
   order_card decide. */

typedef enum {
    kCloudContactsRowOther = 0,
    kCloudContactsRowPhone,
    kCloudContactsRowEmail
} CloudContactsRowKind;

CloudContactsRowKind cloud_contacts_classify_row(const CloudCardRow *row);

/* Fills order[0..returned) with indices into card, grouped: every
   kCloudContactsRowOther row first (arrival order preserved), then
   every phone row, then every email row. order must hold at least
   kCloudMaxCardRows entries. */
int cloud_contacts_order_card(const CloudCardRow *card, int card_count,
                              int order[kCloudMaxCardRows]);

/* True (with year/month/day filled) when value is an English long
   date -- "<Month> <Day>, <Year>", the shape a Foundation
   DateFormatter(.long) emits and the one the Birthday row arrives in
   today. False otherwise, outs left untouched: the card still shows
   the host's own text for anything this does not recognise, rather
   than guessing. */
Boolean cloud_contacts_parse_long_date(const char *value, int *year,
                                       int *month, int *day);

#endif /* NOW_CLOUD_CONTACTS_CARD_H */
