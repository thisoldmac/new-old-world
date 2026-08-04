#ifndef NOW_SCENE_SELF_H
#define NOW_SCENE_SELF_H

#include <Processes.h>
#include <Menus.h>

#include "obsmint.h"
#include "scene.h"

/* This application's OWN windows and controls, asked of the Toolbox
   rather than walked out of memory. See scene_self.c for why that is a
   different kind of read and not an exception to the passive rule. */
void now_scene_collect_self(NowScene *s, int row,
                            const ProcessSerialNumber *psn,
                            NowObsWalk *refs);

/* Resolve one item through Carbon's root-menu attachment. On Mac OS 9 the
   live Apple MenuList entry can be a blank shell while the real system rows
   live in an attached submenu with the same ID. Returns false for a non-Apple
   menu, an absent row, or a blank title. */
Boolean now_scene_copy_apple_menu_item(MenuID menu_id, MenuItemIndex item,
                                       Str255 text);

#endif
