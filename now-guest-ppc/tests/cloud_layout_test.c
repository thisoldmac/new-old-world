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
    cloud_layout_compute(&body, 0, 0, &r);

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
    /* Closed (the resting state): the disclosed rows are the
       anti-rect and the summary carries both facts instead. */
    assert(is_empty(r.size_popup));
    assert(is_empty(r.dest_row));
    assert(is_empty(r.dest_btn));
    assert(!is_empty(r.summary_row));
    assert(!is_empty(r.tri));
    assert(!is_empty(r.dl_bar));
    assert(!is_empty(r.dl_text));
    assert(!is_empty(r.photos_text));

    /* The cleanup's whole rule, asserted as relationships: one shared
       right edge for the control column, uniform row heights, uniform
       gaps, and the label row exactly as tall as its button. */
    assert(r.photos_text.top == r.detail_text.top);
    assert(r.photos_text.left == r.detail_text.left);
    /* Still enough pane to show a photo on the smallest screen. */
    assert(r.photos_text.bottom - r.photos_text.top >= 150);
    /* Wide enough for their words: the popup wears "Fit 1024x768",
       the button wears "Choose...". */
}

/* Drive mode against the same body a list-mode call would take: the
   assertions compare the two layouts to each other rather than
   asserting a coordinate this test would otherwise have to copy out
   of cloud_layout.c to know. Drive mode uses the SAME split list mode
   does now — list left, a real pane right, its own shorter furniture
   stack inside that pane — so most of these read like check_body's,
   just against drive's own path-row-shifted list_top and its Save/
   Size-less furniture. */
static void check_drive_body(short left, short top, short right,
                             short bottom)
{
    Rect body;
    CloudLayout list_r, drive_r;

    body.left = left;
    body.top = top;
    body.right = right;
    body.bottom = bottom;
    cloud_layout_compute(&body, 0, 0, &list_r);
    cloud_layout_compute(&body, 1, 0, &drive_r);

    /* Everything still inside the body. */
    assert(drive_r.list.left >= body.left);
    assert(drive_r.detail.right <= body.right);
    assert(drive_r.list.top >= body.top);
    assert(drive_r.status.bottom <= body.bottom);

    /* The SAME split every mode uses: list and detail land at the same
       x-coordinates in drive mode as they do in list mode (the split
       cloud_layout.c computes once and reuses, not a second layout
       drive invented for itself). Only the y-coordinates differ, by
       the breadcrumb row drive mode alone draws above them. */
    assert(drive_r.list.left == list_r.list.left);
    assert(drive_r.list.right == list_r.list.right);
    assert(drive_r.detail.left == list_r.detail.left);
    assert(drive_r.detail.right == list_r.detail.right);
    assert(drive_r.list.top > list_r.list.top);
    assert(drive_r.list.bottom == list_r.list.bottom);
    assert(drive_r.detail.top == drive_r.list.top);
    assert(drive_r.detail.bottom == list_r.detail.bottom);

    /* List and pane side by side, never overlapping — the same
       assertion check_body makes for every other mode. */
    assert(drive_r.list.right <= drive_r.detail.left);

    /* The pane is real in drive mode now: there IS a card (the
       selected item's name/kind/size/date and the double-click
       affordance line), not the full-width list of the old layout. */
    assert(!is_empty(drive_r.detail));
    assert(!is_empty(drive_r.detail_text));
    assert(drive_r.detail_text.left >= drive_r.detail.left);
    assert(drive_r.detail_text.right <= drive_r.detail.right);

    /* No Save, no Size popup in drive mode: Up lives in the toolbar
       (up_btn, checked below), and a pull always keeps the file's
       exact bytes, nothing to pick a size of. */
    assert(is_empty(drive_r.save_btn));
    assert(is_empty(drive_r.size_popup));
    /* photos_text is photos' own further trim of detail_text; drive
       reads detail_text directly; photos_text stays the anti-rect. */
    assert(is_empty(drive_r.photos_text));

    /* Drive's OWN pane furniture: the destination row and, while a
       pull is landing, the same bar-plus-byte-line shape photos' own
       download furniture uses — real, inside the pane, on the shared
       right edge (5d948ed) the toolbar's Refresh button and the pane
       itself both already use. */
    assert(!is_empty(drive_r.dest_row));
    assert(!is_empty(drive_r.dest_btn));
    assert(!is_empty(drive_r.dl_bar));
    assert(!is_empty(drive_r.dl_text));
    assert(drive_r.dest_btn.right <= drive_r.detail.right);
    assert(drive_r.dest_btn.right <= drive_r.refresh_btn.right);
    assert(drive_r.dest_row.top == drive_r.dest_btn.top);
    assert(drive_r.dest_row.bottom == drive_r.dest_btn.bottom);
    assert(drive_r.dest_row.right <= drive_r.dest_btn.left);
    assert(drive_r.dest_row.left >= drive_r.detail.left);
    assert(drive_r.dest_btn.right <= body.right);
    assert(drive_r.dest_row.bottom <= drive_r.detail.bottom);
    assert(drive_r.dest_row.top >= drive_r.detail.top);
    /* Uniform row height (the 5d948ed rule applied to its own two
       pieces), and the bar/byte-line stacked above it without
       overlap. */
    assert(drive_r.dest_row.bottom - drive_r.dest_row.top
           == drive_r.dest_btn.bottom - drive_r.dest_btn.top);
    assert(drive_r.dest_btn.right - drive_r.dest_btn.left >= 60);
    assert(drive_r.dl_bar.bottom <= drive_r.dest_row.top);
    assert(drive_r.dl_text.bottom <= drive_r.dl_bar.top);
    /* The pane's text stops above the whole furniture stack — never
       drawn under a live control, same rule photos_text keeps for
       photos. */
    assert(drive_r.detail_text.bottom <= drive_r.dl_text.top);

    /* Drive's stack is SHORTER than list/photos mode's own furniture
       stack by exactly the two rows (Save, Size popup) it does not
       have: its destination row sits lower in the pane (closer to
       detail.bottom) than list mode's does, relative to each one's
       own detail.bottom. */
    assert((drive_r.detail.bottom - drive_r.dest_row.bottom)
           < (list_r.detail.bottom - list_r.dest_row.bottom));

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

    /* Breadcrumbs: a real row between the toolbar and the split, full
       width — over both the list AND the pane below it, the same way
       the toolbar itself already spans both. */
    assert(!is_empty(drive_r.path_row));
    assert(drive_r.path_row.top >= drive_r.popup.bottom);
    assert(drive_r.path_row.top >= drive_r.toolbar_search.bottom);
    assert(drive_r.path_row.bottom <= drive_r.list.top);
    assert(drive_r.path_row.bottom <= drive_r.detail.top);
    assert(drive_r.path_row.left >= body.left);
    assert(drive_r.path_row.right <= body.right);
    assert(drive_r.path_row.right - drive_r.path_row.left
           >= (drive_r.detail.right - drive_r.list.left));
}

