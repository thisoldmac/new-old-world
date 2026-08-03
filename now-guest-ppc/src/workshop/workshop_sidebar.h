#ifndef NOW_WORKSHOP_SIDEBAR_H
#define NOW_WORKSHOP_SIDEBAR_H

#include <Carbon.h>

#include "workshop_layout.h"
#include "workshop_module.h"

/* The persistent rail: the module list, the pinned Connection row, and
   the connection glance state under it. Selection changes are reported
   through the callback; the sidebar never switches modules itself. */

typedef void (*WorkshopSidebarSelectFn)(WorkshopModuleID module);

Boolean workshop_sidebar_create(WindowRef owner, const WorkshopLayout *lay,
                                WorkshopSidebarSelectFn on_select);
/* After DisposeWindow, never before: the lists may still call back
   through the UPPs until the window takes the controls with it. */
void workshop_sidebar_dispose(void);

void workshop_sidebar_layout(const WorkshopLayout *lay);
void workshop_sidebar_draw(void);
Boolean workshop_sidebar_click(const EventRecord *event, Point local);
Boolean workshop_sidebar_key(const EventRecord *event);
void workshop_sidebar_activate(Boolean active);
void workshop_sidebar_idle(void);
void workshop_sidebar_set_selection(WorkshopModuleID module);
void workshop_sidebar_describe_scene(const WorkshopSceneWriter *writer);

#endif /* NOW_WORKSHOP_SIDEBAR_H */
