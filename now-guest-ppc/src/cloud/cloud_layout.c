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
    /* Drive's navigation lives on its own row IMMEDIATELY above the
       listing, not up in the service toolbar: Back/Forward/Up, the
       breadcrumb beside them, and the search field at that row's right
       end (metal, 2026-08-02 - the cluster and the crumbs were two
       rows apart from the list they act on, and the search sat beside
       a popup it has nothing to do with). Every other mode keeps the
       search in the toolbar row, where it is the only thing there
       besides the popup and Refresh. */
    if (drive_mode) {
        short nav_top = (short)(top + 26);

        set_rect(&r->back_btn, left, nav_top, (short)(left + 30),
                 (short)(nav_top + 20));
        set_rect(&r->fwd_btn, (short)(r->back_btn.right + 2), nav_top,
                 (short)(r->back_btn.right + 32),
                 (short)(nav_top + 20));
        set_rect(&r->up_btn, (short)(r->fwd_btn.right + 4), nav_top,
                 (short)(r->fwd_btn.right + 48),
                 (short)(nav_top + 20));
        /* The search takes the row's right end; the breadcrumb fills
           whatever is left between Up and it, so a deep path shortens
           rather than colliding. */
        set_rect(&r->toolbar_search, (short)(right - 236), nav_top,
                 right, (short)(nav_top + 20));
        set_rect(&r->path_row, (short)(r->up_btn.right + 10),
                 (short)(nav_top + 2),
                 (short)(r->toolbar_search.left - 10),
                 (short)(nav_top + 18));
    } else {
        set_empty(&r->up_btn, r->refresh_btn.left, (short)(top + 1));
        set_empty(&r->fwd_btn, r->refresh_btn.left, (short)(top + 1));
        set_empty(&r->back_btn, r->refresh_btn.left, (short)(top + 1));
        set_rect(&r->toolbar_search, (short)(r->popup.right + 8), top,
                 (short)(r->refresh_btn.left - 8), (short)(top + 20));
    }

    /* Status is ABOVE the bottom edge, under both panes. */
    set_rect(&r->status, left, (short)(bottom - 14), right, bottom);
    list_bottom = (short)(r->status.top - 8);

    /* Where the split content area starts: directly under drive's
       navigation row (placed above, breadcrumb and search included),
       or at the usual offset under the toolbar in every other mode. */
    if (drive_mode) {
        list_top = (short)(r->back_btn.bottom + gap);
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
        set_empty(&r->size_label, col_right, list_bottom);

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
        set_empty(&r->save_group, r->detail.right, r->detail.top);
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
        /* The photos pane's save cluster: ONE titled group box holding
           the size, the destination and the button, always visible.
           It replaced a disclosure triangle whose closed state looked
           exactly like the stack it was meant to replace and whose
           open state broke on metal (2026-08-02) - a static cluster
           has no state to get wrong, and a person reads where and at
           what size without touching anything.

           The middle row does double duty: it carries the destination
           at rest and the download's bar and byte count while bytes
           land, so a transfer costs the photo no height. */
        short g_top = (short)(r->detail.bottom - 8 - 130);
        short inner_l = (short)(r->detail_text.left + 12);
        short inner_r = (short)(r->detail_text.right - 10);
        short row2 = (short)(g_top + 54);

        set_rect(&r->save_group, r->detail_text.left, g_top,
                 r->detail_text.right, (short)(r->detail.bottom - 8));
        /* The size row is the destination row's shape, one row up: a
           caption at the left inset, the control flush right. The
           caption gets its OWN rect because drawing it into the
           popup's rect overprinted the popup's own title on metal
           (2026-08-02) - a popup draws its value across the whole
           control, so anything else written there lands on top of it.
           The clamp keeps a legible caption on the narrowest honest
           pane rather than letting the popup eat the row. */
        {
            short popup_l = (short)(inner_r - 176);

            if (popup_l < (short)(inner_l + 40)) {
                popup_l = (short)(inner_l + 40);
            }
            set_rect(&r->size_popup, popup_l, (short)(g_top + 22),
                     inner_r, (short)(g_top + 42));
            set_rect(&r->size_label, inner_l, (short)(g_top + 22),
                     (short)(popup_l - gap), (short)(g_top + 42));
        }
        set_rect(&r->dest_btn, (short)(inner_r - 88), row2, inner_r,
                 (short)(row2 + row_h));
        set_rect(&r->dest_row, inner_l, row2,
                 (short)(r->dest_btn.left - 6), (short)(row2 + row_h));
        /* Same row as the destination, shown in its place: the count
           at the left, the bar filling what is left of the row. */
        set_rect(&r->dl_text, inner_l, row2, (short)(inner_l + 108),
                 (short)(row2 + 16));
        set_rect(&r->dl_bar, (short)(r->dl_text.right + 8),
                 (short)(row2 + 4), inner_r, (short)(row2 + 16));
        set_rect(&r->save_btn, (short)(inner_r - 116),
                 (short)(r->save_group.bottom - 30), inner_r,
                 (short)(r->save_group.bottom - 8));

        r->detail_text.bottom = (short)(r->save_group.top - 6);
        r->photos_text = r->detail_text;
    }
}
