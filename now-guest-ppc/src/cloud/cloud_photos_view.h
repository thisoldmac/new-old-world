#ifndef NOW_CLOUD_PHOTOS_VIEW_H
#define NOW_CLOUD_PHOTOS_VIEW_H

#include "cloud_view.h"

/* Photos: the generic listing+card render, plus a preview of the
   selected photo replacing the card — list and preview-on-select, no
   thumbnail grid (deferred indefinitely; docs/icloud.md says why).
   Selecting a row asks cloud.preview with the pane's dimensions and
   the screen's actual depth; the host decodes, resizes and dithers,
   and this view CopyBits the arrived rows from its one offscreen
   GWorld. Exactly one preview lives in memory at a time, evicted on
   every selection change — the 6 MB partition holds a photo, not a
   library. */

const CloudViewOps *cloud_photos_view_ops(void);

/* This view owns its own Data Browser (Name/Size/Modified — the drive
   view's view-owned-browser recipe, docs/icloud.md), because the
   shell's shared two-column browser cannot wear this column set any
   more than it can Drive's (RemoveDataBrowserTableViewColumn is not
   among the 22 symbols proven exported on the PB1400c;
   cloud_drive_view.h says why in full). Unlike Drive, this view's
   rows ARE the shell's shared CloudStore — Save, the card and the
   live search all already read store->rows[selected] — so this
   browser needs the shell's own store pointer and its own selection
   notification, both handed over once at bind time rather than
   duplicated here. */
typedef struct CloudPhotosHost {
    const CloudStore *store;          /* the shell's shared listing;
                                          address is stable — g_store is
                                          a file-static in cloud_module.c
                                          that outlives the page. */
    DataBrowserItemNotificationUPP notify_upp;
                                       /* the shell's own selected/
                                          deselected handling, reused
                                          verbatim: this browser's item
                                          ids index the SAME store rows
                                          the shell's two-column browser
                                          already did, so the shell's
                                          existing notification is
                                          correct unchanged. Built and
                                          disposed by cloud_module.c —
                                          this view only attaches it. */
    void (*relayout)(void);            /* the disclosure triangle
                                          changes which rows exist, so
                                          the shell recomputes the
                                          layout and re-places every
                                          control - this view owns the
                                          state, the shell owns the
                                          geometry. */
} CloudPhotosHost;

/* One-time wiring, called from cloud_create() BEFORE this view's own
   create op (which needs notify_upp already built to attach it to its
   Data Browser). */
void cloud_photos_view_bind(const CloudPhotosHost *host);

/* Whether the pane's destination and size rows are disclosed. The
   shell asks on every layout: those rows exist only when this says so,
   and only for photos. False before the view is created, and forced
   false while a download runs. */
Boolean cloud_photos_view_disclosed(void);

/* This view's own Data Browser (NULL when creation failed, or before
   create() runs): the control the shell shows, sizes and routes
   clicks/keys to while photos is the active service. */
ControlRef cloud_photos_view_browser(void);

/* Owned by this view but called by the shell, the drive view's
   pattern: the window (and every control in it) outlives nothing, so
   dispose only drops this view's own offscreen world, hook and
   browser (before its own item-data UPP — files_browser_view.c's
   dispose order and carbon-upp-is-not-a-cast-on-cfm, same as Drive's;
   the shared notify_upp is NOT disposed here, since this view does
   not own it). */
void cloud_photos_view_dispose(void);

#endif /* NOW_CLOUD_PHOTOS_VIEW_H */
