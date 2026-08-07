/* Asking the machine what colour it draws with.
 *
 * The host renderer redraws windows this guest's Appearance Manager
 * erased, so it needs the same brushes. Before this file it carried them
 * as constants - one of them counted off a screendump - which is right
 * for the shipped Platinum theme and wrong, invisibly, for any other.
 *
 * Toolbox-dependent, so it is separated from scene_build.c/scene_json.c
 * on purpose: those two are the Toolbox-free halves the native tests
 * compile with the host `cc`, and this one cannot be.
 */
#ifndef NOW_SCENE_THEME_H
#define NOW_SCENE_THEME_H

#include "scene.h"

/* Fills `out` from the live Appearance Manager and low memory. Never
   fails as a whole: a brush the machine will not answer for leaves its
   field at -1, which the scene publishes as an ABSENT key rather than as
   a colour. `out` is fully initialised even when every ask fails. */
void now_scene_theme_ask(NowSceneTheme *out);

#endif /* NOW_SCENE_THEME_H */
