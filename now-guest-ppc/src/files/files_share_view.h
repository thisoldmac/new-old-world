#ifndef NOW_FILES_SHARE_VIEW_H
#define NOW_FILES_SHARE_VIEW_H

#include <Carbon.h>

#include "files_layout.h"
#include "workshop_scene.h"

/* "My Shared Folder": the lower half of the Files page. What this Mac
   offers the other one, where files it sends here land, and the two
   verbs - Send File, Open Folder - that were previously hidden under a
   disclosure triangle labelled as if it covered only the setting.

   Paths, offers and transfer state stay owned by fileshare.c and the
   wire; this file owns controls, drawing, and nothing else.

   It takes the whole layout rather than an area: the page's geometry is
   decided once, in files_layout.c, where a host cc can check it. */

Boolean files_share_create(WindowRef owner, const FilesLayoutRects *r);
void files_share_dispose(void);

void files_share_layout(const FilesLayoutRects *r);
void files_share_show(Boolean visible);
void files_share_draw(void);
Boolean files_share_click(const EventRecord *event, Point local);
void files_share_activate(Boolean active);
void files_share_idle(void);

/* This half's hand-drawn text, once, for both faces: a NULL writer draws
   it, a writer reports it. The module's describe_scene calls this, which
   is why the labels below cannot be described differently from the way
   they are drawn - there is only the one walk. */
void files_share_content(const WorkshopSceneWriter *writer);

/* The most recent send/share outcome, for the page's status channel.
   Empty when this half has nothing to say - which is a different thing
   from the page having nothing to say, and the reason the placard's
   channels live in files_status.c. */
void files_share_status(char *out, long cap);

/* The wire's running commentary on a send (conn_set_file_note). */
void files_share_note(const char *line);

#endif /* NOW_FILES_SHARE_VIEW_H */
