#ifndef NOW_UPDATE_ACTIVATION_H
#define NOW_UPDATE_ACTIVATION_H

#include <Carbon.h>

/* Reconcile the saved Extension exchange receipt with the table resident in
   this boot. Returns true while a restart is still required. */
Boolean now_update_activation_reconcile(void);

/* Record the exact 256-bit release identity after the Extension exchange. */
OSErr now_update_activation_record(const char *build);

#endif
