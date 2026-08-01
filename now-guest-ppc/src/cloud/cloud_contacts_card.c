#include "cloud_contacts_card.h"

#include <string.h>

/* See the header for why classification reads the value, not the
   label. */

static Boolean is_digit_c(char c)
{
    return c >= '0' && c <= '9';
}

static Boolean looks_like_phone(const char *v)
{
    int digits = 0;
    const char *p;

    if (v == NULL || v[0] == '\0') {
        return 0;
    }
    for (p = v; *p != '\0'; ++p) {
        if (is_digit_c(*p)) {
            ++digits;
            continue;
        }
        switch (*p) {
        case ' ': case '(': case ')': case '+': case '-':
        case '.': case '/':
            continue;
        default:
            return 0;
        }
    }
    /* A short digit run ("12345") reads as a zip code or a room
       number, not a phone number; a real one has an area code. */
    return digits >= 7 && digits <= 20;
}

static Boolean looks_like_email(const char *v)
{
    const char *at;

    if (v == NULL) {
        return 0;
    }
    at = strchr(v, '@');
    return at != NULL && at != v && at[1] != '\0';
}

CloudContactsRowKind cloud_contacts_classify_row(const CloudCardRow *row)
{
    if (row == NULL) {
        return kCloudContactsRowOther;
    }
    /* Email first: an address value can itself contain digit runs
       that would otherwise pass looks_like_phone, but never an '@'
       (a phone number never carries one either). */
    if (looks_like_email(row->value)) {
        return kCloudContactsRowEmail;
    }
    if (looks_like_phone(row->value)) {
        return kCloudContactsRowPhone;
    }
    return kCloudContactsRowOther;
}

int cloud_contacts_order_card(const CloudCardRow *card, int card_count,
                              int order[kCloudMaxCardRows])
{
    int n = 0;
    int i;

    if (card_count > kCloudMaxCardRows) {
        card_count = kCloudMaxCardRows;
    }
    if (card_count < 0) {
        card_count = 0;
    }
    for (i = 0; i < card_count; ++i) {
        if (cloud_contacts_classify_row(&card[i]) == kCloudContactsRowOther) {
            order[n++] = i;
        }
    }
    for (i = 0; i < card_count; ++i) {
        if (cloud_contacts_classify_row(&card[i]) == kCloudContactsRowPhone) {
            order[n++] = i;
        }
    }
    for (i = 0; i < card_count; ++i) {
        if (cloud_contacts_classify_row(&card[i]) == kCloudContactsRowEmail) {
            order[n++] = i;
        }
    }
    return n;
}

static const char *k_months[12] = {
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December"
};

Boolean cloud_contacts_parse_long_date(const char *value, int *year,
                                       int *month, int *day)
{
    int m;
    const char *p = NULL;
    int d = 0, y = 0;

    if (value == NULL) {
        return 0;
    }
    for (m = 0; m < 12; ++m) {
        size_t len = strlen(k_months[m]);

        if (strncmp(value, k_months[m], len) == 0 && value[len] == ' ') {
            p = value + len + 1;
            break;
        }
    }
    if (p == NULL) {
        return 0;
    }
    if (!is_digit_c(*p)) {
        return 0;
    }
    while (is_digit_c(*p)) {
        d = d * 10 + (*p - '0');
        ++p;
    }
    if (p[0] != ',' || p[1] != ' ') {
        return 0;
    }
    p += 2;
    if (!is_digit_c(*p)) {
        return 0;
    }
    while (is_digit_c(*p)) {
        y = y * 10 + (*p - '0');
        ++p;
    }
    if (*p != '\0') {
        return 0;              /* trailing text: not confidently a date */
    }
    if (d < 1 || d > 31 || y < 1600 || y > 3999) {
        return 0;
    }
    *year = y;
    *month = m + 1;
    *day = d;
    return 1;
}
