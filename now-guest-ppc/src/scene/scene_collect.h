#ifndef NOW_SCENE_COLLECT_H
#define NOW_SCENE_COLLECT_H

/* The impure half of the scene: ask the Process Manager who is running,
   ask the validated reader what each one's windows are, ask the machine
   how big its screen is - then hand all of it to the Toolbox-free
   assembly in scene.h.

   The split is deliberate and is the same one peek_read.c / peek_oracle.c
   already draw: everything that can be decided from arguments is decided
   where a native test can reach it, and this file holds only the part
   that needs a Macintosh. Nothing here interprets a verdict or decides
   what a scene claims; it collects and delegates.

   Foreign memory is never touched here either. Every window read goes
   through now_peek_windows_for_psn, which validates each pointer inside
   the process's partition or the system heap before dereferencing it
   (docs/resident-components.md). This file cannot weaken that even by
   accident, because it never holds a foreign pointer. */

#include <Carbon.h>

#include "scene.h"

/* Fills `out` with a scene of the machine as it is right now.

   `seq` is the caller's monotonically increasing counter (IR v1 carries
   it so a consumer can tell two scenes apart when their clocks agree).
   `stale_after_ticks` is the age gate handed to assembly: nonzero marks
   an old-but-clean anchor stale beside its data, 0 disables it.

   Always produces a scene. A machine with no readable anchors yields a
   scene of processes whose rows say why, which is the honest answer and
   not an error - "no windows visible from here" is a fact worth
   carrying. */
void now_scene_collect(NowScene *out, long seq,
                       unsigned long stale_after_ticks);

#endif /* NOW_SCENE_COLLECT_H */
