#ifndef NOW_UPDATE_ACTIVATION_H
#define NOW_UPDATE_ACTIVATION_H

#include <Carbon.h>
#include "prefs.h"

/* Reconcile the saved Extension exchange receipt with the table resident in
   this boot. Returns true while a restart is still required. */
Boolean now_update_activation_reconcile(NowPrefs *prefs);

/* Record the exact 256-bit release identity after the Extension exchange. */
OSErr now_update_activation_record(const char *build);

/* Remove a pre-install receipt when the file exchange does not complete. */
OSErr now_update_activation_clear(void);

#endif
