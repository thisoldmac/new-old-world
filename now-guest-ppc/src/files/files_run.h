#ifndef NOW_FILES_RUN_H
#define NOW_FILES_RUN_H

#include <Carbon.h>

#include "workshop_scene.h"

/* One run of text on the Files page, drawn or described.

   A NULL writer draws it - at the baseline files_layout.c states, in the
   font asked for, truncated to the rect it was given. A writer reports
   the rect the run occupies and the whole line, untruncated: the host is
   being told what the page SAYS, and a middle-truncated path is a fact
   about a narrow window rather than about the folder.

   Both halves of this page reach every one of their words through here,
   so a run cannot be drawn in one place and described from another. */

void files_run(const WorkshopSceneWriter *writer, const Rect *where,
               Boolean right_align, Boolean emphasized, short trunc,
               const char *line);

#endif /* NOW_FILES_RUN_H */
