/* The Contacts card's pure decisions, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/core -I ../src/cloud \
        cloud_contacts_card_test.c ../src/cloud/cloud_contacts_card.c \
        -o /tmp/t && /tmp/t

   The contract (x-cloud, contacts) says rows carry phones, emails and
   addresses "in the person's own labels ('home', 'work')" -- so the
   fixtures below deliberately reuse the SAME label on a phone row and
   an email row, the way cloud_model_test.c's own card fixture does
   ("work" on an email), to prove the classifier reads the value and
   not the label. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "cloud_contacts_card.h"
#include "cloud_model.h"

static CloudCardRow mk(const char *label, const char *value)
{
    CloudCardRow row;

    memset(&row, 0, sizeof row);
    strncpy(row.label, label, sizeof row.label - 1);
    strncpy(row.value, value, sizeof row.value - 1);
    return row;
}

static void test_classification_reads_the_value_not_the_label(void)
{
    CloudCardRow home_phone = mk("home", "+1 (555) 123-4567");
    CloudCardRow work_phone = mk("work", "555-0100");
    CloudCardRow home_email = mk("home", "ada@example.com");
    CloudCardRow work_email = mk("work", "ada@work.example.com");
    CloudCardRow name = mk("Name", "Ada Lovelace");
    CloudCardRow company = mk("Company", "Acme");
    CloudCardRow address = mk("home", "1 Main St, Springfield");
    /* The host joins CNPostalAddressFormatter's lines with ", "
       (CloudServices.swift), so a real mailing address arrives with
       two or more comma-separated parts. */
    CloudCardRow mailing = mk("work", "One Infinite Loop, Cupertino, CA 95014");
    /* A company with a comma in it is still a company, and a birthday
       is two comma-separated parts with a digit in them -- neither
       may land in the Address box. */
    CloudCardRow inc = mk("Company", "Analytical Engines, Ltd.");
    CloudCardRow birthday = mk("Birthday", "November 5, 1990");

    assert(cloud_contacts_classify_row(&home_phone) == kCloudContactsRowPhone);
    assert(cloud_contacts_classify_row(&work_phone) == kCloudContactsRowPhone);
    assert(cloud_contacts_classify_row(&home_email) == kCloudContactsRowEmail);
    assert(cloud_contacts_classify_row(&work_email) == kCloudContactsRowEmail);
    assert(cloud_contacts_classify_row(&name) == kCloudContactsRowOther);
    assert(cloud_contacts_classify_row(&company) == kCloudContactsRowOther);
    /* Addresses are now a section of their own (the judged design,
       2026-08-02: Phone, Email, Address, then Other). */
    assert(cloud_contacts_classify_row(&address) == kCloudContactsRowAddress);
    assert(cloud_contacts_classify_row(&mailing) == kCloudContactsRowAddress);
    assert(cloud_contacts_classify_row(&inc) == kCloudContactsRowOther);
    assert(cloud_contacts_classify_row(&birthday) == kCloudContactsRowOther);
}

static void test_order_is_phone_email_address_then_everything_else(void)
{
    CloudCardRow card[7];
    int order[kCloudMaxCardRows];
    int n;

    card[0] = mk("Name", "Ada Lovelace");
    card[1] = mk("work", "ada@example.com");      /* email, arrives 2nd */
    card[2] = mk("Company", "Acme");
    card[3] = mk("home", "+1 555 000 1111");       /* phone, arrives 4th */
    card[4] = mk("work", "+1 555 222 3333");       /* phone, arrives 5th */
    card[5] = mk("home", "ada@home.example");      /* email, arrives 6th */
    card[6] = mk("home", "12 Rue Neuve, Paris, 75002");   /* address */

    n = cloud_contacts_order_card(card, 7, order);
    assert(n == 7);
    /* Every phone, arrival order preserved... */
    assert(order[0] == 3);
    assert(order[1] == 4);
    /* ...then every email... */
    assert(order[2] == 1);
    assert(order[3] == 5);
    /* ...then every address... */
    assert(order[4] == 6);
    /* ...then everything else, arrival order preserved. */
    assert(order[5] == 0);                         /* Name */
    assert(order[6] == 2);                         /* Company */
}

