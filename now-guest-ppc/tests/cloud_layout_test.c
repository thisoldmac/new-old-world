/* The iCloud page's geometry:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_layout_test.c ../src/cloud/cloud_layout.c -o /tmp/t && /tmp/t
   Click and draw read these rectangles; what is worth proving is that
   they stay inside the body, do not overlap, and survive the smallest
   honest screen (640x480 body). */

#include <assert.h>
#include <stdio.h>

#include "cloud_layout.h"

static void check_body(short left, short top, short right, short bottom)
{
    Rect body;
    CloudLayout r;

    body.left = left;
    body.top = top;
    body.right = right;
    body.bottom = bottom;
    cloud_layout_compute(&body, &r);

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
}

int main(void)
{
    /* The Workshop body on a 640x480 screen, and a roomier one. */
    check_body(160, 60, 630, 450);
    check_body(160, 60, 1000, 700);
    printf("cloud_layout_test: all assertions passed\n");
    return 0;
}
