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
                                          popup — hand-drawn, not a
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
                                          between the toolbar and the
                                          list ("iCloud Drive:Attic");
                                          empty outside drive mode */
    /* Drive mode's own destination row, beneath path_row: reuses the
       same two fields the photos furniture below defines (dest_row,
       dest_btn) rather than adding a second pair with the same shape —
       the two modes never draw at once, so one set of rects serves
       both. Empty outside drive mode, like path_row. */
    Rect list;                        /* the Data Browser: full body
                                          width in drive mode, left half
                                          otherwise */
    Rect detail;                      /* the card pane beside it; empty
                                          in drive mode — there is no
                                          card, the list owns the row */
    Rect detail_text;                 /* where card rows draw, inset;
                                          empty in drive mode */
    Rect save_btn;                    /* bottom of the detail pane;
                                          empty in drive mode (Up moves
                                          to up_btn, in the toolbar) */
    Rect status;                      /* one line under both panes */

    /* The photos view's extra card-pane furniture. Computed whenever
       the card pane exists (they are only rectangles; the other views
       ignore them) and empty in drive mode like everything else the
       card owns EXCEPT dest_row/dest_btn, which drive mode fills with
       its OWN destination row instead (see path_row above) — the two
       modes never draw at once, so reusing the pair costs nothing and
       avoids a second rect pair with the identical shape. Stacked
       bottom-up above save_btn in list/photos mode: the destination
       row, then the download bar, then its byte-count line. */
    Rect size_popup;                  /* Size dropdown, left of Save;
                                          empty in drive mode */
    Rect dest_row;                    /* "Save into:" path label — the
                                          card pane's row in list/photos
                                          mode, the row under path_row
                                          in drive mode */
    Rect dest_btn;                    /* Choose... beside it, same
                                          dual role */
    Rect dl_bar;                      /* the moving bar (shown only
                                          while a download lands) */
    Rect dl_text;                     /* its byte count, above it */
    Rect photos_text;                 /* detail_text minus the rows
                                          above — where photos' card,
                                          preview and loading line draw
                                          so pixels never sit under
                                          controls */
} CloudLayout;

/* drive_mode picks which of the two layouts above cloud_draw's and
   cloud_click's rectangles actually are; both modes fill every field
   so a caller never needs to know which one ran. */
void cloud_layout_compute(const Rect *body, Boolean drive_mode,
                          CloudLayout *r);

#endif /* NOW_CLOUD_LAYOUT_H */
