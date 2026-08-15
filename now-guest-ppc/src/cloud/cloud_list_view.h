#ifndef NOW_CLOUD_LIST_VIEW_H
#define NOW_CLOUD_LIST_VIEW_H

#include "cloud_view.h"

/* The generic service render: a card for the selected row (cloud.card),
   or the service's own words when there is nothing to select from yet.
   Used today by Photos — any service that lists rows off cloud.listing
   and shows a plain label:value card off cloud.detail gets this view
   for free, no new file needed. Contacts has moved to its own tailored
   card (cloud_contacts_view.c); this is what a service falls back to
   without one. The rows themselves are the shell's Data Browser
   (kCloudColTitle/kCloudColSubtitle straight off CloudRow); this view
   only draws the detail pane. Asking the wire for rows and cards
   (ask_rows/ask_card/ask_save) stays in cloud_module.c — it already
   owns the Data Browser and the model those calls fill, so there is
   nothing left for this view's click/key/idle/reset_for_service to do;
   they are NULL, and the shell's own defaults are exactly this
   behaviour already. */

const CloudViewOps *cloud_list_view_ops(void);

/* The generic card render alone, for a view that adds to it rather
   than replaces it: the photos view draws THIS whenever it has no
   pixels to show, so the two card renders cannot drift. */
void cloud_list_view_draw_card(const CloudLayout *r,
                               const CloudStore *store,
                               const CloudService *service, int selected);

/* The same render's describing half, for a view (photos) that falls
   through to this card and wants the description to fall through with
   it — one walk, so the drawn card and the described card cannot
   drift from each other either. */
void cloud_list_view_describe_card(const WorkshopSceneWriter *writer,
                                   const CloudLayout *r,
                                   const CloudStore *store,
                                   const CloudService *service,
                                   int selected);

#endif /* NOW_CLOUD_LIST_VIEW_H */
