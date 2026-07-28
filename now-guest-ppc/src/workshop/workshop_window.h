#ifndef NOW_WORKSHOP_WINDOW_H
#define NOW_WORKSHOP_WINDOW_H

#include <Carbon.h>

#include "workshop_module.h"

/* The one primary window. It owns the WindowRef, the sidebar, the
   header and status placards, and module switching; main.c routes the
   usual document-window events here. */

Boolean workshop_open(void);
void workshop_close(void);
Boolean workshop_is(WindowRef window);
WindowRef workshop_ref(void);

void workshop_draw(void);
void workshop_click(const EventRecord *event);
Boolean workshop_key(const EventRecord *event);
void workshop_activate(Boolean active);
void workshop_idle(void);
/* Recompute the layout after a grow or zoom. */
void workshop_resized(void);

void workshop_select_module(WorkshopModuleID module);

#endif /* NOW_WORKSHOP_WINDOW_H */
