#ifndef NOW_CLOUD_LIST_VIEW_H
#define NOW_CLOUD_LIST_VIEW_H

#include "cloud_view.h"

/* The generic service render: a card for the selected row (cloud.card),
   or the service's own words when there is nothing to select from yet.
   Used today by Photos and Contacts — any service that lists rows off
   cloud.listing and shows a card off cloud.detail gets this view for
   free, no new file needed. The rows themselves are the shell's Data
   Browser (kCloudColTitle/kCloudColSubtitle straight off CloudRow); this
   view only draws the detail pane. Asking the wire for rows and cards
   (ask_rows/ask_card/ask_save) stays in cloud_module.c — it already
   owns the Data Browser and the model those calls fill, so there is
   nothing left for this view's click/key/idle/reset_for_service to do;
   they are NULL, and the shell's own defaults are exactly this
   behaviour already. */

const CloudViewOps *cloud_list_view_ops(void);

#endif /* NOW_CLOUD_LIST_VIEW_H */
