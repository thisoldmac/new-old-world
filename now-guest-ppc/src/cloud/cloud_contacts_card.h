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
    kCloudContactsRowEmail,
    kCloudContactsRowAddress
} CloudContactsRowKind;

CloudContactsRowKind cloud_contacts_classify_row(const CloudCardRow *row);

/* Fills order[0..returned) with indices into card, grouped in the
   order the card's section boxes appear -- every phone row first,
   then every email, then every address, then everything else
   (arrival order preserved inside each group). order must hold at
   least kCloudMaxCardRows entries.

   Phone/Email/Address before Other because a person looking up a
   contact wants the ways to REACH them, and the leftovers the host
   emits (Name, Company, Birthday -- see CloudServices.swift's card())
   are either already drawn beside the well or genuinely incidental. */
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

/* --- the card's furniture: well, name, and a group box per section ---

   The classic Address Book shape: a square photo well top-left, the
   person's name beside it in the large system font with the
   organization under it in the small one, then -- below both -- one
   TITLED GROUP BOX per section, in the order Phone, Email, Address,
   Other, each holding its own label/value rows. (Judged from rendered
   mocks, 2026-08-02: a flat label/value column read as a form, not as
   an address card.)

   Pure geometry, so the host cc can prove the stack holds together --
   in order, never overlapping, never past the pane -- without a
   screen. The BOXES are real Appearance group-box controls
   (kControlGroupBoxTextTitleProc) placed at these rects by
   cloud_contacts_view.c; the ROWS inside them are hand-drawn text,
   because they are content, not controls. */

enum {
    /* 48, not 64: at the smallest honest pane (~184pt wide) a
       64-point well leaves under 112pt for a name in the large system
       font before truncation bites on anything but a short one; 48
       leaves 128 and still reads as a real photo, not a postage stamp. */
    kCloudContactsWellSize = 48,
    kCloudContactsWellGap = 8,          /* well's right edge to the name */
    kCloudContactsRowsGap = 12,         /* well's bottom edge to the
                                            first group box -- taller
                                            than the name block, so it
                                            is always the box top that
                                            has to clear the well */

    kCloudContactsMaxSections = 4,      /* Phone, Email, Address, Other:
                                            the whole kind set, so the
                                            view's control POOL is this
                                            size and never grows */
    kCloudContactsBoxInset = 8,         /* box's left edge to the label */
    kCloudContactsValueDx = 70,         /* label column to value column */
    kCloudContactsRowHeight = 14,
    kCloudContactsBoxFirstRow = 26,     /* box top to the FIRST row's
                                            baseline: clears the group
                                            box's own titled top edge */
    kCloudContactsBoxTail = 9,          /* last baseline to box bottom:
                                            a small-font descender plus
                                            the frame's own breathing */
    kCloudContactsBoxGap = 6            /* between one box and the next */
};

typedef struct {
    const char *title;   /* "Phone" / "Email" / "Address" / "Other",
                             static storage, MacRoman-safe ASCII */
    Rect box;            /* the group box control's frame */
    int first;           /* index into CloudContactsCardLayout.order of
                             this section's first row */
    int count;           /* rows DRAWN in this box -- may be fewer than
                             the section has, when the pane ran out (see
                             below); never 0, a section with nothing to
                             show is simply absent */
} CloudContactsSection;

typedef struct {
    Rect well;           /* the square photo well, top-left of the pane */
    short name_left;     /* where the name and organization text starts */
    short name_baseline; /* the name's baseline */
    short org_baseline;  /* the organization's, one small row under it */
    short rows_top;      /* the first group box's top edge */

    int order[kCloudMaxCardRows];  /* card row indices, section order */
    int order_count;

    int section_count;             /* 0 when there is no card yet */
    CloudContactsSection sections[kCloudContactsMaxSections];
} CloudContactsCardLayout;

/* Degrades gracefully rather than asserting, in three ways a test can
   watch:

   - a pane too small for the configured well shrinks the well to fit
     rather than overflow it;
   - a card with NO rows (the prefetch has not answered yet) answers
     section_count 0 -- the well and the name draw alone, rather than
     four empty boxes standing where a card is about to arrive;
   - a stack too tall for the pane is TRUNCATED, never spilled: the
     last box that fits keeps only the rows that fit inside it, and
     any section after it is dropped. There is no scroller on this
     pane, so overflowing it would draw over the page's furniture.

   `card` may be NULL (with card_count 0) when the caller only wants
   the well and the name -- cloud_contacts_view.c's layout/select
   seams do exactly that. NULL pane or out is a no-op / zeroed answer
   respectively. */
void cloud_contacts_card_layout(const Rect *pane,
                                const CloudCardRow *card, int card_count,
                                CloudContactsCardLayout *out);

/* Where row `i` of a section draws. Kept here rather than re-derived
   in the view so the arithmetic that the test proves is the same
   arithmetic that reaches the screen. Out-of-range i is clamped. */
short cloud_contacts_section_baseline(const CloudContactsSection *s, int i);
short cloud_contacts_section_label_x(const CloudContactsSection *s);
short cloud_contacts_section_value_x(const CloudContactsSection *s);

#endif /* NOW_CLOUD_CONTACTS_CARD_H */
