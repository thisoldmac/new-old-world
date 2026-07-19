#include <Carbon.h>

#include <stdio.h>
#include <string.h>

#include "capture.h"
#include "capture_store.h"
#include "product_identity.h"

enum {
    kWindowWidth = 700,
    kWindowHeight = 510,
    kWindowMinWidth = 360,
    kWindowMinHeight = 240,
    kControlHeight = 24,
    kFileMenuID = 129,
    kFileQuitItem = 1
};

static WindowRef g_window;
static ControlRef g_capture_button;
static ControlRef g_depth_button;
static ControlRef g_previous_button;
static ControlRef g_next_button;
static CaptureStore g_store;
static short g_depth = 8;
static unsigned long g_next_sequence = 1;
static Boolean g_running = true;
static Rect g_screen_bounds;

static const short k_depths[] = { 1, 8, 16, 32 };
static const unsigned char k_empty_pascal[] = { 0 };
static const unsigned char k_file_menu_title[] = {
    4, 'F', 'i', 'l', 'e'
};
static const unsigned char k_quit_menu_item[] = {
    6, 'Q', 'u', 'i', 't', '/', 'Q'
};

static void request_redraw(void)
{
    Rect bounds;

    GetWindowPortBounds(g_window, &bounds);
    InvalWindowRect(g_window, &bounds);
}

static void set_depth_button_title(void)
{
    char title[32];
    Str255 text;

    snprintf(title, sizeof title, "Depth: %d-bit", g_depth);
    CopyCStringToPascal(title, text);
    SetControlTitle(g_depth_button, text);
}

static void update_history_controls(void)
{
    Boolean has_previous = g_store.selected > 0;
    Boolean has_next = g_store.selected >= 0
        && g_store.selected + 1 < g_store.count;

    HiliteControl(g_previous_button, has_previous ? 0 : 255);
    HiliteControl(g_next_button, has_next ? 0 : 255);
}

static void cycle_depth(void)
{
    unsigned int index;

    for (index = 0; index < sizeof k_depths / sizeof k_depths[0]; ++index) {
        if (k_depths[index] == g_depth) {
            g_depth = k_depths[(index + 1)
                % (sizeof k_depths / sizeof k_depths[0])];
            break;
        }
    }
    set_depth_button_title();
    request_redraw();
}

static void show_capture_error(int error)
{
    const char *reason = "The screenshot could not be created.";
    Str255 message;

    if (error == kCaptureNoMemory) {
        reason = "There is not enough memory for this capture depth.";
    } else if (error == kCapturePixelsUnavailable) {
        reason = "QuickDraw could not access the capture pixels.";
    }
    CopyCStringToPascal(reason, message);
    ParamText(message, k_empty_pascal, k_empty_pascal, k_empty_pascal);
    Alert(200, NULL);
}

static void capture_self(void)
{
    CaptureImage image;
    int result;

    result = capture_window(g_window, g_depth, g_next_sequence, &image);
    if (result != kCaptureOK) {
        show_capture_error(result);
        return;
    }
    ++g_next_sequence;
    capture_store_append(&g_store, &image);
    update_history_controls();
    request_redraw();
}

static void draw_status(const CaptureImage *image)
{
    char status[128];
    Str255 text;

    MoveTo(20, 91);
    UseThemeFont(kThemeSystemFont, smSystemScript);
    if (image == NULL) {
        CopyCStringToPascal("Capture this window to begin.", text);
    } else {
        snprintf(status, sizeof status,
                 "Screenshot %lu  -  %d-bit  -  %ld KB  -  %d of %d",
                 image->sequence, image->depth, image->pixel_bytes / 1024,
                 g_store.selected + 1, g_store.count);
        CopyCStringToPascal(status, text);
    }
    DrawString(text);
}

static void fit_rect(const Rect *source, const Rect *box, Rect *result)
{
    long source_width = source->right - source->left;
    long source_height = source->bottom - source->top;
    long box_width = box->right - box->left;
    long box_height = box->bottom - box->top;
    long width;
    long height;

    if (source_width * box_height > source_height * box_width) {
        width = box_width;
        height = source_height * box_width / source_width;
    } else {
        height = box_height;
        width = source_width * box_height / source_height;
    }
    result->left = (short)(box->left + (box_width - width) / 2);
    result->top = (short)(box->top + (box_height - height) / 2);
    result->right = (short)(result->left + width);
    result->bottom = (short)(result->top + height);
}

static void draw_content(void)
{
    const CaptureImage *image = capture_store_current(&g_store);
    Rect window_bounds;
    Rect preview_box;
    Rect destination;
    RGBColor frame = { 0x7777, 0x7777, 0x7777 };

    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &window_bounds);
    EraseRect(&window_bounds);
    DrawControls(g_window);
    draw_status(image);

    SetRect(&preview_box, 20, 108,
            (short)(window_bounds.right - 20),
            (short)(window_bounds.bottom - 20));
    RGBForeColor(&frame);
    FrameRect(&preview_box);
    ForeColor(blackColor);

    if (image != NULL) {
        InsetRect(&preview_box, 8, 8);
        fit_rect(&image->bounds, &preview_box, &destination);
        capture_image_draw(image, &destination);
    }
}

static ControlRef make_push_button(const Rect *bounds, const char *title)
{
    Str255 text;

    CopyCStringToPascal(title, text);
    return NewControl(g_window, bounds, text, true, 0, 0, 1, pushButProc, 0);
}

