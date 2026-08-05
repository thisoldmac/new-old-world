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

/* The rail's own state, which the window needs before it can lay
   anything out. Safe to call before create: the statics behind it are
   the defaults until seeded, so the first compute_layout gets the same
   answer the rail will draw with. */
void workshop_sidebar_rail_spec(WorkshopRailSpec *out);

/* Seeded from prefs before the first layout, because density decides row
   height and therefore every rectangle in the rail. */
void workshop_sidebar_load_prefs(void);

/* The Preferences page's two levers. Both persist and relay out to the
   window, which must recompute the layout - a density change moves every
   row. */
Boolean workshop_sidebar_compact(void);
void workshop_sidebar_set_compact(Boolean compact);
/* Back to the order the enum declares. The escape hatch for a rail
   rearranged into confusion, and the only way back that does not require
   dragging every row. */
void workshop_sidebar_reset_order(void);

/* Told to the window when the rail's geometry changes under it: a
   density change or a reset both need the layout recomputed and the
   whole window repainted, which is the window's job, not the rail's. */
typedef void (*WorkshopSidebarRelayoutFn)(void);
void workshop_sidebar_set_relayout_fn(WorkshopSidebarRelayoutFn fn);

#endif /* NOW_WORKSHOP_SIDEBAR_H */
