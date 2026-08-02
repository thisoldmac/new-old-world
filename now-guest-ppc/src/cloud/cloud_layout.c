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

    /* The navigation cluster rides the same toolbar row, left of
       Refresh, ONLY in drive mode - the list/card views have no
       equivalent actions up here (Save lives in the card pane
       instead). Left to right: Back, Forward (a tight pair, titled
       "<" and ">"), then Up, then Refresh. Outside drive mode all
       three collapse to the anti-rect at the same corner Refresh
       starts from, so a stray draw call there paints nothing rather
       than a stale button-shaped rectangle. */
    if (drive_mode) {
        set_rect(&r->up_btn, (short)(r->refresh_btn.left - 46),
                 (short)(top + 1), (short)(r->refresh_btn.left - 6),
                 (short)(top + 19));
        set_rect(&r->fwd_btn, (short)(r->up_btn.left - 32),
                 (short)(top + 1), (short)(r->up_btn.left - 6),
                 (short)(top + 19));
        set_rect(&r->back_btn, (short)(r->fwd_btn.left - 28),
                 (short)(top + 1), (short)(r->fwd_btn.left - 2),
                 (short)(top + 19));
    } else {
        set_empty(&r->up_btn, r->refresh_btn.left, (short)(top + 1));
        set_empty(&r->fwd_btn, r->refresh_btn.left, (short)(top + 1));
        set_empty(&r->back_btn, r->refresh_btn.left, (short)(top + 1));
    }

    /* The search field fills the toolbar row between the popup and
       whatever real button sits right of it - back_btn (the left edge
       of the drive navigation cluster) in drive mode, refresh_btn
       otherwise (the cluster is the anti-rect there, so using it
       unconditionally would pin the field's right edge to the popup's
       own left corner). Present in both modes: Drive's rows are
       filterable by name exactly like the other views' by title. */
    {
        short right_of = drive_mode ? r->back_btn.left
                                    : r->refresh_btn.left;

        set_rect(&r->toolbar_search, (short)(r->popup.right + 8),
                 top, (short)(right_of - 8), (short)(top + 20));
    }

    /* Status is ABOVE the bottom edge, under both panes. */
    set_rect(&r->status, left, (short)(bottom - 14), right, bottom);
    list_bottom = (short)(r->status.top - 8);

    if (drive_mode) {
        /* Breadcrumbs between the toolbar and the list, the Files
           page's path row shape: where you are, from the share root
           down. */
        set_rect(&r->path_row, left, (short)(top + 26), right,
                 (short)(top + 42));
        /* No card in drive mode: the browser IS the page, full body
           width, and detail/save collapse to anti-rects at its right
           edge rather than being placed off to one side - "empty",
           not "elsewhere". Pull progress that used to draw into the
           card moves to the status placard (cloud_drive_view.c). */
        set_rect(&r->list, left, (short)(top + 46), right, list_bottom);
        set_empty(&r->detail, right, (short)(top + 46));
        set_empty(&r->detail_text, right, (short)(top + 46));
        set_empty(&r->save_btn, right, list_bottom);
        set_empty(&r->size_popup, right, list_bottom);
        set_empty(&r->dest_row, right, list_bottom);
        set_empty(&r->dest_btn, right, list_bottom);
        set_empty(&r->dl_bar, right, list_bottom);
        set_empty(&r->dl_text, right, list_bottom);
        set_empty(&r->photos_text, right, (short)(top + 46));
        return;
    }
    set_empty(&r->path_row, left, (short)(top + 26));

    /* List left, card right. The list carries titles up to 31-plus
       characters; give it the wider share of a 640-wide body but keep
       the card readable at 640x480 (the smallest honest screen). */
    split = (short)(body->left + ((body->right - body->left) * 11) / 20);
    set_rect(&r->list, left, (short)(top + 28), split, list_bottom);
    set_rect(&r->detail, (short)(split + 8), (short)(top + 28),
             right, list_bottom);
    r->detail_text = r->detail;
    r->detail_text.left = (short)(r->detail_text.left + 6);
    r->detail_text.right = (short)(r->detail_text.right - 4);
    r->detail_text.top = (short)(r->detail_text.top + 4);
    /* save_btn and detail_text.bottom are placed in the furniture
       block below, where the whole right-aligned column lives. */

    /* The photos view's furniture, stacked bottom-up over Save. Only
       rectangles — the views that do not use them never read them —
       and photos_text is what keeps the preview and the card clear of
       the rows: pixels drawn under a live control is the one overlap
       nothing would ever repaint correctly.

       The Size popup takes its own row rather than sitting beside
       Save: on the smallest honest screen the card pane's inner width
       is under 200 points, and "Save to this Mac" plus a popup that
       can say "Fit 1024x768" do not both fit on one of them. A fixed
       150 fits the widest item everywhere the pane exists at all. */
    /* Tidied to one rule (metal feedback, 2026-08-02: "clean up the
       buttons"): every CONTROL — Choose..., the Size popup, Save — is
       flush to one shared right edge, every row is 20 points tall,
       every gap between rows is 6, and the labels centre on their
       row. A column of right-aligned actions is the Platinum shape;
       the earlier layout left-aligned the popup and let the rows
       drift, which read as clutter on the real screen. */
    {
        short col_right = (short)(right - 6);
        short row_h = 20;
        short gap = 6;
        short save_top = (short)(r->detail.bottom - 8 - row_h);
        short size_top = (short)(save_top - gap - row_h);
        short dest_top = (short)(size_top - gap - row_h);

        set_rect(&r->save_btn, (short)(col_right - 110), save_top,
                 col_right, (short)(save_top + row_h));
        set_rect(&r->size_popup, (short)(col_right - 150), size_top,
                 col_right, (short)(size_top + row_h));
        set_rect(&r->dest_btn, (short)(col_right - 74), dest_top,
                 col_right, (short)(dest_top + row_h));
        set_rect(&r->dest_row, r->detail_text.left, dest_top,
                 (short)(r->dest_btn.left - 6),
                 (short)(dest_top + row_h));
        set_rect(&r->dl_bar, r->detail_text.left,
                 (short)(dest_top - gap - 12), r->detail_text.right,
                 (short)(dest_top - gap));
        set_rect(&r->dl_text, r->detail_text.left,
                 (short)(r->dl_bar.top - 4 - 14), r->detail_text.right,
                 (short)(r->dl_bar.top - 4));
        r->detail_text.bottom = (short)(r->save_btn.top - 6);
        r->photos_text = r->detail_text;
        r->photos_text.bottom = (short)(r->dl_text.top - 6);
    }
}
