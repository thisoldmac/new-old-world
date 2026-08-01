#include "cloud_layout.h"

static void set_rect(Rect *r, short left, short top,
                     short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

/* The anti-rect: zero area, so "empty" is checkable the same way for
   every field (right <= left, bottom <= top) without a separate flag
   per rect. cloud_module.c leans on this to skip drawing/tracking a
   field that landed here rather than asking g_drive_mode a second
   time. */
static void set_empty(Rect *r, short at_left, short at_top)
{
    r->left = at_left;
    r->right = at_left;
    r->top = at_top;
    r->bottom = at_top;
}

void cloud_layout_compute(const Rect *body, Boolean drive_mode,
                          CloudLayout *r)
{
    short left = (short)(body->left + 10);
    short right = (short)(body->right - 10);
    short top = (short)(body->top + 8);
    short bottom = (short)(body->bottom - 8);
    short split;
    short list_bottom;

    /* The toolbar: dropdown left, Refresh right. The popup is wide
       because it wears the service label inside it. */
    set_rect(&r->popup, left, top, (short)(left + 190), (short)(top + 20));
    set_rect(&r->refresh_btn, (short)(right - 70), (short)(top + 1),
             right, (short)(top + 19));

    /* Up rides the same toolbar row, just left of Refresh, ONLY in
       drive mode - the list/card views have no equivalent action up
       here (Save lives in the card pane instead). Outside drive mode
       it collapses to the anti-rect at the same corner Refresh starts
       from, so a stray draw call there paints nothing rather than a
       stale button-shaped rectangle. */
    if (drive_mode) {
        set_rect(&r->up_btn, (short)(r->refresh_btn.left - 56),
                 (short)(top + 1), (short)(r->refresh_btn.left - 6),
                 (short)(top + 19));
    } else {
        set_empty(&r->up_btn, r->refresh_btn.left, (short)(top + 1));
    }

    /* Status is ABOVE the bottom edge, under both panes. */
    set_rect(&r->status, left, (short)(bottom - 14), right, bottom);
    list_bottom = (short)(r->status.top - 8);

    if (drive_mode) {
        /* No card in drive mode: the browser IS the page, full body
           width, and detail/save collapse to anti-rects at its right
           edge rather than being placed off to one side - "empty",
           not "elsewhere". Pull progress that used to draw into the
           card moves to the status placard (cloud_drive_view.c). */
        set_rect(&r->list, left, (short)(top + 28), right, list_bottom);
        set_empty(&r->detail, right, (short)(top + 28));
        set_empty(&r->detail_text, right, (short)(top + 28));
        set_empty(&r->save_btn, right, list_bottom);
        return;
    }

    /* List left, card right. The list carries titles up to 31-plus
       characters; give it the wider share of a 640-wide body but keep
       the card readable at 640x480 (the smallest honest screen). */
    split = (short)(body->left + ((body->right - body->left) * 11) / 20);
    set_rect(&r->list, left, (short)(top + 28), split, list_bottom);
    set_rect(&r->detail, (short)(split + 8), (short)(top + 28),
             right, list_bottom);
    set_rect(&r->save_btn, (short)(right - 110),
             (short)(r->detail.bottom - 24), right,
             (short)(r->detail.bottom - 4));
    r->detail_text = r->detail;
    r->detail_text.left = (short)(r->detail_text.left + 6);
    r->detail_text.right = (short)(r->detail_text.right - 4);
    r->detail_text.top = (short)(r->detail_text.top + 4);
    r->detail_text.bottom = (short)(r->save_btn.top - 6);
}
