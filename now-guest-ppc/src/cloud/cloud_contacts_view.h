#ifndef NOW_CLOUD_CONTACTS_VIEW_H
#define NOW_CLOUD_CONTACTS_VIEW_H

#include "cloud_view.h"

/* Contacts' own card render. The list half is still the shell's
   generic Data Browser (kCloudColTitle/kCloudColSubtitle straight off
   CloudRow, alphabetical because the host's cloud.listing already is
   -- contract x-cloud, contacts); only the card pane is tailored here,
   into an address-book-style layout: labels right-aligned, values
   left, phone rows grouped, then email rows (cloud_contacts_card.h
   decides the grouping), any recognisable date rendered through
   LongDateString. Asking the wire (ask_rows/ask_card) and selection
   stay the shell's -- this view answers only "how does the card look",
   same division cloud_list_view.c already draws. */

const CloudViewOps *cloud_contacts_view_ops(void);

#endif /* NOW_CLOUD_CONTACTS_VIEW_H */
