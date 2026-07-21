#ifndef NOW_HOST_BROWSER_H
#define NOW_HOST_BROWSER_H

#include <Carbon.h>

#include "fileshare.h"

/* Browsing the other machine's share.
   ------------------------------------------------------------------
   A Data Browser list view, which is the native list control: sorting,
   selection and opening are its behaviour, not ours. Proved on the
   PB1400c first (spikes/databrowser) - see that README for the four
   things this had to get right, of which two are silent failures. */

void host_browser_open(void);
void host_browser_close(void);
Boolean host_browser_is(WindowRef window);
WindowRef host_browser_ref(void);
void host_browser_draw(void);
void host_browser_click(const EventRecord *event);
void host_browser_key(const EventRecord *event);
void host_browser_activate(Boolean becoming_active);

/* Running commentary on a pull (conn_set_get_note), and the tick that
   keeps its percentage moving. */
void host_browser_note(const char *line);
void host_browser_idle(void);

/* The wire's answer (conn_set_listing). */
void host_browser_listing(const char *path, const FileEntry *entries,
                          int count, Boolean more, long cursor,
                          const char *root, const char *error);

#endif /* NOW_HOST_BROWSER_H */
