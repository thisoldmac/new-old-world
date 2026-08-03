#ifndef NOW_SCENE_SELF_H
#define NOW_SCENE_SELF_H

#include "scene.h"

/* This application's OWN windows and controls, asked of the Toolbox
   rather than walked out of memory. See scene_self.c for why that is a
   different kind of read and not an exception to the passive rule. */
void now_scene_collect_self(NowScene *s, int row);

#endif
