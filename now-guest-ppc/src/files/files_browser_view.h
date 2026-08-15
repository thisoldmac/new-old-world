#ifndef NOW_FILES_BROWSER_VIEW_H
#define NOW_FILES_BROWSER_VIEW_H

#include <Carbon.h>

#include "files_pull.h"
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
/* This view's own errors, for the page's browse status channel. Empty
   when it has nothing to say; the transfer's commentary is a different
   channel and comes from the pull, not from here. */
void files_browser_note_text(char *out, long cap);

/* True ONCE, for a pass in which the path, the count or the note
   changed. The path row belongs to the module, so this is how a listing
   that arrived asks for it to be repainted. */
Boolean files_browser_chrome_changed(void);

/* --- the pull in flight -------------------------------------------------
   The view is what starts a pull (a double-click, or Return on a
   selection), so it is what knows a pull was asked for before any byte
   confirms it. The module owns the Stop control and the drawing; these
   are the seam between them. */

/* The current pull, folded from now_wire_get_active() on every idle
   pass. True while one is live. */
Boolean files_browser_pull(PullView *out);

/* True ONCE, for the pass in which a pull was just started here. The
   module uses it to put a Stop button on screen in the same click that
   started the transfer, rather than one event-loop pass later. */
Boolean files_browser_pull_began(void);

/* Stop the pull in flight. Runs the registered canceller (files_pull.h),
   leaves the pane saying what was left behind, and returns false with a
   reason in `err` when there was nothing to stop or the wire refused. */
Boolean files_browser_stop_pull(char *err, long cap);

/* The wire's listing answer (conn_set_listing). */
void files_browser_listing(const char *path, const FileEntry *entries,
                           int count, Boolean more, long cursor,
                           const char *root, const char *error);
/* The wire's running commentary on a pull (conn_set_get_note). */
void files_browser_note(const char *line);

#endif /* NOW_FILES_BROWSER_VIEW_H */
