#ifndef NOW_CLOUD_CONTACTS_CARD_H
#define NOW_CLOUD_CONTACTS_CARD_H

#include "cloud_layout.h"
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

/* --- the card's furniture, top-left photo well beside the name -------

   The classic Address Book shape: a square photo well top-left, the
   person's name beside it in the large system font, then the grouped
   rows below both. Pure geometry so the host cc can prove it holds
   together at the smallest honest pane (cloud_layout_test.c's 640x480
   body puts the contacts card's detail_text at roughly 184x286 points
   -- see cloud_layout.c) without a screen. */

enum {
    /* 48, not 64: at the smallest honest pane (~184pt wide, above) a
       64-point well leaves under 112pt for a name in the large system
       font before truncation bites on anything but a short one; 48
       leaves 128 and still reads as a real photo, not a postage stamp. */
    kCloudContactsWellSize = 48,
    kCloudContactsWellGap = 8,          /* well's right edge to the name */
    kCloudContactsRowsGap = 12          /* well's bottom edge to the
                                            first label/value row --
                                            taller than the name row, so
                                            it is always the rows_top
                                            that has to clear it */
};

typedef struct {
    Rect well;          /* the square photo well, top-left of the pane */
    short name_left;     /* where the name's text starts */
    short name_baseline; /* the name's baseline, centred against well */
    short rows_top;      /* where the label/value rows begin drawing */
} CloudContactsCardLayout;

/* Degrades gracefully rather than asserting: a pane too small for the
   configured well shrinks the well to fit rather than overflow it (a
   grown window is the only way this project has ever proven a pane
   this narrow, but a test should not have to trust that). NULL pane or
   out is a no-op / zeroed answer respectively. */
void cloud_contacts_card_layout(const Rect *pane,
                                CloudContactsCardLayout *out);

#endif /* NOW_CLOUD_CONTACTS_CARD_H */