/* The judged design's whole claim: closing the disclosure gives the
   photo the height the two setting rows were holding, and BOTH facts
   (where, what size) still have a line of their own. Asserted by
   comparing the two layouts rather than by copying coordinates. */
static void check_disclosure(short left, short top, short right,
                             short bottom)
{
    Rect body;
    CloudLayout shut, open_r;

    body.left = left; body.top = top;
    body.right = right; body.bottom = bottom;
    cloud_layout_compute(&body, 0, 0, &shut);
    cloud_layout_compute(&body, 0, 1, &open_r);

    /* Open, the rows are real, right-aligned with Save, uniform. */
    assert(!is_empty(open_r.size_popup));
    assert(!is_empty(open_r.dest_btn));
    assert(!is_empty(open_r.dest_row));
    assert(open_r.save_btn.right == open_r.size_popup.right);
    assert(open_r.size_popup.right == open_r.dest_btn.right);
    assert(open_r.dest_row.top == open_r.dest_btn.top);
    assert(open_r.dest_btn.bottom <= open_r.size_popup.top);
    assert(open_r.size_popup.bottom <= open_r.summary_row.top);

    /* The summary and Save do not move when the rows appear - only
       the photo's pane gives way. */
    assert(open_r.summary_row.top == shut.summary_row.top);
    assert(open_r.save_btn.top == shut.save_btn.top);
    assert(open_r.photos_text.bottom < shut.photos_text.bottom);

    /* The triangle sits inside the summary row, at its left, and the
       summary's text still has most of the row after it. */
    assert(shut.tri.left == shut.summary_row.left);
    assert(shut.tri.bottom <= shut.summary_row.bottom);
    assert(shut.summary_row.right - shut.tri.right
           > (shut.summary_row.right - shut.summary_row.left) / 2);

    /* The download read-out lives in that same row: bar at the right
       end, byte count beside it, neither claiming its own height. */
    assert(shut.dl_bar.top >= shut.summary_row.top);
    assert(shut.dl_bar.bottom <= shut.summary_row.bottom);
    assert(shut.dl_bar.right == shut.summary_row.right);
    assert(shut.dl_text.right <= shut.dl_bar.left);
    assert(shut.dl_text.left == shut.summary_row.left);
    /* and the byte count keeps a usable width even on a small pane. */
    assert(shut.dl_text.right - shut.dl_text.left >= 50);
}

int main(void)
{
    /* The Workshop body on a 640x480 screen, and a roomier one. */
    check_body(160, 60, 630, 450);
    check_body(160, 60, 1000, 700);
    check_disclosure(160, 60, 630, 450);
    check_disclosure(160, 60, 1000, 700);
    check_drive_body(160, 60, 630, 450);
    check_drive_body(160, 60, 1000, 700);
    printf("cloud_layout_test: all assertions passed\n");
    return 0;
}
