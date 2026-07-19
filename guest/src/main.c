#include <Carbon.h>

#include <string.h>

#include "capture_win.h"
#include "prefs.h"
#include "settings_dialog.h"
#include "wire.h"

enum {
    kWindowMinWidth = 360,
    kWindowMinHeight = 240,
    kFileMenuID = 129,
    kFileCloseItem = 1,
    kFileQuitItem = 3,
    kWindowsMenuID = 130,
    kWindowsNewScreenshotsItem = 1,
    kWindowsConnectionItem = 2
};

static Boolean g_running = true;
static Rect g_screen_bounds;

static const unsigned char k_file_menu_title[] = {
    4, 'F', 'i', 'l', 'e'
};
static const unsigned char k_windows_menu_title[] = {
    7, 'W', 'i', 'n', 'd', 'o', 'w', 's'
};
static const unsigned char k_new_screenshots_menu_item[] = {
    24, 'N', 'e', 'w', ' ', 'S', 'c', 'r', 'e', 'e', 'n', 's', 'h', 'o',
    't', 's', ' ', 'W', 'i', 'n', 'd', 'o', 'w', '/', 'N'
};
static const unsigned char k_connection_menu_item[] = {
    13, 'C', 'o', 'n', 'n', 'e', 'c', 't', 'i', 'o', 'n', 0xC9, '/', 'K'
};
static const unsigned char k_separator_menu_item[] = {
    2, '-', ' '
};
static const unsigned char k_close_menu_item[] = {
    7, 'C', 'l', 'o', 's', 'e', '/', 'W'
};
static const unsigned char k_quit_menu_item[] = {
    6, 'Q', 'u', 'i', 't', '/', 'Q'
};

static void create_menu_bar(void)
{
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);
    MenuRef windows_menu = NewMenu(kWindowsMenuID, k_windows_menu_title);

    AppendMenu(file_menu, k_close_menu_item);
    AppendMenu(file_menu, k_separator_menu_item);
    AppendMenu(file_menu, k_quit_menu_item);
    InsertMenu(file_menu, 0);
    /* Modules live in the Windows menu; there is no main app window. */
    AppendMenu(windows_menu, k_new_screenshots_menu_item);
    AppendMenu(windows_menu, k_connection_menu_item);
    InsertMenu(windows_menu, 0);
    DrawMenuBar();
}

static void compute_screen_bounds(void)
{
    RgnHandle desktop = GetGrayRgn();

    if (desktop != NULL) {
        GetRegionBounds(desktop, &g_screen_bounds);
    } else {
        SetRect(&g_screen_bounds, 0, 20, 800, 600);
    }
}

static void close_front_window(void)
{
    NowCaptureWindow *win = capwin_front();

    if (win != NULL) {
        capwin_destroy(win);
    }
}

/* The session (open windows + their bounds and depths) rides in the prefs
   file next to the connection settings, so a relaunch restores exactly what
   was on screen — including nothing. */
static void save_session(void)
{
    NowPrefs prefs;
    NowCaptureWindow *win;
    Rect bounds;
    short n = 0;

    now_prefs_load(&prefs);
    for (win = capwin_first(); win != NULL && n < kNowMaxSavedWindows;
         win = win->next) {
        GetWindowBounds(win->window, kWindowContentRgn, &bounds);
        prefs.windows[n].left = bounds.left;
        prefs.windows[n].top = bounds.top;
        prefs.windows[n].right = bounds.right;
        prefs.windows[n].bottom = bounds.bottom;
        prefs.windows[n].depth = win->depth;
        ++n;
    }
    prefs.window_count = n;
    now_prefs_save(&prefs);
}

static void restore_session(void)
{
    NowPrefs prefs;
    Rect bounds;
    short i;

    now_prefs_load(&prefs);
    if (prefs.window_count < 0) {
        capwin_create(NULL, 8);       /* first run: one default window */
        return;
    }
    /* Restore back-to-front so list order (front first) round-trips. */
    for (i = (short)(prefs.window_count - 1); i >= 0; --i) {
        SetRect(&bounds, prefs.windows[i].left, prefs.windows[i].top,
                prefs.windows[i].right, prefs.windows[i].bottom);
        capwin_create(&bounds, prefs.windows[i].depth);
    }
}

