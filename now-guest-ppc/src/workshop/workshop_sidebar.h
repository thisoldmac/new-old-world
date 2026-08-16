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

/* The rail's own state, which the window needs before it can lay
   anything out. Safe to call before create: the statics behind it are
   the defaults until seeded, so the first compute_layout gets the same
   answer the rail will draw with. */
void workshop_sidebar_rail_spec(WorkshopRailSpec *out);

/* Seeded from prefs before the first layout: the saved arrangement and
   the collapsed state both reach the rectangles. */
void workshop_sidebar_load_prefs(void);

/* Collapsed to icons only - the rail's one remaining shape choice, since
   the rich density was retired and every expanded row is one line. It
   persists and relays out to the window, which must recompute the
   layout: the rail's whole width changes. */
Boolean workshop_sidebar_collapsed(void);
void workshop_sidebar_set_collapsed(Boolean collapsed);

/* The collapse button, drawn into the Workshop's header placard because
   it must sit in the same place in both states and a 48-pixel rail has
   no room for it. The window draws and routes it; the rail owns what it
   means. */
void workshop_sidebar_draw_toggle(void);
Boolean workshop_sidebar_toggle_click(Point local);

/* Hover help for a rail row, drawn by hand because Carbon's help tags do
   not display under Mac OS 9: the page's name when the rail is collapsed
   to icons, its description when the rail is expanded - the line the
   retired rich density used to carry. Cheap per pass. */
void workshop_sidebar_tag_idle(void);
/* Back to the curated default order (workshop_order.c). The escape hatch
   for a rail rearranged into confusion, and the only way back that does
   not require dragging every row. */
void workshop_sidebar_reset_order(void);

/* Told to the window when the rail's geometry changes under it: a
   density change or a reset both need the layout recomputed and the
   whole window repainted, which is the window's job, not the rail's. */
typedef void (*WorkshopSidebarRelayoutFn)(void);
void workshop_sidebar_set_relayout_fn(WorkshopSidebarRelayoutFn fn);

#endif /* NOW_WORKSHOP_SIDEBAR_H */
