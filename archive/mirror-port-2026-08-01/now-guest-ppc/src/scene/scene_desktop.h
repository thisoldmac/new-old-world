#ifndef NOW_SCENE_DESKTOP_H
#define NOW_SCENE_DESKTOP_H

/* The desktop plane's impure half: the Desktop Folder walk and the
   volumes walk, both ordinary File Manager calls rather than a
   foreign-memory read - so unlike scene_collect.c's process walk, there
   is no anchor, no partition, and no verdict here. scene_build.c and
   scene_json.c carry every rule that IS testable without a Macintosh
   (kept Toolbox-free for exactly that reason); this file is the one
   Toolbox-dependent caller of them, the same relationship
   scene_collect.c has to the rest of the scene. */

#include "scene.h"

/* Walks the Desktop Folder (FindFolder kDesktopFolderType) and the
   mounted volumes (indexed PBHGetVInfo), appending every visible item to
   `s`. Either walk can fail or find nothing without affecting the other:
   a Desktop Folder that will not resolve still leaves the volumes walk
   free to run, and vice versa. `s->desktop_items_present` ends up true
   the moment either one actually ran (now_scene_open_desktop_items),
   false only when neither could start at all. */
void now_scene_collect_desktop(NowScene *s);

#endif /* NOW_SCENE_DESKTOP_H */
