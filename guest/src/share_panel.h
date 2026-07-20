#ifndef NOW_SHARE_PANEL_H
#define NOW_SHARE_PANEL_H

#include <Carbon.h>

/* File Sharing is a modeless panel, not a dialog: the human opens it
   deliberately, may want to look at the Finder while deciding, and Mac
   OS speech reads modal dialogs aloud. It matches the Screenshots and
   Console windows rather than interrupting like an alert. */

void share_panel_open(void);
void share_panel_close(void);
Boolean share_panel_is(WindowRef window);
WindowRef share_panel_ref(void);
void share_panel_draw(void);
void share_panel_click(Point local);

#endif /* NOW_SHARE_PANEL_H */
