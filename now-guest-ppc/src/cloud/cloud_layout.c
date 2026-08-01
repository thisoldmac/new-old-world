#include "cloud_layout.h"

static void set_rect(Rect *r, short left, short top,
                     short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void cloud_layout_compute(const Rect *body, CloudLayout *r)
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

    /* Status is ABOVE the bottom edge, under both panes. */
    set_rect(&r->status, left, (short)(bottom - 14), right, bottom);
    list_bottom = (short)(r->status.top - 8);

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
