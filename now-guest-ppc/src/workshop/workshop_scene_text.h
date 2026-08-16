#ifndef NOW_WORKSHOP_SCENE_TEXT_H
#define NOW_WORKSHOP_SCENE_TEXT_H

#include "workshop_scene.h"

/* Edit>Copy, served from the page's own describe_scene.

   A page that can say what it drew can already say it as text, so
   `copy_text` does not need a second walk over the same facts - it needs
   the first one pointed at a buffer instead of at the host. This is that
   buffer: a WorkshopSceneWriter whose `add` appends the static text it is
   handed.

   Runs that share a baseline are joined with two spaces rather than
   broken onto separate lines, because a label and its value are drawn as
   two runs on one line and copying them as two lines would be copying
   something nobody is looking at. Anything that is not static text -
   panels, bands, icons - contributes nothing: it has no words in it.

   The consequence worth stating: what lands on the clipboard is by
   construction what the page describes, which is by construction what
   the page drew. Three things that cannot drift because they are one
   walk. */

typedef struct WorkshopSceneText {
    char *out;
    long cap;
    long len;
    short last_top;      /* baseline grouping; see above */
    Boolean any;
} WorkshopSceneText;

/* Point `writer` at `sink`, which writes into out[0..cap-1]. */
void workshop_scene_text_begin(WorkshopSceneText *sink,
                               WorkshopSceneWriter *writer, char *out,
                               long cap);
/* Bytes written, not counting the terminator. 0 means the page produced
   no words, which the Workshop treats as "nothing to copy". */
long workshop_scene_text_end(WorkshopSceneText *sink);

#endif /* NOW_WORKSHOP_SCENE_TEXT_H */