static void test_ambiguous_and_empty_values_fall_to_other(void)
{
    CloudCardRow blank = mk("home", "");
    CloudCardRow words = mk("home", "the corner office");
    CloudCardRow short_digits = mk("home", "12345");   /* a zip, not a phone */

    assert(cloud_contacts_classify_row(&blank) == kCloudContactsRowOther);
    assert(cloud_contacts_classify_row(&words) == kCloudContactsRowOther);
    assert(cloud_contacts_classify_row(&short_digits) == kCloudContactsRowOther);
}

/* Birthday's value arrives as an English long date (the host's
   DateFormatter, .long style) -- the guest needs the components back
   out to hand LongDateString the reader's own machine's date format,
   rather than echoing the host's English text verbatim. */
static void test_long_date_values_parse(void)
{
    int y = 0, m = 0, d = 0;

    assert(cloud_contacts_parse_long_date("November 5, 1990", &y, &m, &d));
    assert(y == 1990 && m == 11 && d == 5);

    y = m = d = 0;
    assert(cloud_contacts_parse_long_date("January 31, 2004", &y, &m, &d));
    assert(y == 2004 && m == 1 && d == 31);

    assert(!cloud_contacts_parse_long_date("Ada Lovelace", &y, &m, &d));
    assert(!cloud_contacts_parse_long_date("home", &y, &m, &d));
    assert(!cloud_contacts_parse_long_date("+1 555 000 1111", &y, &m, &d));
    assert(!cloud_contacts_parse_long_date(
        "November 5, 1990 (approx)", &y, &m, &d));
    assert(!cloud_contacts_parse_long_date("Movember 5, 1990", &y, &m, &d));
}

/* The card's furniture: well top-left, name beside it, rows below
   both. Checked at the pane cloud_layout_test.c's smallest honest body
   (640x480) actually produces for the contacts card -- see
   cloud_layout.c's detail_text arithmetic -- rather than a round
   number this test would otherwise have to keep in sync by hand. */
static void test_layout_at_the_smallest_honest_pane(void)
{
    Rect pane;
    CloudContactsCardLayout l;

    pane.left = 432;
    pane.top = 100;
    pane.right = 616;
    pane.bottom = 386;
    cloud_contacts_card_layout(&pane, NULL, 0, &l);

    /* The well is square, anchored top-left of the pane, at the
       configured size (the pane is wide/tall enough for it). */
    assert(l.well.left == pane.left);
    assert(l.well.top == pane.top);
    assert(l.well.right - l.well.left == kCloudContactsWellSize);
    assert(l.well.bottom - l.well.top == kCloudContactsWellSize);
    assert(l.well.right <= pane.right);
    assert(l.well.bottom <= pane.bottom);

    /* The name starts right of the well, with a real gap, and its
       baseline falls inside the well's own height (vertically
       centred against it, not off above or below). */
    assert(l.name_left == l.well.right + kCloudContactsWellGap);
    assert(l.name_left < pane.right);
    assert(l.name_baseline > l.well.top);
    assert(l.name_baseline < l.well.bottom);

    /* The organization sits one small row under the name, and the
       pair still reads as a block against the well rather than
       hanging off its bottom edge. */
    assert(l.org_baseline > l.name_baseline);
    assert(l.org_baseline - l.name_baseline == kCloudContactsRowHeight);
    assert(l.org_baseline < l.well.bottom);

    /* The rows start below the well (the taller of the two), with a
       real gap, and still inside the pane. */
    assert(l.rows_top == l.well.bottom + kCloudContactsRowsGap);
    assert(l.rows_top > l.well.bottom);
    assert(l.rows_top < pane.bottom);
}

/* A pane too small for the configured well shrinks the well to fit
   rather than let it overflow the pane -- proven by construction, not
   by trusting a screen this narrow ever gets built. */
static void test_layout_shrinks_the_well_on_a_tiny_pane(void)
{
    Rect pane;
    CloudContactsCardLayout l;

    pane.left = 10;
    pane.top = 20;
    pane.right = 40;               /* 30pt wide: under the 48pt well */
    pane.bottom = 90;
    cloud_contacts_card_layout(&pane, NULL, 0, &l);

    assert(l.well.right - l.well.left == 30);
    assert(l.well.right <= pane.right);
    assert(l.name_left == l.well.right + kCloudContactsWellGap);
    assert(l.rows_top == l.well.bottom + kCloudContactsRowsGap);
}