static void handle_menu_choice(long choice)
{
    if (HiWord(choice) == kFileMenuID) {
        if (LoWord(choice) == kFileCloseItem) {
            close_front_window();
        } else if (LoWord(choice) == kFileQuitItem) {
            g_running = false;
        }
    } else if (HiWord(choice) == kWindowsMenuID) {
        if (LoWord(choice) == kWindowsNewScreenshotsItem) {
            capwin_create(NULL, 8);
        } else if (LoWord(choice) == kWindowsConnectionItem) {
            now_settings_dialog_run();
        }
    }
}

static void handle_mouse_down(const EventRecord *event)
{
    WindowRef window;
    NowCaptureWindow *win;
    Point local;
    short part = FindWindow(event->where, &window);

    if (part == inMenuBar) {
        long choice = MenuSelect(event->where);
        handle_menu_choice(choice);
        HiliteMenu(0);
        return;
    }
    win = capwin_find(window);
    if (win == NULL) {
        return;
    }
    if (part == inDrag) {
        DragWindow(window, event->where, &g_screen_bounds);
    } else if (part == inGrow) {
        Rect limits;
        long size;

        SetRect(&limits, kWindowMinWidth, kWindowMinHeight,
                (short)(g_screen_bounds.right - g_screen_bounds.left),
                (short)(g_screen_bounds.bottom - g_screen_bounds.top));
        size = GrowWindow(window, event->where, &limits);
        if (size != 0) {
            Rect inval;

            SizeWindow(window, LoWord(size), HiWord(size), true);
            GetWindowPortBounds(window, &inval);
            InvalWindowRect(window, &inval);
        }
    } else if (part == inZoomIn || part == inZoomOut) {
        if (TrackBox(window, event->where, part)) {
            Rect inval;

            SetPortWindowPort(window);
            ZoomWindow(window, part, false);
            GetWindowPortBounds(window, &inval);
            InvalWindowRect(window, &inval);
        }
    } else if (part == inGoAway) {
        if (TrackGoAway(window, event->where)) {
            capwin_destroy(win);
        }
    } else if (part == inContent) {
        if (window != FrontWindow()) {
            SelectWindow(window);
            return;
        }
        local = event->where;
        SetPortWindowPort(window);
        GlobalToLocal(&local);
        capwin_content_click(win, local);
    }
}

static void handle_key_down(const EventRecord *event)
{
    char key = (char)(event->message & charCodeMask);

    if ((event->modifiers & cmdKey) != 0) {
        long choice = MenuKey(key);
        handle_menu_choice(choice);
        HiliteMenu(0);
    } else if (key == '\r' || key == '\n') {
        NowCaptureWindow *win = capwin_front();

        if (win != NULL) {
            capwin_capture(win);
        }
    }
}

static pascal OSErr handle_quit_apple_event(const AppleEvent *event,
                                             AppleEvent *reply,
                                             long refcon)
{
    (void)event;
    (void)reply;
    (void)refcon;
    g_running = false;
    return noErr;
}

int main(void)
{
    EventRecord event;
    AEEventHandlerUPP quit_handler;
    NowCaptureWindow *win;

    InitCursor();
    FlushEvents(everyEvent, 0);
    compute_screen_bounds();
    create_menu_bar();
    restore_session();
    conn_init();

    /* On CFM PowerPC a UPP is the tvector itself; the cast avoids
       NewAEEventHandlerUPP, a weakly-linked import that would resolve to
       NULL (and crash) on CarbonLib versions that lack it. */
    quit_handler = (AEEventHandlerUPP)handle_quit_apple_event;
    AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                          quit_handler, 0, false);

    while (g_running) {
        conn_service();
        if (!WaitNextEvent(everyEvent, &event, 6, NULL)) {
            continue;
        }
        switch (event.what) {
        case mouseDown:
            handle_mouse_down(&event);
            break;
        case keyDown:
            /* autoKey is deliberately ignored: a held Return must not
               machine-gun the capture history. */
            handle_key_down(&event);
            break;
        case updateEvt:
            win = capwin_find((WindowRef)event.message);
            if (win != NULL) {
                BeginUpdate(win->window);
                capwin_draw(win);
                EndUpdate(win->window);
            }
            break;
        case kHighLevelEvent:
            AEProcessAppleEvent(&event);
            break;
        default:
            break;
        }
    }

    save_session();
    conn_shutdown();
    AERemoveEventHandler(kCoreEventClass, kAEQuitApplication,
                         quit_handler, false);
    capwin_destroy_all();
    return 0;
}
