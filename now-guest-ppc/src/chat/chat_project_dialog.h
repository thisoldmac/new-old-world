#ifndef NOW_CHAT_PROJECT_DIALOG_H
#define NOW_CHAT_PROJECT_DIALOG_H

#include <Carbon.h>

/* The New Project editor. Fills `name` (C string, `name_cap` bytes) and
   `home` with the contract's word for where the project is
   authoritative - "guest" for this Mac, "host" for the other one - and
   returns true when the person committed a non-empty name. The modal
   loop pumps the wire (now_pump_modal_filter), the 301/302 rule. */
Boolean now_chat_project_new(char *name, long name_cap,
                             char *home, long home_cap);

#endif
