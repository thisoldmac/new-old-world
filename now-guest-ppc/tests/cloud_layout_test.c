/* The iCloud page's geometry:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_layout_test.c ../src/cloud/cloud_layout.c -o /tmp/t && /tmp/t
   Click and draw read these rectangles; what is worth proving is that
   they stay inside the body, do not overlap, and survive the smallest
   honest screen (640x480 body). */

#include <assert.h>
#include <stdio.h>

#include "cloud_layout.h"

/* An empty rect the way cloud_layout.c makes one: zero area. Checked
   by relationship (right <= left or bottom <= top), not by comparing
   against a coordinate copied out of the implementation. */
static int is_empty(Rect r)
{
    return r.right <= r.left || r.bottom <= r.top;
}

static void check_body(short left, short top, short right, short bottom)
{
    Rect body;
    CloudLayout r;

    body.left = left;
    body.top = top;
    body.right = right;
    body.bottom = bottom;
    cloud_layout_compute(&body, 0, &r);

    /* Everything inside the body. */
    assert(r.popup.left >= body.left && r.refresh_btn.right <= body.right);
    assert(r.list.top >= body.top && r.status.bottom <= body.bottom);
    assert(r.detail.right <= body.right);

    /* The toolbar above the panes, the panes above the status line. */
    assert(r.popup.bottom <= r.list.top);
    assert(r.list.bottom <= r.status.top);
    assert(r.detail.bottom <= r.status.top);

    /* List and card side by side, never overlapping. */
    assert(r.list.right <= r.detail.left);

    /* Save sits inside the card pane, and the card text stops above
       it — a button drawn over the last row is a card nobody can
       read. */
    assert(r.save_btn.left >= r.detail.left);
    assert(r.save_btn.bottom <= r.detail.bottom);
    assert(r.detail_text.bottom <= r.save_btn.top);

    /* Wide enough to use on the smallest screen: the list carries
       31-character titles, the card carries labelled values. */
    assert(r.list.right - r.list.left >= 200);
    assert(r.detail.right - r.detail.left >= 150);

    /* The navigation cluster belongs to drive mode only; outside it,
       every piece is the anti-rect, not a button parked somewhere
       unreachable — and the breadcrumb row with them. */
    assert(is_empty(r.up_btn));
    assert(is_empty(r.back_btn));
    assert(is_empty(r.fwd_btn));
    assert(is_empty(r.path_row));

    /* The search field: real in both modes, in the toolbar row,
       between the popup and whatever sits right of it, wide enough to
       type into. */
    assert(!is_empty(r.toolbar_search));
    assert(r.toolbar_search.left >= r.popup.right);
    assert(r.toolbar_search.right <= r.refresh_btn.left);
    assert(r.toolbar_search.bottom <= r.list.top);
    assert(r.toolbar_search.right - r.toolbar_search.left >= 80);

    /* The photos furniture: real rects inside the card pane, stacked
       bottom-up (Save row, destination row, bar, byte line) without
       overlap, and photos_text stops above the whole stack so the
       preview never draws under a live control. */
    assert(!is_empty(r.size_popup));
    assert(!is_empty(r.dest_row));
    assert(!is_empty(r.dest_btn));
    assert(!is_empty(r.dl_bar));
    assert(!is_empty(r.dl_text));
    assert(!is_empty(r.photos_text));
    assert(r.size_popup.left >= r.detail.left);
    assert(r.size_popup.right <= r.detail.right);
    assert(r.size_popup.bottom <= r.save_btn.top);
    assert(r.dest_row.bottom <= r.size_popup.top);
    assert(r.dest_btn.bottom <= r.size_popup.top);
    assert(r.dest_row.right <= r.dest_btn.left);
    assert(r.dest_btn.right <= r.detail.right);

    /* The cleanup's whole rule, asserted as relationships: one shared
       right edge for the control column, uniform row heights, uniform
       gaps, and the label row exactly as tall as its button. */
    assert(r.save_btn.right == r.size_popup.right);
    assert(r.size_popup.right == r.dest_btn.right);
    assert(r.save_btn.bottom - r.save_btn.top
           == r.size_popup.bottom - r.size_popup.top);
    assert(r.size_popup.bottom - r.size_popup.top
           == r.dest_btn.bottom - r.dest_btn.top);
    assert(r.save_btn.top - r.size_popup.bottom
           == r.size_popup.top - r.dest_btn.bottom);
    assert(r.dest_row.top == r.dest_btn.top);
    assert(r.dest_row.bottom == r.dest_btn.bottom);
    assert(r.dl_bar.bottom <= r.dest_row.top);
    assert(r.dl_text.bottom <= r.dl_bar.top);
    assert(r.photos_text.bottom <= r.dl_text.top);
    assert(r.photos_text.top == r.detail_text.top);
    assert(r.photos_text.left == r.detail_text.left);
    /* Still enough pane to show a photo on the smallest screen. */
    assert(r.photos_text.bottom - r.photos_text.top >= 150);
    /* Wide enough for their words: the popup wears "Fit 1024x768",
       the button wears "Choose...". */
    assert(r.size_popup.right - r.size_popup.left >= 110);
    assert(r.dest_btn.right - r.dest_btn.left >= 60);
}

/* Drive mode against the same body a list-mode call would take:
   the assertions compare the two layouts to each other rather than
   asserting a coordinate this test would otherwise have to copy out
   of cloud_layout.c to know. */
