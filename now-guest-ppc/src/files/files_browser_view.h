#ifndef NOW_FILES_BROWSER_VIEW_H
#define NOW_FILES_BROWSER_VIEW_H

#include <Carbon.h>

#include "fileshare.h"

/* The remote half of the Files page: the peer's share in a Data
   Browser, with the Up button's path model and file retrieval. The view
   owns its child controls and the two callback UPPs; the Workshop owns
   the window. */

Boolean files_browser_create(WindowRef owner, const Rect *area);
/* After DisposeWindow, never before: the list may still call back
   through the UPPs until the window takes the control with it. */
void files_browser_dispose(void);
/* False when the Data Browser could not be created; the page then says
   browsing is unavailable but the share settings stay usable. */
Boolean files_browser_available(void);

void files_browser_layout(const Rect *area);
void files_browser_show(Boolean visible);
void files_browser_draw(void);
Boolean files_browser_click(const EventRecord *event, Point local);
Boolean files_browser_key(const EventRecord *event);
void files_browser_activate(Boolean active);
void files_browser_idle(void);

void files_browser_go_up(void);
Boolean files_browser_at_root(void);
/* The path row's text: "<peer>: <share root><path>". */
void files_browser_path_text(char *out, long cap);
/* The live listing state for the path row: "Reading...", "N items". */
void files_browser_count_text(char *out, long cap);
/* Transfer commentary and errors, for the status placard. */
void files_browser_note_text(char *out, long cap);

/* The wire's listing answer (conn_set_listing). */
void files_browser_listing(const char *path, const FileEntry *entries,
                           int count, Boolean more, long cursor,
                           const char *root, const char *error);
/* The wire's running commentary on a pull (conn_set_get_note). */
void files_browser_note(const char *line);

#endif /* NOW_FILES_BROWSER_VIEW_H */
