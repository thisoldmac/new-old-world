#ifndef NOW_CONTINUITY_OFFER_INTAKE_H
#define NOW_CONTINUITY_OFFER_INTAKE_H

#include "now_continuity_offer.h"

/* Reading continuity.offer off the wire.
   ------------------------------------------------------------------
   continuity.offer is unsolicited, pushed whenever what the host is
   carrying toward this Macintosh changes — continuity.selection
   inverted, same shape, other sender. This file's only job is folding
   each one into the table now_continuity_offer.h decides over; the
   decision itself is Toolbox-free and lives there, where the host cc
   watches it fail. The JSON parse here is the Toolbox-light half. */

/* Parse and fold in one continuity.offer control frame. */
void now_continuity_offer_intake(const char *request);

/* What this Mac currently holds. Never NULL. */
const NowContinuityOfferTable *now_continuity_offer_table(void);

/* Drop it: link gone. An offer is consent carried over ONE connection —
   the same rule the selection stub follows — so it cannot outlive the
   session that delivered it. */
void now_continuity_offer_forget(void);

#endif /* NOW_CONTINUITY_OFFER_INTAKE_H */
