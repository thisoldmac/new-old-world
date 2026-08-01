#ifndef NOW_SCENE_WALK_H
#define NOW_SCENE_WALK_H

/* The bridge between the ported foreign-memory walk (src/axwalk/) and
   the scene's assembly rules (scene.h).

   TOOLBOX-FREE, WHICH IS THE WHOLE REASON IT IS ITS OWN FILE. Everything
   below takes a bound `NowAxMemory` seam as an argument and never asks
   the machine for anything, so the wiring that decides WHAT A SCENE
   CLAIMS about another process's controls and menus is reachable from a
   native host test (tests/scene_walk_test.c) driving the same synthetic
   big-endian arena the axwalk tests use. The impure half - resolve a
   PSN, bind a partition - is one call in scene_collect.c, and that call
   is the only part of this plane a Macintosh is needed to exercise.

   It is the same split scene_build.c / scene_collect.c and
   peek_oracle.c / peek_read.c already draw, applied to the piece the
   roadmap called "the ported walk has no caller".

   NOTHING HERE WIDENS THE BOUNDARY. Every read goes through axwalk,
   which validates every range through now_peek_range_in_partition()
   before dereferencing it. This file holds foreign ADDRESSES and passes
   them to a validating reader; it never dereferences one itself, and it
   must not learn how. */

/* axwalk.h, NOT axprocess.h: the latter includes <Carbon.h> for a
   ProcessSerialNumber, which is exactly what would put this header - and
   its test - back on a Macintosh. The seam arrives already bound. */
#include "axwalk.h"
#include "scene.h"

enum {
    /* A bound on one window's control chain. Reaching it means the list
       is longer than a scene carries or the chain is cyclic; either way
       the window's controls are retracted rather than reported short
       (scene.h, the retraction rule). */
    kNowSceneWalkMaxControls = 48
};

/* Fills one already-admitted window row's `kind`, `controls` and `text`
   from a bound seam. `address` is the window's WindowRecord, which
   peek_read.c reported beside the row.

   Silent on failure BY DESIGN: a window record that does not validate
   leaves every sub-plane absent, so the row keeps exactly the claims
   peek_read.c already established for it and gains none. */
void now_scene_walk_window(NowScene *s, int window,
                           const NowAxMemory *memory, unsigned long address);

/* Fills the menu-bar plane from `menu_list`, attributing it to process
   row `proc` - which must be the FRONT process, because classic Mac OS
   draws one menu bar and it is the front application's.

   A null `menu_list` is an empty ANSWER, not a failure: the plane opens
   and carries zero menus, which is what a faceless background process
   has. A list that fails to parse retracts the whole plane instead. */
void now_scene_walk_menubar(NowScene *s, int proc,
                            const NowAxMemory *memory,
                            unsigned long menu_list);

#endif /* NOW_SCENE_WALK_H */