/* A zero-area pane (drive mode's anti-rect, or a page never laid out)
   answers a zeroed struct rather than a nonsense well past its edges
   -- the same "empty is checkable by relationship" rule cloud_layout.c
   already keeps, extended to a struct with no dedicated empty flag. */
static void test_layout_on_an_empty_pane_is_inert(void)
{
    Rect pane;
    CloudContactsCardLayout l;

    memset(&l, 0xAA, sizeof l);        /* poison, so a no-op would show */
    pane.left = 50;
    pane.top = 50;
    pane.right = 50;
    pane.bottom = 50;
    cloud_contacts_card_layout(&pane, NULL, 0, &l);

    assert(l.well.right - l.well.left == 0);
    assert(l.well.bottom - l.well.top == 0);
    assert(l.name_left == l.well.right + kCloudContactsWellGap);
    assert(l.rows_top == l.well.bottom + kCloudContactsRowsGap);
}

/* NULL in either direction must not crash -- the shell's draw path
   always has a real pane, but a pure function earns its own guard. */
static void test_layout_null_is_safe(void)
{
    Rect pane = { 0, 0, 100, 100 };
    CloudContactsCardLayout l;

    cloud_contacts_card_layout(NULL, NULL, 0, &l);
    cloud_contacts_card_layout(&pane, NULL, 0, NULL);
}

/* --- the section boxes ------------------------------------------------

   Expectations below come from the contract's x-cloud contacts
   description (phones, emails and addresses as [label, value] rows,
   plus the Name/Company/Birthday rows the host's own card() adds) and
   from the judged mock: one TITLED box per section, in the order
   Phone, Email, Address, Other, rows inside each. They are stated as
   relationships -- order, containment, non-overlap -- rather than as
   the numbers cloud_contacts_card.c happens to produce, so a change
   to the paddings does not need this file edited to stay true. */

/* The whole-contact fixture, in the order the host emits it
   (CloudServices.swift: Name, Company, phones, emails, addresses,
   Birthday). */
static int full_contact(CloudCardRow *card)
{
    card[0] = mk("Name", "Ada Lovelace");
    card[1] = mk("Company", "Analytical Engines, Ltd.");
    card[2] = mk("work", "+1 (555) 123-4567");
    card[3] = mk("mobile", "555-0100");
    card[4] = mk("work", "ada@example.com");
    card[5] = mk("home", "ada@home.example");
    card[6] = mk("home", "1 Main St, Springfield, CA 95014");
    card[7] = mk("Birthday", "November 5, 1990");
    return 8;
}

/* The pane the judged design was drawn against: 252 points wide and
   about 380 tall, roughly what the iCloud page's card pane comes to on
   a 640x480 screen. Stated here rather than imported, so this test
   fails loudly if the pane is ever shrunk under the design. */
static void judged_pane(Rect *pane)
{
    pane->left = 364;
    pane->top = 76;
    pane->right = (short)(pane->left + 252);
    pane->bottom = (short)(pane->top + 380);
}

/* Every box inside the pane, below the well, in top-to-bottom order,
   none overlapping the next -- the invariants a hand-placed stack of
   controls breaks first. */
static void assert_boxes_are_well_formed(const CloudContactsCardLayout *l,
                                         const Rect *pane)
{
    int i;

    assert(l->section_count >= 0);
    assert(l->section_count <= kCloudContactsMaxSections);
    for (i = 0; i < l->section_count; ++i) {
        const CloudContactsSection *s = &l->sections[i];

        assert(s->title != NULL && s->title[0] != '\0');
        assert(s->count > 0);          /* an empty box is never placed */
        assert(s->box.left >= pane->left);
        assert(s->box.right <= pane->right);
        assert(s->box.right > s->box.left);
        assert(s->box.top >= l->rows_top);
        assert(s->box.bottom <= pane->bottom);
        assert(s->box.bottom > s->box.top);

        /* Rows live INSIDE their own box, both ends. */
        assert(cloud_contacts_section_baseline(s, 0) > s->box.top);
        assert(cloud_contacts_section_baseline(s, s->count - 1)
               < s->box.bottom);
        /* The label at the box's left inset, the value a second
           column 70 points right of it -- the judged design. */
        assert(cloud_contacts_section_label_x(s) > s->box.left);
        assert(cloud_contacts_section_value_x(s)
               - cloud_contacts_section_label_x(s)
               == kCloudContactsValueDx);
        assert(cloud_contacts_section_value_x(s) < s->box.right);

        if (i > 0) {
            /* Strictly below the one before it: no overlap, and a
               real gap so two frames never share a pixel row. */
            assert(s->box.top > l->sections[i - 1].box.bottom);
        }
    }
}

