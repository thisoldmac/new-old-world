#ifndef NOW_TRASH_MOVE_H
#define NOW_TRASH_MOVE_H

#include <Carbon.h>

/* Moves `spec` into `to_dir` (normally a volume's Trash) WITHOUT renaming
   it. A currently-running application cannot have its catalog name
   changed while it runs -- FSpRename on a live APPL's own spec is the
   operation that returns fBsyErr on systems where Finder replacement
   still succeeds -- so this never attempts that rename, unlike a plain
   PBCatMove-after-FSpRename sequence.

   If `to_dir` already holds an item under spec's current name, that
   OTHER item is displaced first (renamed to a free name inside `to_dir`)
   so spec can land under its own, unchanged name. On success spec's
   name is untouched and spec->parID becomes `to_dir`. On failure spec is
   left exactly as it was and any displaced collision is restored under
   its original name before returning; the OSErr that failed is
   returned (fnfErr, or whatever PBCatMoveSync/FSpRename reported). */
OSErr now_trash_move_busy(FSSpec *spec, long to_dir);

#endif
