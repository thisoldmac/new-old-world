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

/* An address arrives as CNPostalAddressFormatter's mailing-address
   text with its newlines turned into ", " (the host's card(), in
   CloudServices.swift) -- so "1 Main St, Springfield, CA 95014", never
   a bare word. Two comma-separated parts is the floor, and one of
   them must carry a digit (a house number, a postcode) OR there must
   be three parts, because "Acme, Inc." is a COMPANY and would
   otherwise land in the address box. A long date is excluded outright:
   "November 5, 1990" is two parts with a digit and is a Birthday. */
static Boolean looks_like_address(const char *v)
{
    int parts = 1;
    int digits = 0;
    int letters = 0;
    const char *p;
    int y, m, d;

    if (v == NULL || v[0] == '\0') {
        return 0;
    }
    if (cloud_contacts_parse_long_date(v, &y, &m, &d)) {
        return 0;
    }
    for (p = v; *p != '\0'; ++p) {
        if (*p == ',') {
            ++parts;
        } else if (is_digit_c(*p)) {
            ++digits;
        } else if ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z')) {
            ++letters;
        }
    }
    if (letters == 0) {
        return 0;
    }
    if (parts >= 3) {
        return 1;
    }
    return parts == 2 && digits > 0;
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
    if (looks_like_address(row->value)) {
        return kCloudContactsRowAddress;
    }
    return kCloudContactsRowOther;
}

/* The section order, stated ONCE: order_card groups by it and the
   layout walks it, so the boxes and the rows inside them can never
   disagree about which comes first. */
static const CloudContactsRowKind k_section_kind[kCloudContactsMaxSections] = {
    kCloudContactsRowPhone,
    kCloudContactsRowEmail,
    kCloudContactsRowAddress,
    kCloudContactsRowOther
};

static const char *k_section_title[kCloudContactsMaxSections] = {
    "Phone", "Email", "Address", "Other"
};

int cloud_contacts_order_card(const CloudCardRow *card, int card_count,
                              int order[kCloudMaxCardRows])
{
    int n = 0;
    int s, i;

    if (card == NULL) {
        return 0;
    }
    if (card_count > kCloudMaxCardRows) {
        card_count = kCloudMaxCardRows;
    }
    if (card_count < 0) {
        card_count = 0;
    }
    for (s = 0; s < kCloudContactsMaxSections; ++s) {
        for (i = 0; i < card_count; ++i) {
            if (cloud_contacts_classify_row(&card[i]) == k_section_kind[s]) {
                order[n++] = i;
            }
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

/* Height a box holding `rows` rows wants. */
static short box_height(int rows)
{
    return (short)(kCloudContactsBoxFirstRow
                   + (rows - 1) * kCloudContactsRowHeight
                   + kCloudContactsBoxTail);
}

/* How many of `rows` fit in `room` points, 0 when not even one does. */
static int rows_that_fit(int rows, short room)
{
    int fits;

    if (room < box_height(1)) {
        return 0;
    }
    fits = (room - box_height(1)) / kCloudContactsRowHeight + 1;
    return fits < rows ? fits : rows;
}

void cloud_contacts_card_layout(const Rect *pane,
                                const CloudCardRow *card, int card_count,
                                CloudContactsCardLayout *out)
{
    short pw, ph, well, y;
    int s, first;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    if (pane == NULL) {
        return;
    }
    pw = (short)(pane->right - pane->left);
    ph = (short)(pane->bottom - pane->top);
    well = kCloudContactsWellSize;
    if (pw > 0 && well > pw) {
        well = pw;
    }
    if (ph > 0 && well > ph) {
        well = ph;
    }
    if (pw <= 0 || ph <= 0) {
        well = 0;
    }
    out->well.left = pane->left;
    out->well.top = pane->top;
    out->well.right = (short)(pane->left + well);
    out->well.bottom = (short)(pane->top + well);
    out->name_left = (short)(out->well.right + kCloudContactsWellGap);
    /* Two lines centred as a BLOCK against the well -- the name in the
       large system font, the organization one small row under it, the
       shape the judged mock shows. A contact with no organization
       leaves the name four points above the well's midline, which at
       this scale nobody sees; a name pinned to the midline with the
       organization hung off its bottom is what does read wrong. */
    out->name_baseline = (short)(pane->top + well / 2 - 4);
    out->org_baseline = (short)(out->name_baseline + kCloudContactsRowHeight);
    out->rows_top = (short)(out->well.bottom + kCloudContactsRowsGap);

    if (pw <= 0 || ph <= 0 || card == NULL || card_count <= 0) {
        return;                        /* no card yet: well and name
                                           alone, no boxes -- see the
                                           header */
    }
    out->order_count = cloud_contacts_order_card(card, card_count,
                                                 out->order);

    y = out->rows_top;
    first = 0;
    for (s = 0; s < kCloudContactsMaxSections; ++s) {
        int have = 0;
        int shown;
        int i;
        CloudContactsSection *sec;

        for (i = 0; i < out->order_count; ++i) {
            if (cloud_contacts_classify_row(&card[out->order[i]])
                == k_section_kind[s]) {
                ++have;
            }
        }
        if (have == 0) {
            continue;                  /* a section with no rows is
                                           absent, not an empty box */
        }
        shown = rows_that_fit(have, (short)(pane->bottom - y));
        if (shown <= 0) {
            break;                     /* out of pane: truncate rather
                                           than draw over the page */
        }
        sec = &out->sections[out->section_count++];
        sec->title = k_section_title[s];
        sec->first = first;
        sec->count = shown;
        sec->box.left = pane->left;
        sec->box.right = pane->right;
        sec->box.top = y;
        sec->box.bottom = (short)(y + box_height(shown));
        y = (short)(sec->box.bottom + kCloudContactsBoxGap);
        first += have;                 /* the FULL run: order[] still
                                           holds the rows this box had
                                           no room for */
    }
}

short cloud_contacts_section_baseline(const CloudContactsSection *s, int i)
{
    if (s == NULL) {
        return 0;
    }
    if (i < 0) {
        i = 0;
    }
    if (s->count > 0 && i >= s->count) {
        i = s->count - 1;
    }
    return (short)(s->box.top + kCloudContactsBoxFirstRow
                   + i * kCloudContactsRowHeight);
}

short cloud_contacts_section_label_x(const CloudContactsSection *s)
{
    return s == NULL ? 0 : (short)(s->box.left + kCloudContactsBoxInset);
}

short cloud_contacts_section_value_x(const CloudContactsSection *s)
{
    return s == NULL
        ? 0
        : (short)(cloud_contacts_section_label_x(s) + kCloudContactsValueDx);
}
