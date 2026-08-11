#ifndef NOW_FILES_SHARE_VIEW_H
#define NOW_FILES_SHARE_VIEW_H

#include <Carbon.h>

/* The local half of the Files page: what this Mac exposes, where pulled
   files land, sending a file, and the native progress bar for a send in
   flight. Paths, offers, and transfer state stay owned by fileshare.c
   and the wire. */

Boolean files_share_create(WindowRef owner, const Rect *area);
void files_share_dispose(void);

void files_share_layout(const Rect *area);
void files_share_show(Boolean visible);
void files_share_draw(void);
Boolean files_share_click(const EventRecord *event, Point local);
void files_share_activate(Boolean active);
void files_share_idle(void);

/* The most recent send/share outcome for the status placard. */
void files_share_status(char *out, long cap);

/* The wire's running commentary on a send (conn_set_file_note). */
void files_share_note(const char *line);

#endif /* NOW_FILES_SHARE_VIEW_H */
