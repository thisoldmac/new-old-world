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
#include "obsmint.h"
#include "scene.h"

enum {
    /* A bound on one window's control chain. Reaching it means the list
       is longer than a scene carries or the chain is cyclic; either way
       the window's controls are retracted rather than reported short
       (scene.h, the retraction rule).

       DERIVED, NOT CHOSEN. A window cannot contribute more controls than
       the whole scene carries, so a separate per-window number is a
       second place for the limit to live - and this repository has
       already paid for a cap stated in three places with a different
       value in each. It was 48 against a pool of 96, which meant the
       per-window bound bit first and the pool's own headroom was
       unreachable: the Appearance control panel's 73-control chain was
       refused by the smaller of two numbers that nobody had compared.
       One number now, in scene.h, and this is a view of it. */
    kNowSceneWalkMaxControls = kNowSceneMaxControls,

    /* How far the DIAGNOSTIC count above the bound will hop. It records
       nothing and only follows pointers, so it is affordable at an order
       of magnitude above the carrying bound - and it is still a bound,
       because a cyclic chain would otherwise spin inside the event loop.
       A count that reaches it is reported as a floor, never a length. */
    kNowSceneWalkChainProbeMax = 512
};

/* Fills one already-admitted window row's `kind`, `controls`, `text` and
   `ref` from a bound seam. `address` is the window's WindowRecord, which
   peek_read.c reported beside the row.

   `refs` IS THE WALK'S MINTING SEAM, aimed at this process, and it may
   be NULL - which is how a caller with no reference layer produces a
   scene with every `ref` absent instead of one with invented ones. THIS
   walk mints, rather than a later pass consulting a registry, and the
   reason is that this is the only moment the addresses exist: a control
   is a ControlHandle on a chain in another process's heap, and nothing
   downstream of here holds one. A pass that re-derived them would be a
   second walk deciding what an element is, which is the defect the
   reference layer was unified to remove.

   Minting HERE is affordable because the seam interns (obsmint.h): a
   second fetch of an unchanged window hands back the same references and
   the registry does not grow, so a person pressing refresh does not
   invalidate the scene they are looking at.

   Silent on failure BY DESIGN: a window record that does not validate
   leaves every sub-plane absent, so the row keeps exactly the claims
   peek_read.c already established for it and gains none. An element the
   seam declines to name keeps its other claims and loses only `ref`. */
void now_scene_walk_window(NowScene *s, int window,
                           const NowAxMemory *memory, unsigned long address,
                           NowObsWalk *refs);

/* Fills the menu-bar plane from `menu_list`, attributing it to process
   row `proc` - which must be the FRONT process, because classic Mac OS
   draws one menu bar and it is the front application's.

   A null `menu_list` is an empty ANSWER, not a failure: the plane opens
   and carries zero menus, which is what a faceless background process
   has. A list that fails to parse retracts the whole plane instead. */
void now_scene_walk_menubar(NowScene *s, int proc,
                            const NowAxMemory *memory,
                            unsigned long menu_list);

/* Mac OS 9 may expose the front Carbon application's Apple menu as an exact
   shell whose rows have indices and enablement but blank text. A validated
   classic process menu can still carry the system-owned Apple Menu Items
   rows, identified by the two-NUL prefix measured in axmenu.c. Fill only an
   already-present, wholly blank Apple shell with an equal-sized suffix of
   those guest rows. The current menu keeps its own ID, geometry and
   MenuSelect indices; no host label or application-specific prefix is
   synthesized. Returns nonzero only when a fill occurred. */
int now_scene_fill_blank_system_apple(NowScene *s,
                                      const NowAxMemory *memory,
                                      unsigned long menu_list);

#endif /* NOW_SCENE_WALK_H */
