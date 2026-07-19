#ifndef NOW_CAPTURE_WIN_H
#define NOW_CAPTURE_WIN_H

#include <Carbon.h>

#include "capture_store.h"

/* One capture window: its own history, depth, and controls. The app owns
   zero to N of these; closing one never quits the app. */
typedef struct NowCaptureWindow {
    struct NowCaptureWindow *next;
    WindowRef window;
    ControlRef capture_button;
    ControlRef depth_button;
    ControlRef previous_button;
    ControlRef next_button;
    CaptureStore store;
    short depth;
} NowCaptureWindow;

/* content: global content bounds to restore, or NULL for a default
   (centered, staggered by how many windows already exist). */
NowCaptureWindow *capwin_create(const Rect *content, short depth);
void capwin_destroy(NowCaptureWindow *win);
void capwin_destroy_all(void);

NowCaptureWindow *capwin_find(WindowRef window);
NowCaptureWindow *capwin_front(void);
NowCaptureWindow *capwin_first(void);
short capwin_count(void);

void capwin_draw(NowCaptureWindow *win);
void capwin_capture(NowCaptureWindow *win);
void capwin_content_click(NowCaptureWindow *win, Point local);

#endif
