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
                          Boolean photo_detail, CloudLayout *r)
{
    short left = (short)(body->left + 10);
    short right = (short)(body->right - 10);
    short top = (short)(body->top + 8);
    short bottom = (short)(body->bottom - 8);
    short split;
    short list_bottom;
    short list_top;
    short col_right;
    short gap = 6;                     /* the 5d948ed rule: every gap
                                           between rows 6 */
    short row_h = 20;                  /* and every control row 20pt */

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

    /* Breadcrumbs, and where the split content area starts under the
       toolbar: drive mode gets a real path row between the toolbar and
       the list/detail split ("iCloud Drive:Attic"); every other mode
       has no path row and the content starts at the same fixed offset
       it always has. */
    if (drive_mode) {
        set_rect(&r->path_row, left, (short)(top + 26), right,
                 (short)(top + 42));
        list_top = (short)(r->path_row.bottom + gap);
    } else {
        set_empty(&r->path_row, left, (short)(top + 26));
        list_top = (short)(top + 28);
    }

    /* List left, detail/card right - the SAME split every mode uses.
       Drive used to be a second, full-width layout with no pane at
       all; now it is this one, differing only in list_top (the
       breadcrumbs above it) and in what its own furniture below fills
       the pane with (no Save, no Size popup - see below). The list
       carries titles up to 31-plus characters; give it the wider share
       of a 640-wide body but keep the pane readable at 640x480 (the
       smallest honest screen). */
    split = (short)(body->left + ((body->right - body->left) * 11) / 20);
    set_rect(&r->list, left, list_top, split, list_bottom);
    set_rect(&r->detail, (short)(split + 8), list_top, right, list_bottom);
    r->detail_text = r->detail;
    r->detail_text.left = (short)(r->detail_text.left + 6);
    r->detail_text.right = (short)(r->detail_text.right - 4);
    r->detail_text.top = (short)(r->detail_text.top + 4);
    /* save_btn/size_popup/dest_row/dl_bar/dl_text and detail_text.bottom
       are placed in the furniture block below, where the whole
       right-aligned column lives - one for drive, one for everything
       else, both sharing col_right (the 5d948ed rule: one shared right
       edge for the control column). */
    col_right = (short)(right - 6);

    if (drive_mode) {
        short dest_top;

        /* Drive's own pane furniture: just the destination row (2026-
           08-02's "Save into:" plus Choose..., moved off the toolbar
           strip and into the pane under the 5d948ed rule the other
           views' furniture already follows) and, while a pull is
           landing, the same moving-bar-plus-byte-line shape Photos'
           download furniture uses below. No Save button here (Up
           lives in the toolbar, up_btn above) and no Size popup (a
           drive pull always keeps the file's exact bytes - nothing to
           pick a size of), so the stack is two rows shorter than
           list/photos mode's. */
        set_empty(&r->save_btn, col_right, list_bottom);
        set_empty(&r->size_popup, col_right, list_bottom);

        dest_top = (short)(r->detail.bottom - 8 - row_h);
        set_rect(&r->dest_btn, (short)(col_right - 74), dest_top,
                 col_right, (short)(dest_top + row_h));
        set_rect(&r->dest_row, r->detail_text.left, dest_top,
                 (short)(r->dest_btn.left - gap), (short)(dest_top + row_h));
        set_rect(&r->dl_bar, r->detail_text.left,
                 (short)(dest_top - gap - 12), r->detail_text.right,
                 (short)(dest_top - gap));
        set_rect(&r->dl_text, r->detail_text.left,
                 (short)(r->dl_bar.top - 4 - 14), r->detail_text.right,
                 (short)(r->dl_bar.top - 4));
        /* The selected item's name/kind/size/date and the double-click
           affordance line draw above the whole stack - never under a
           live control, the rule every pane's furniture already
           keeps. */
        r->detail_text.bottom = (short)(r->dl_text.top - 6);
        set_empty(&r->photos_text, r->detail.right, r->detail.top);
        set_empty(&r->summary_row, r->detail.right, r->detail.top);
        set_empty(&r->tri, r->detail.right, r->detail.top);
        return;
    }

    /* The photos view's extra card-pane furniture, stacked bottom-up
       over Save. Only rectangles - the views that do not use them
       never read them - and photos_text is what keeps the preview and
       the card clear of the rows: pixels drawn under a live control is
       the one overlap nothing would ever repaint correctly.

       Tidied to one rule (metal feedback, 2026-08-02: "clean up the
       buttons"): every CONTROL - Choose..., the Size popup, Save - is
       flush to one shared right edge, every row is 20 points tall,
       every gap between rows is 6, and the labels centre on their
       row. A column of right-aligned actions is the Platinum shape. */
    {
        short save_top = (short)(r->detail.bottom - 8 - row_h);
        short bar_left;

        set_rect(&r->save_btn, (short)(col_right - 110), save_top,
                 col_right, (short)(save_top + row_h));

        /* The summary line sits directly above Save and never moves.
           Idle it reads "<folder>, <size>"; during a download the same
           strip carries the byte count and the bar, so nothing is given
           permanent height for a state that is usually not happening. */
        set_rect(&r->summary_row, r->detail_text.left,
                 (short)(save_top - 22), r->detail_text.right,
                 (short)(save_top - 6));
        set_rect(&r->tri, r->summary_row.left,
                 (short)(r->summary_row.top + 2),
                 (short)(r->summary_row.left + 12),
                 (short)(r->summary_row.top + 14));
        /* The bar takes the row's right end, but never so much that the
           byte count beside it has no room on a narrow pane. */
        bar_left = (short)(r->summary_row.right - 90);
        if (bar_left < (short)(r->summary_row.left + 60)) {
            bar_left = (short)(r->summary_row.left + 60);
        }
        set_rect(&r->dl_bar, bar_left, (short)(r->summary_row.top + 2),
                 r->summary_row.right, (short)(r->summary_row.top + 14));
        set_rect(&r->dl_text, r->summary_row.left, r->summary_row.top,
                 (short)(r->dl_bar.left - 6), r->summary_row.bottom);

        r->detail_text.bottom = (short)(r->save_btn.top - 6);
        r->photos_text = r->detail_text;
        if (photo_detail) {
            short size_top = (short)(r->summary_row.top - 26);
            short dest_top = (short)(size_top - 26);

            set_rect(&r->size_popup, (short)(col_right - 150), size_top,
                     col_right, (short)(size_top + row_h));
            set_rect(&r->dest_btn, (short)(col_right - 74), dest_top,
                     col_right, (short)(dest_top + row_h));
            set_rect(&r->dest_row, r->detail_text.left, dest_top,
                     (short)(r->dest_btn.left - 6),
                     (short)(dest_top + row_h));
            r->photos_text.bottom = (short)(dest_top - 6);
        } else {
            set_empty(&r->size_popup, col_right, r->summary_row.top);
            set_empty(&r->dest_btn, col_right, r->summary_row.top);
            set_empty(&r->dest_row, col_right, r->summary_row.top);
            r->photos_text.bottom = (short)(r->summary_row.top - 6);
        }
    }
}
