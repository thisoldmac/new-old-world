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

    assert(cloud_contacts_classify_row(&home_phone) == kCloudContactsRowPhone);
    assert(cloud_contacts_classify_row(&work_phone) == kCloudContactsRowPhone);
    assert(cloud_contacts_classify_row(&home_email) == kCloudContactsRowEmail);
    assert(cloud_contacts_classify_row(&work_email) == kCloudContactsRowEmail);
    assert(cloud_contacts_classify_row(&name) == kCloudContactsRowOther);
    assert(cloud_contacts_classify_row(&company) == kCloudContactsRowOther);
    /* Addresses are not one of the two grouped kinds; they stay with
       the rest ("phone/email rows grouped", nothing said of address). */
    assert(cloud_contacts_classify_row(&address) == kCloudContactsRowOther);
}

static void test_order_groups_phones_then_emails_after_everything_else(void)
{
    CloudCardRow card[6];
    int order[kCloudMaxCardRows];
    int n;

    card[0] = mk("Name", "Ada Lovelace");
    card[1] = mk("work", "ada@example.com");      /* email, arrives 2nd */
    card[2] = mk("Company", "Acme");
    card[3] = mk("home", "+1 555 000 1111");       /* phone, arrives 4th */
    card[4] = mk("work", "+1 555 222 3333");       /* phone, arrives 5th */
    card[5] = mk("home", "ada@home.example");      /* email, arrives 6th */

    n = cloud_contacts_order_card(card, 6, order);
    assert(n == 6);
    /* Everything else, arrival order... */
    assert(order[0] == 0);                         /* Name */
    assert(order[1] == 2);                         /* Company */
    /* ...then every phone, arrival order preserved... */
    assert(order[2] == 3);
    assert(order[3] == 4);
    /* ...then every email, arrival order preserved. */
    assert(order[4] == 1);
    assert(order[5] == 5);
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
    cloud_contacts_card_layout(&pane, &l);

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
    cloud_contacts_card_layout(&pane, &l);

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
    cloud_contacts_card_layout(&pane, &l);

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

    cloud_contacts_card_layout(NULL, &l);
    cloud_contacts_card_layout(&pane, NULL);
}

int main(void)
{
    test_classification_reads_the_value_not_the_label();
    test_order_groups_phones_then_emails_after_everything_else();
    test_ambiguous_and_empty_values_fall_to_other();
    test_long_date_values_parse();
    test_layout_at_the_smallest_honest_pane();
    test_layout_shrinks_the_well_on_a_tiny_pane();
    test_layout_on_an_empty_pane_is_inert();
    test_layout_null_is_safe();
    printf("cloud_contacts_card_test: all assertions passed\n");
    return 0;
}
