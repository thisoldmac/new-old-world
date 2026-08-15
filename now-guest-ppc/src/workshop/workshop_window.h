#ifndef NOW_WORKSHOP_WINDOW_H
#define NOW_WORKSHOP_WINDOW_H

#include <Carbon.h>

#include "workshop_module.h"

/* The one primary window. It owns the WindowRef, the sidebar, the
   header and status placards, and module switching; main.c routes the
   usual document-window events here. */

Boolean workshop_open(void);
/* quitting distinguishes a user-initiated close (records the Workshop
   closed, so relaunch honors it) from app teardown (records it open,
   since the window still existed when the app quit); see prefs.h's
   workshop_open_at_quit. */
void workshop_close(Boolean quitting);
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
void workshop_describe_scene(const WorkshopSceneWriter *writer);

#endif /* NOW_WORKSHOP_WINDOW_H */
