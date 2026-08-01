#include "cloud_contacts_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_contacts_card.h"
#include "cloud_filter.h"

/* The Contacts card, drawn in the classic Address Book's own shape:
   a right-aligned label column, values starting at a fixed left
   margin, phone rows grouped together and email rows grouped after
   them (cloud_contacts_card.h decides which is which and in what
   order -- this file only draws). No Save button: cloud.get on
   contacts is refused not-listable by the contract (x-cloud,
   contacts), and cloud_module.c's action_applies() already knows to
   keep the button hidden for this service, so there is nothing here
   to click. */

enum {
    kLabelColWidth = 72,       /* label column width, right edge to text */
    kColGap = 10,              /* between the label column and values */
    kRowHeight = 14,
    kGroupGap = 8              /* extra space where the row kind changes */
};

static void draw_left(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

/* Right-aligned so the label column reads the way the classic Address
   Book's card does: "   home:" ending flush above "   work:". */
static void draw_label(short right_edge, short y, const char *label)
{
    Str255 t;
    short w;

    CopyCStringToPascal(label, t);
    w = StringWidth(t);
    MoveTo((short)(right_edge - w), y);
    DrawString(t);
}

/* today's value if it parses as a recognisable long date, rendered
   through LongDateString in the reader's own machine's date format --
   the whole reason cloud_contacts_card.h hands back components rather
   than this file trying to reformat English text itself. False (line
   left undrawn by the caller) if it is not a date this can read. */
static Boolean draw_date_value(short x, short y, const char *value)
{
    int year, month, day;
    LongDateRec rec;
    LongDateTime ldt;
    Str255 when;

    if (!cloud_contacts_parse_long_date(value, &year, &month, &day)) {
        return false;
    }
    memset(&rec, 0, sizeof rec);
    rec.ld.era = 0;
    rec.ld.year = (short)year;
    rec.ld.month = (short)month;
    rec.ld.day = (short)day;
    rec.ld.hour = 0;
    rec.ld.minute = 0;
    rec.ld.second = 0;
    rec.ld.dayOfWeek = 1;      /* LongDateToSeconds derives the real one */
    LongDateToSeconds(&rec, &ldt);
    LongDateString(&ldt, longDate, when, NULL);
    MoveTo(x, y);
    DrawString(when);
    return true;
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    short label_right = (short)(r->detail_text.left + kLabelColWidth);
    short value_left = (short)(label_right + kColGap);
    short y = (short)(r->detail_text.top + 12);
    int order[kCloudMaxCardRows];
    int n, i;
    CloudContactsRowKind last_kind = kCloudContactsRowOther;
    Boolean first = true;

    if (store->card_count > 0) {
        n = cloud_contacts_order_card(store->card, store->card_count, order);
        for (i = 0; i < n && y < r->detail_text.bottom; ++i) {
            const CloudCardRow *row = &store->card[order[i]];
            CloudContactsRowKind kind = cloud_contacts_classify_row(row);
            char value[136];

            if (!first && kind != last_kind) {
                y = (short)(y + kGroupGap);
                if (y >= r->detail_text.bottom) {
                    break;
                }
            }
            first = false;
            last_kind = kind;

            draw_label(label_right, y, row->label);
            if (!draw_date_value(value_left, y, row->value)) {
                snprintf(value, sizeof value, "%.128s", row->value);
                draw_left(value_left, y, value);
            }
            y = (short)(y + kRowHeight);
        }
        return;
    }
    /* No card yet: the same fallback words the generic list view
       shows -- the service's own state/detail, or a nudge to pick a
       row, so a person sees why the pane is blank. */
    if (service != NULL && strcmp(service->state, "serving") != 0) {
        draw_left(r->detail_text.left, y, service->label);
        y = (short)(y + 16);
        if (service->detail[0] != '\0') {
            draw_left(r->detail_text.left, y, service->detail);
        }
        return;
    }
    if (selected < 0 && store->row_count > 0) {
        draw_left(r->detail_text.left, y, "Select a name to see its card.");
    }
}

/* The name list is the shell's shared rows too (title = display name,
   subtitle = whatever the host chose to show under it) — same
   predicate cloud_list_view.c uses, same reason: the two fields the
   Data Browser already shows. */
static Boolean view_row_matches(int index, const CloudStore *store,
                                const char *needle)
{
    const CloudRow *row;

    if (store == NULL || index < 0 || index >= store->row_count) {
        return false;
    }
    row = &store->rows[index];
    return cloud_filter_matches_either(row->title, row->subtitle, needle);
}

static const CloudViewOps k_ops = {
    NULL,                              /* create */
    NULL,                              /* show */
    NULL,                              /* layout */
    view_draw,
    NULL,                              /* click: no button is ever shown */
    NULL,                              /* key: generic HandleControlKey */
    NULL,                              /* idle: nothing to watch */
    NULL,                              /* reset_for_service: ask_rows(1) */
    view_row_matches
};

const CloudViewOps *cloud_contacts_view_ops(void)
{
    return &k_ops;
}
