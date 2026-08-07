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
   through now_peek_windows_for_psn, and every control, menu and text
   read through src/axwalk/ by way of scene_walk.c - both of which
   validate each pointer inside the process's partition or the system
   heap before dereferencing it (docs/resident-components.md). This file
   holds foreign ADDRESSES, to hand one reader's window record back to
   the other; it never dereferences one, so it cannot weaken the
   boundary even by accident. */

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

/* Notes who is in front, for the cross-application layer ledger
   (front_order.h). ONE front sample — the processes family's, through
   `now_proc_roster_front` — and idempotent while nothing changes.

   Called from the main event loop rather than from now_scene_collect,
   and that is the whole point: layer order is a sequence of TRANSITIONS
   and no API hands one back, so it exists only for an application that
   was watching when it happened. Sampling it at collection time would
   see the machine as it is at that instant and miss every application
   that came forward and went back between two scenes - which, on a
   mirror the host is driving, is most of them.

   Costs a trap per pass. Deliberate: this loop already sleeps a tick to
   yield, and the alternative is a scene that reports a stacking order it
   guessed. */
void now_scene_note_front_process(void);

#endif /* NOW_SCENE_COLLECT_H */
