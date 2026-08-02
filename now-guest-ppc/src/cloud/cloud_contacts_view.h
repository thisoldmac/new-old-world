#ifndef NOW_CLOUD_CONTACTS_VIEW_H
#define NOW_CLOUD_CONTACTS_VIEW_H

#include "cloud_view.h"

/* Contacts: a real address-book page. This view owns TWO things beyond
   the card render its header used to describe alone:

   The LIST is this view's own Data Browser, with real columns -- Name
   and Company, not the shell's generic Item/Detail -- built the way
   cloud_drive_view.c's own browser is: its own control, its own UPPs,
   the fill-hilite call, disposed before them at window close. Unlike
   Drive, this view keeps no row storage of its own: the rows ARE the
   shell's CloudStore (cloud.listing, alphabetical because the host's
   answer already is -- contract x-cloud, contacts), read straight off
   the pointer cloud_contacts_view_bind() is given once. Asking the
   wire for the list (ask_rows), batching arrivals and the live
   search's diff all stay the SHELL's -- cloud_module.c's
   active_browser() already treats "whichever browser the mode owns" as
   one seam, and this view is simply a second thing that seam can
   point at. Only "what happens when a row is picked" needed a hook
   back into the shell (CloudContactsHost.row_selected), because that
   is where g_selected and ask_card() already live.

   The CARD is the classic Address Book's own shape: a photo well
   top-left (cloud_contacts_card.h's pure layout), the name beside it
   in the large system font, then the grouped [label, value] rows —
   phones, emails, everything else — below both, any recognisable date
   rendered through LongDateString. The well's pixels are the SAME
   preview-well machinery Photos uses (cloud_preview_well.c, extracted
   from cloud_photos_view.c 2026-08-02 for exactly this): one decoded
   bitmap in memory, shared by whichever view is asking, evicted on
   every selection change; while it is loading or the ask is refused
   (a contact with no photo is not a failure -- x-cloud, contacts)
   this view draws its own hand-drawn person-silhouette placeholder in
   the well, guest-side, rather than showing nothing. */

const CloudViewOps *cloud_contacts_view_ops(void);

typedef struct CloudContactsHost {
    /* A row on THIS view's own browser was selected/deselected (-1).
       The shell's existing g_selected/ask_card()/CloudViewOps.select
       plumbing runs off this -- the same three steps its own shared
       browser's notification already performs for every other
       service, because this view owns a second CONTROL, not a second
       selection model. */
    void (*row_selected)(int index);

    /* True while the shell is mutating a browser's items on its own
       behalf (a rebuild, a listing settling, a search's diff) --
       RemoveDataBrowserItems fires deselect notifications nobody
       asked for, and those must not re-trigger ask_card(). The
       shell's own browser already guards this with a static flag;
       this view has no way to see it without asking. */
    Boolean (*in_rebuild)(void);
} CloudContactsHost;

/* One-time wiring, called from cloud_create() the way cloud_drive_
   view_bind is (before this view's own create() runs, so create()
   never has to assume it has already happened). `store`'s ADDRESS is
   stable for the run (it is the shell's static CloudStore); this view
   re-reads its CONTENTS on every item_data/item_notify/draw call and
   caches nothing about a row. */
void cloud_contacts_view_bind(const CloudContactsHost *host,
                              const CloudStore *store);

/* Window close / quit: disposes this view's browser BEFORE its UPPs
   (carbon-upp-is-not-a-cast-on-cfm; files_browser_view.c's order is
   the pattern), and stops asking the preview well for anything. */
void cloud_contacts_view_dispose(void);

/* This view's own Data Browser (NULL when creation failed): Name and
   Company columns, shown only while contacts is the active service.
   The shell mutates it exactly as it mutates its own shared control --
   add/remove/clear already read "whichever browser is active"
   (cloud_module.c's active_browser()), so returning this here is the
   only change that function needs to know about a third mode. */
ControlRef cloud_contacts_view_browser(void);

#endif /* NOW_CLOUD_CONTACTS_VIEW_H */
