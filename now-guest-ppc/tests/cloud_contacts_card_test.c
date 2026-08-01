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

int main(void)
{
    test_classification_reads_the_value_not_the_label();
    test_order_groups_phones_then_emails_after_everything_else();
    test_ambiguous_and_empty_values_fall_to_other();
    test_long_date_values_parse();
    printf("cloud_contacts_card_test: all assertions passed\n");
    return 0;
}
