#ifndef NOW_CLOUD_LAYOUT_H
#define NOW_CLOUD_LAYOUT_H

/* The iCloud page's geometry, pure so the host cc can test it: click
   and draw read the same rectangles and cannot disagree. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect { short top, left, bottom, right; } Rect;
typedef unsigned char Boolean;
#endif

typedef struct {
    Rect popup;                       /* the service dropdown */
    Rect toolbar_search;              /* the live filter, beside the
                                          popup - hand-drawn, not a
                                          control (the WaitNextEvent app
                                          cannot host an inline edit-text
                                          control; software_module.c's
                                          reason, unchanged here) */
    Rect refresh_btn;
    Rect back_btn;                    /* drive mode only: the history
                                          pair, left of Up; empty (zero
                                          area) outside drive mode */
    Rect fwd_btn;
    Rect up_btn;                      /* drive mode only: in the toolbar
                                          row, beside refresh; empty
                                          (zero area) outside drive mode */
    Rect path_row;                    /* drive mode only: breadcrumbs
                                          above the list/detail split
                                          ("iCloud Drive:Attic"); empty
                                          outside drive mode */
    Rect list;                        /* the Data Browser: left share of
                                          the split - the SAME geometry
                                          every mode uses, drive included
                                          (cloud_layout.c reuses the one
                                          split rather than inventing a
                                          second layout for drive) */
    Rect detail;                      /* the pane beside it: the card in
                                          list/photos/contacts mode, the
                                          SELECTED drive item's name/
                                          kind/size/date plus the
                                          double-click affordance line
                                          in drive mode. Real in every
                                          mode now - drive stopped being
                                          a card-less full-width list. */
    Rect detail_text;                 /* where the pane's text draws,
                                          inset, and trimmed to stop
                                          above whatever furniture rows
                                          (below) that mode fills in
                                          underneath it */
    Rect save_btn;                    /* bottom of the pane in list mode;
                                          empty in drive mode (Up moves
                                          to up_btn, in the toolbar -
                                          drive has no Save button, only
                                          its own destination row) */
    Rect status;                      /* one line under both panes */

    /* The pane's own download furniture, below its text. Computed
       whenever the pane exists - rectangles only; a mode that draws no
       controls into them never reads them. List/photos/contacts mode
       stacks bottom-up over save_btn: the Size popup, the destination
       row, the download bar, then its byte-count line. Drive mode has
       no Save and no Size popup (a pull always keeps the file's exact
       bytes - nothing to pick a size of), so its stack is two rows
       shorter: just the destination row, then the bar and byte line
       while a pull is landing - the same shape, reused, not reinvented
       (cloud_drive_view.c). */
    Rect size_popup;                  /* Size dropdown, left of Save;
                                          empty in drive mode (nothing to
                                          pick a size of) */
    Rect dest_row;                    /* "Save into:" path label, in the
                                          pane in every mode now (moved
                                          off drive's old toolbar strip,
                                          under the 5d948ed rule the
                                          other views' furniture already
                                          follows) */
    Rect dest_btn;                    /* Choose... beside it */
    Rect dl_bar;                      /* the moving bar (shown only
                                          while a download lands) */
    Rect dl_text;                     /* its byte count, above it */
    Rect summary_row;                 /* photos, always: the one line
                                          that states WHERE and AT WHAT
                                          SIZE the next save lands, so
                                          both facts are readable without
                                          clicking anything. Doubles as
                                          the download read-out's row -
                                          the bar and byte count draw
                                          here rather than claiming
                                          permanent height of their own */
    Rect tri;                         /* the disclosure triangle at the
                                          summary's left: closed is the
                                          summary alone, open adds the
                                          destination and size controls.
                                          Empty in every non-photos mode */
    Rect photos_text;                 /* detail_text minus the rows
                                          above, for PHOTOS specifically
                                          - where its card, preview and
                                          loading line draw so pixels
                                          never sit under controls;
                                          empty in drive mode, which
                                          reads detail_text directly
                                          (already trimmed above drive's
                                          own, shorter furniture stack) */
} CloudLayout;

/* drive_mode picks which of the two layouts above cloud_draw's and
   cloud_click's rectangles actually are; both modes fill every field
   so a caller never needs to know which one ran. Drive mode no longer
   means "full width, no pane": it is the same list/detail split every
   other mode uses, with its own list_top (the breadcrumbs above it)
   and its own, shorter furniture stack in the pane. */
/* photo_detail opens the photos pane's disclosed rows (destination and
   size controls). Closed, those three rects are the anti-rect and the
   summary line carries both facts in 42 points instead of 94 - the
   photo gets the difference. Ignored outside photos/list mode. */
void cloud_layout_compute(const Rect *body, Boolean drive_mode,
                          Boolean photo_detail,
                          CloudLayout *r);

#endif /* NOW_CLOUD_LAYOUT_H */