/* Each section holds exactly the rows of its own kind, and its
   [first, first+count) window into order[] names them. */
static void assert_section_holds(const CloudContactsCardLayout *l,
                                 const CloudCardRow *card, int which,
                                 const char *title,
                                 CloudContactsRowKind kind, int count)
{
    const CloudContactsSection *s = &l->sections[which];
    int i;

    assert(which < l->section_count);
    assert(strcmp(s->title, title) == 0);
    assert(s->count == count);
    assert(s->first >= 0);
    assert(s->first + s->count <= l->order_count);
    for (i = 0; i < s->count; ++i) {
        assert(cloud_contacts_classify_row(&card[l->order[s->first + i]])
               == kind);
    }
}

static void test_sections_are_phone_email_address_other_and_fit(void)
{
    CloudCardRow card[8];
    CloudContactsCardLayout l;
    Rect pane;
    int n = full_contact(card);

    judged_pane(&pane);
    cloud_contacts_card_layout(&pane, card, n, &l);

    /* All four kinds are present in this contact, so all four boxes
       are, in the judged order. */
    assert(l.section_count == 4);
    assert_section_holds(&l, card, 0, "Phone", kCloudContactsRowPhone, 2);
    assert_section_holds(&l, card, 1, "Email", kCloudContactsRowEmail, 2);
    assert_section_holds(&l, card, 2, "Address",
                         kCloudContactsRowAddress, 1);
    /* Name, Company and Birthday: the labelled leftovers. */
    assert_section_holds(&l, card, 3, "Other", kCloudContactsRowOther, 3);

    /* Every row the card carries is placed exactly once. */
    assert(l.order_count == n);
    assert(l.sections[0].count + l.sections[1].count
           + l.sections[2].count + l.sections[3].count == n);

    assert_boxes_are_well_formed(&l, &pane);
    /* The whole stack fits the judged pane with the well above it --
       no truncation was needed to make the assertions above true. */
    assert(l.sections[3].box.bottom <= pane.bottom);
}

static void test_a_section_with_no_rows_is_absent(void)
{
    CloudCardRow card[3];
    CloudContactsCardLayout l;
    Rect pane;

    /* A contact with a phone and a name, nothing else: an Email box
       and an Address box would both be furniture standing over
       nothing. */
    card[0] = mk("Name", "Grace Hopper");
    card[1] = mk("work", "+1 555 010 2030");
    card[2] = mk("Birthday", "December 9, 1906");

    judged_pane(&pane);
    cloud_contacts_card_layout(&pane, card, 3, &l);

    assert(l.section_count == 2);
    assert_section_holds(&l, card, 0, "Phone", kCloudContactsRowPhone, 1);
    assert_section_holds(&l, card, 1, "Other", kCloudContactsRowOther, 2);
    assert_boxes_are_well_formed(&l, &pane);
}

static void test_one_section_leaves_no_box_shaped_hole(void)
{
    CloudCardRow card[2];
    CloudContactsCardLayout l;
    Rect pane;

    card[0] = mk("work", "+1 555 010 2030");
    card[1] = mk("mobile", "+1 555 010 2031");

    judged_pane(&pane);
    cloud_contacts_card_layout(&pane, card, 2, &l);

    assert(l.section_count == 1);
    assert_section_holds(&l, card, 0, "Phone", kCloudContactsRowPhone, 2);
    /* The one box starts where the rows start -- not one, two or
       three box-heights down where the absent Email/Address/Other
       boxes would otherwise have stood. */
    assert(l.sections[0].box.top == l.rows_top);
    assert_boxes_are_well_formed(&l, &pane);
}

/* A selected contact whose card has not arrived yet (the prefetch is
   still walking, or the ask is in flight): the well and the name draw
   alone. Four empty titled boxes would be a promise the card has not
   made. */
