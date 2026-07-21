#ifndef NOW_CONSOLE_WIN_H
#define NOW_CONSOLE_WIN_H

#include <Carbon.h>

/* The guest's own console: a single window that runs the SAME command table
   as the wire (commands.c), locally. Typing "gestalt" here reports this
   machine's own Gestalt — one implementation, two invocation paths. It is
   also the guest's first real log view. */

void console_win_open(void);          /* create, or bring to front */
void console_win_close(void);
Boolean console_win_is(WindowRef window);
WindowRef console_win_ref(void);
void console_win_draw(void);
void console_win_invalidate(void);    /* repaint after a resize/zoom */
void console_win_activate(Boolean becoming_active);
void console_win_key(char ch);        /* printable / return / backspace */

#endif