static void create_controls(void)
{
    Rect bounds;

    SetRect(&bounds, 20, 20, 138, 20 + kControlHeight);
    g_capture_button = make_push_button(&bounds, "Capture This Window");
    SetRect(&bounds, 150, 20, 270, 20 + kControlHeight);
    g_depth_button = make_push_button(&bounds, "Depth: 8-bit");
    SetRect(&bounds, 20, 56, 104, 56 + kControlHeight);
    g_previous_button = make_push_button(&bounds, "Previous");
    SetRect(&bounds, 116, 56, 200, 56 + kControlHeight);
    g_next_button = make_push_button(&bounds, "Next");
    update_history_controls();
}

static void create_menu_bar(void)
{
    MenuRef file_menu = NewMenu(kFileMenuID, k_file_menu_title);

    AppendMenu(file_menu, k_quit_menu_item);
    InsertMenu(file_menu, 0);
    DrawMenuBar();
}

static void create_main_window(void)
{
    Rect bounds;
    Str255 title;
    RgnHandle desktop = GetGrayRgn();

    /* The gray region already excludes the menu bar; its bounds are the
       classic-portable answer to "where may windows go". */
    if (desktop != NULL) {
        GetRegionBounds(desktop, &g_screen_bounds);
    } else {
        SetRect(&g_screen_bounds, 0, 20, 800, 600);
    }

    bounds.left = (short)(g_screen_bounds.left
        + (g_screen_bounds.right - g_screen_bounds.left
        - kWindowWidth) / 2);
    bounds.top = (short)(g_screen_bounds.top
        + (g_screen_bounds.bottom - g_screen_bounds.top
        - kWindowHeight) / 2);
    bounds.right = (short)(bounds.left + kWindowWidth);
    bounds.bottom = (short)(bounds.top + kWindowHeight);

    CreateNewWindow(kDocumentWindowClass,
                    kWindowStandardDocumentAttributes,
                    &bounds, &g_window);
    CopyCStringToPascal(PRODUCT_WINDOW_TITLE, title);
    SetWTitle(g_window, title);
    SetThemeWindowBackground(g_window, kThemeBrushDocumentWindowBackground,
                             true);
    create_controls();
    ShowWindow(g_window);
    SelectWindow(g_window);
}

static void handle_control_click(Point point)
{
    ControlRef control = NULL;

    if (FindControl(point, g_window, &control) == 0 || control == NULL) {
        return;
    }
    if (TrackControl(control, point, NULL) == 0) {
        return;
    }
    if (control == g_capture_button) {
        capture_self();
    } else if (control == g_depth_button) {
        cycle_depth();
    } else if (control == g_previous_button
               && capture_store_select_previous(&g_store)) {
        update_history_controls();
        request_redraw();
    } else if (control == g_next_button
               && capture_store_select_next(&g_store)) {
        update_history_controls();
        request_redraw();
    }
}

static void handle_mouse_down(const EventRecord *event)
{
    WindowRef window;
    Point local;
    short part = FindWindow(event->where, &window);

    if (part == inMenuBar) {
        long choice = MenuSelect(event->where);
        if (HiWord(choice) == kFileMenuID && LoWord(choice) == kFileQuitItem) {
            g_running = false;
        }
        HiliteMenu(0);
    } else if (part == inDrag && window == g_window) {
        DragWindow(window, event->where, &g_screen_bounds);
    } else if (part == inGrow && window == g_window) {
        Rect limits;
        long size;

        SetRect(&limits, kWindowMinWidth, kWindowMinHeight,
                (short)(g_screen_bounds.right - g_screen_bounds.left),
                (short)(g_screen_bounds.bottom - g_screen_bounds.top));
        size = GrowWindow(window, event->where, &limits);
        if (size != 0) {
            SizeWindow(window, LoWord(size), HiWord(size), true);
            request_redraw();
        }
    } else if ((part == inZoomIn || part == inZoomOut) && window == g_window
               && TrackBox(window, event->where, part)) {
        SetPortWindowPort(window);
        ZoomWindow(window, part, false);
        request_redraw();
    } else if (part == inGoAway && window == g_window
               && TrackGoAway(window, event->where)) {
        g_running = false;
    } else if (part == inContent && window == g_window) {
        if (window != FrontWindow()) {
            SelectWindow(window);
            return;
        }
        local = event->where;
        SetPortWindowPort(window);
        GlobalToLocal(&local);
        handle_control_click(local);
    }
}

static void handle_key_down(const EventRecord *event)
{
    char key = (char)(event->message & charCodeMask);

    if ((event->modifiers & cmdKey) != 0) {
        long choice = MenuKey(key);
        if (HiWord(choice) == kFileMenuID && LoWord(choice) == kFileQuitItem) {
            g_running = false;
        }
        HiliteMenu(0);
    } else if (key == '\r' || key == '\n') {
        capture_self();
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

    InitCursor();
    FlushEvents(everyEvent, 0);
    capture_store_init(&g_store);
    create_menu_bar();
    create_main_window();

    /* On CFM PowerPC a UPP is the tvector itself; the cast avoids
       NewAEEventHandlerUPP, a weakly-linked import that would resolve to
       NULL (and crash) on CarbonLib versions that lack it. */
    quit_handler = (AEEventHandlerUPP)handle_quit_apple_event;
    AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                          quit_handler, 0, false);

    while (g_running) {
        if (!WaitNextEvent(everyEvent, &event, 12, NULL)) {
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
            if ((WindowRef)event.message == g_window) {
                BeginUpdate(g_window);
                draw_content();
                EndUpdate(g_window);
            }
            break;
        case kHighLevelEvent:
            AEProcessAppleEvent(&event);
            break;
        default:
            break;
        }
    }

    AERemoveEventHandler(kCoreEventClass, kAEQuitApplication,
                         quit_handler, false);
    capture_store_dispose(&g_store);
    DisposeWindow(g_window);
    return 0;
}