static void test_no_card_rows_yet_draws_no_boxes(void)
{
    CloudContactsCardLayout l;
    CloudCardRow none[1];
    Rect pane;

    judged_pane(&pane);
    cloud_contacts_card_layout(&pane, NULL, 0, &l);
    assert(l.section_count == 0);
    assert(l.order_count == 0);
    assert(l.well.right - l.well.left == kCloudContactsWellSize);
    assert(l.rows_top == l.well.bottom + kCloudContactsRowsGap);

    /* Same answer for a real (but empty) card array. */
    memset(none, 0, sizeof none);
    cloud_contacts_card_layout(&pane, none, 0, &l);
    assert(l.section_count == 0);
}

/* The pane has no scroller, so a card too tall for it is truncated,
   never spilled over the page's own furniture. Sixteen rows -- the
   model's kCloudMaxCardRows ceiling -- into a short pane is the worst
   case the wire can deliver. */
static void test_a_stack_too_tall_is_truncated_not_spilled(void)
{
    CloudCardRow card[kCloudMaxCardRows];
    CloudContactsCardLayout l;
    Rect pane;
    int i, drawn = 0;
    char value[64];

    for (i = 0; i < kCloudMaxCardRows; ++i) {
        snprintf(value, sizeof value, "+1 555 %03d 0000", i);
        card[i] = mk("work", value);
    }
    pane.left = 0;
    pane.top = 0;
    pane.right = 252;
    pane.bottom = 160;                 /* well 48 + gap 12 leaves 100 */
    cloud_contacts_card_layout(&pane, card, kCloudMaxCardRows, &l);

    assert(l.order_count == kCloudMaxCardRows);
    assert(l.section_count == 1);
    for (i = 0; i < l.section_count; ++i) {
        drawn += l.sections[i].count;
    }
    assert(drawn > 0);
    assert(drawn < kCloudMaxCardRows); /* something HAD to be dropped */
    assert_boxes_are_well_formed(&l, &pane);
}

/* Sixteen rows spread across all four sections is the other worst
   case: four titled boxes cost four sets of frame padding, which the
   single-box case never pays. It must still stay inside the judged
   pane. */
static void test_the_worst_case_card_still_fits_the_judged_pane(void)
{
    CloudCardRow card[kCloudMaxCardRows];
    CloudContactsCardLayout l;
    Rect pane;
    int i, drawn = 0;
    char value[64];

    for (i = 0; i < 4; ++i) {
        snprintf(value, sizeof value, "+1 555 %03d 0000", i);
        card[i] = mk("work", value);
    }
    for (i = 4; i < 8; ++i) {
        snprintf(value, sizeof value, "ada%d@example.com", i);
        card[i] = mk("home", value);
    }
    for (i = 8; i < 12; ++i) {
        snprintf(value, sizeof value, "%d Main St, Springfield, CA 95014", i);
        card[i] = mk("work", value);
    }
    for (i = 12; i < kCloudMaxCardRows; ++i) {
        snprintf(value, sizeof value, "note %d", i);
        card[i] = mk("Note", value);
    }
    judged_pane(&pane);
    cloud_contacts_card_layout(&pane, card, kCloudMaxCardRows, &l);

    assert(l.section_count == 4);
    for (i = 0; i < l.section_count; ++i) {
        drawn += l.sections[i].count;
    }
    assert(drawn == kCloudMaxCardRows);   /* nothing dropped: it fits */
    assert_boxes_are_well_formed(&l, &pane);
}

int main(void)
{
    test_classification_reads_the_value_not_the_label();
    test_order_is_phone_email_address_then_everything_else();
    test_ambiguous_and_empty_values_fall_to_other();
    test_long_date_values_parse();
    test_layout_at_the_smallest_honest_pane();
    test_layout_shrinks_the_well_on_a_tiny_pane();
    test_layout_on_an_empty_pane_is_inert();
    test_layout_null_is_safe();
    test_sections_are_phone_email_address_other_and_fit();
    test_a_section_with_no_rows_is_absent();
    test_one_section_leaves_no_box_shaped_hole();
    test_no_card_rows_yet_draws_no_boxes();
    test_a_stack_too_tall_is_truncated_not_spilled();
    test_the_worst_case_card_still_fits_the_judged_pane();
    printf("cloud_contacts_card_test: all assertions passed\n");
    return 0;
}
