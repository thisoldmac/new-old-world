#ifndef NOW_WEB_PORT_DIALOG_H
#define NOW_WEB_PORT_DIALOG_H

#include <Carbon.h>

/* Dialog Manager owns the editable field. The Workshop window deliberately
   does not host editText controls because they do not receive text in this
   WaitNextEvent application. The modal filter pumps NOW's wire. */
Boolean now_web_edit_port(unsigned short *port);

#endif /* NOW_WEB_PORT_DIALOG_H */