static void check_drive_body(short left, short top, short right,
                             short bottom)
{
    Rect body;
    CloudLayout list_r, drive_r;

    body.left = left;
    body.top = top;
    body.right = right;
    body.bottom = bottom;
    cloud_layout_compute(&body, 0, &list_r);
    cloud_layout_compute(&body, 1, &drive_r);

    /* Everything still inside the body. */
    assert(drive_r.list.left >= body.left);
    assert(drive_r.list.right <= body.right);
    assert(drive_r.list.top >= body.top);
    assert(drive_r.list.bottom <= body.bottom);

    /* The browser IS the page: wider than the list-mode list at the
       same body, and it reaches at least as far right as list mode's
       card pane used to (nothing held back on its right for a card
       that no longer draws). */
    assert(drive_r.list.right - drive_r.list.left
           > list_r.list.right - list_r.list.left);
    assert(drive_r.list.right >= list_r.detail.right);

    /* No card: detail, its text and Save all collapse to the
       anti-rect — and the photos furniture with them, EXCEPT
       dest_row/dest_btn, which drive mode fills with its own
       destination row instead of leaving empty. */
    assert(is_empty(drive_r.detail));
    assert(is_empty(drive_r.detail_text));
    assert(is_empty(drive_r.save_btn));
    assert(is_empty(drive_r.size_popup));
    assert(is_empty(drive_r.dl_bar));
    assert(is_empty(drive_r.dl_text));
    assert(is_empty(drive_r.photos_text));

    /* Drive's own destination row: real, beneath the breadcrumbs and
       above the list, Choose... on the SAME right edge Refresh's
       column already uses (the 5d948ed shared-right-edge rule, one
       lane over from the photos card's version of it), the label
       filling what is left of the row, uniform height with the
       breadcrumb row above it. */
    assert(!is_empty(drive_r.dest_row));
    assert(!is_empty(drive_r.dest_btn));
    assert(drive_r.dest_btn.right == drive_r.refresh_btn.right);
    assert(drive_r.dest_row.top == drive_r.dest_btn.top);
    assert(drive_r.dest_row.bottom == drive_r.dest_btn.bottom);
    assert(drive_r.dest_row.right <= drive_r.dest_btn.left);
    assert(drive_r.dest_row.left >= body.left);
    assert(drive_r.dest_btn.right <= body.right);
    assert(drive_r.dest_row.top >= drive_r.path_row.bottom);
    assert(drive_r.dest_row.bottom <= drive_r.list.top);
    /* Uniform row height within the destination row itself (the
       5d948ed rule applied to its own two pieces — it does not bind
       path_row, which is plain breadcrumb text with no button beside
       it and a different height already, by design). */
    assert(drive_r.dest_row.bottom - drive_r.dest_row.top
           == drive_r.dest_btn.bottom - drive_r.dest_btn.top);
    assert(drive_r.dest_btn.right - drive_r.dest_btn.left >= 60);

    /* The navigation cluster is real in drive mode: nonzero areas,
       in the toolbar row (at or above the list's top, same rule the
       popup/refresh buttons already follow), reading Back, Forward,
       Up, Refresh left to right without overlap. */
    assert(!is_empty(drive_r.up_btn));
    assert(!is_empty(drive_r.back_btn));
    assert(!is_empty(drive_r.fwd_btn));
    assert(drive_r.up_btn.bottom <= drive_r.list.top);
    assert(drive_r.back_btn.bottom <= drive_r.list.top);
    assert(drive_r.fwd_btn.bottom <= drive_r.list.top);
    assert(drive_r.back_btn.right <= drive_r.fwd_btn.left);
    assert(drive_r.fwd_btn.right <= drive_r.up_btn.left);
    assert(drive_r.up_btn.right <= drive_r.refresh_btn.left);
    assert(drive_r.back_btn.left >= body.left);

    /* Wide enough for a person to hit: the Back/Forward pair are
       small but real buttons, Up still fits its word. */
    assert(drive_r.back_btn.right - drive_r.back_btn.left >= 20);
    assert(drive_r.fwd_btn.right - drive_r.fwd_btn.left >= 20);
    assert(drive_r.up_btn.right - drive_r.up_btn.left >= 32);

    /* The search field yields to the cluster's left edge in drive
       mode instead of overlapping it, and stays typable. */
    assert(!is_empty(drive_r.toolbar_search));
    assert(drive_r.toolbar_search.right <= drive_r.back_btn.left);
    assert(drive_r.toolbar_search.right - drive_r.toolbar_search.left
           >= 48);

    /* Breadcrumbs: a real row between the toolbar and the list, full
       width like the list it describes. */
    assert(!is_empty(drive_r.path_row));
    assert(drive_r.path_row.top >= drive_r.popup.bottom);
    assert(drive_r.path_row.top >= drive_r.toolbar_search.bottom);
    assert(drive_r.path_row.bottom <= drive_r.list.top);
    assert(drive_r.path_row.left >= body.left);
    assert(drive_r.path_row.right <= body.right);
    assert(drive_r.path_row.right - drive_r.path_row.left
           >= drive_r.list.right - drive_r.list.left);
}

int main(void)
{
    /* The Workshop body on a 640x480 screen, and a roomier one. */
    check_body(160, 60, 630, 450);
    check_body(160, 60, 1000, 700);
    check_drive_body(160, 60, 630, 450);
    check_drive_body(160, 60, 1000, 700);
    printf("cloud_layout_test: all assertions passed\n");
    return 0;
}
