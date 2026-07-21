#ifndef NOW_CONN_EDIT_DIALOG_H
#define NOW_CONN_EDIT_DIALOG_H

#include <Carbon.h>

/* Editing the other Mac's address and port.
   ------------------------------------------------------------------
   A movable-modal DIALOG, driven by the Dialog Manager - NOT an
   edit-text control on the Connection page. The Appearance edit-text
   control takes neither clicks nor keystrokes in this WaitNextEvent
   app (the Console hit the same wall and hand-rolled its input); the
   Dialog Manager's own edit-text items DO work, and are the path the
   original Connection dialog used on the PowerBook before the Workshop
   rewrite. So the page shows the target read-only, and this dialog is
   how it changes.

   ModalDialog runs a nested loop; the filter (pump.h) keeps the wire
   serviced while it is open, so a long edit never drops the link.

   Seeds from *host / *port; on Save, validates with conn_fields.c,
   writes the new values back through the same pointers, and returns
   true. Returns false on Cancel or if the dialog cannot be built,
   leaving the values untouched. */
Boolean now_conn_edit(char *host, long host_cap, unsigned short *port);

#endif /* NOW_CONN_EDIT_DIALOG_H */
