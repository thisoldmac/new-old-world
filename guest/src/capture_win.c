#include "capture_win.h"

#include <stdio.h>
#include <string.h>

#include "capture.h"
#include "product_identity.h"

enum {
    kWindowWidth = 700,
    kWindowHeight = 510,
    kControlHeight = 24,
    kStaggerStep = 24
};

static NowCaptureWindow *g_windows = NULL;
static unsigned long g_next_sequence = 1;
static unsigned long g_window_serial = 0;

static const short k_depths[] = { 1, 8, 16, 32 };

static void request_redraw(NowCaptureWindow *win)
{
    Rect bounds;

    GetWindowPortBounds(win->window, &bounds);
    InvalWindowRect(win->window, &bounds);
}

static void set_depth_button_title(NowCaptureWindow *win)
{
    char title[32];
    Str255 text;

    snprintf(title, sizeof title, "Depth: %d-bit", win->depth);
    CopyCStringToPascal(title, text);
    SetControlTitle(win->depth_button, text);
}

static void update_history_controls(NowCaptureWindow *win)
{
    Boolean has_previous = win->store.selected > 0;
    Boolean has_next = win->store.selected >= 0
        && win->store.selected + 1 < win->store.count;

    HiliteControl(win->previous_button, has_previous ? 0 : 255);
    HiliteControl(win->next_button, has_next ? 0 : 255);
}

static ControlRef make_push_button(WindowRef window, const Rect *bounds,
                                   const char *title)
{
    Str255 text;

    CopyCStringToPascal(title, text);
    return NewControl(window, bounds, text, true, 0, 0, 1, pushButProc, 0);
}

static void default_content_bounds(Rect *bounds)
{
    Rect screen;
    RgnHandle desktop = GetGrayRgn();
    short stagger = (short)((capwin_count() % 6) * kStaggerStep);

    if (desktop != NULL) {
        GetRegionBounds(desktop, &screen);
    } else {
        SetRect(&screen, 0, 20, 800, 600);
    }
    bounds->left = (short)(screen.left
        + (screen.right - screen.left - kWindowWidth) / 2 + stagger);
    bounds->top = (short)(screen.top
        + (screen.bottom - screen.top - kWindowHeight) / 2 + stagger);
    bounds->right = (short)(bounds->left + kWindowWidth);
    bounds->bottom = (short)(bounds->top + kWindowHeight);
}

NowCaptureWindow *capwin_create(const Rect *content, short depth)
{
    NowCaptureWindow *win;
    Rect bounds;
    Str255 title;
    char name[48];

    win = (NowCaptureWindow *)NewPtrClear(sizeof *win);
    if (win == NULL) {
        return NULL;
    }
    if (content != NULL && content->right - content->left >= 360
        && content->bottom - content->top >= 240) {
        bounds = *content;
    } else {
        default_content_bounds(&bounds);
    }
    capture_store_init(&win->store);
    win->depth = capture_depth_is_supported(depth) ? depth : 8;

    CreateNewWindow(kDocumentWindowClass,
                    kWindowStandardDocumentAttributes,
                    &bounds, &win->window);
    if (win->window == NULL) {
        DisposePtr((Ptr)win);
        return NULL;
    }
    ++g_window_serial;
    if (g_window_serial == 1) {
        snprintf(name, sizeof name, "Screenshots");
    } else {
        snprintf(name, sizeof name, "Screenshots %lu", g_window_serial);
    }
    CopyCStringToPascal(name, title);
    SetWTitle(win->window, title);
    SetThemeWindowBackground(win->window,
                             kThemeBrushDocumentWindowBackground, true);

    SetRect(&bounds, 20, 20, 138, 20 + kControlHeight);
    win->capture_button = make_push_button(win->window, &bounds,
                                           "Capture This Window");
    SetRect(&bounds, 150, 20, 270, 20 + kControlHeight);
    win->depth_button = make_push_button(win->window, &bounds, "Depth: 8-bit");
    SetRect(&bounds, 20, 56, 104, 56 + kControlHeight);
    win->previous_button = make_push_button(win->window, &bounds, "Previous");
    SetRect(&bounds, 116, 56, 200, 56 + kControlHeight);
    win->next_button = make_push_button(win->window, &bounds, "Next");
    set_depth_button_title(win);
    update_history_controls(win);

    win->next = g_windows;
    g_windows = win;
    ShowWindow(win->window);
    SelectWindow(win->window);
    return win;
}

void capwin_destroy(NowCaptureWindow *win)
{
    NowCaptureWindow **link;

    for (link = &g_windows; *link != NULL; link = &(*link)->next) {
        if (*link == win) {
            *link = win->next;
            break;
        }
    }
    capture_store_dispose(&win->store);
    DisposeWindow(win->window);
    DisposePtr((Ptr)win);
}

void capwin_destroy_all(void)
{
    while (g_windows != NULL) {
        capwin_destroy(g_windows);
    }
}

NowCaptureWindow *capwin_find(WindowRef window)
{
    NowCaptureWindow *win;

    for (win = g_windows; win != NULL; win = win->next) {
        if (win->window == window) {
            return win;
        }
    }
    return NULL;
}

NowCaptureWindow *capwin_front(void)
{
    return capwin_find(FrontWindow());
}

NowCaptureWindow *capwin_first(void)
{
    return g_windows;
}

short capwin_count(void)
{
    short n = 0;
    NowCaptureWindow *win;

    for (win = g_windows; win != NULL; win = win->next) {
        ++n;
    }
    return n;
}

static void show_capture_error(int error)
{
    const char *reason = "The screenshot could not be created.";
    Str255 message;
    static const unsigned char empty[] = { 0 };

    if (error == kCaptureNoMemory) {
        reason = "There is not enough memory for this capture depth.";
    } else if (error == kCapturePixelsUnavailable) {
        reason = "QuickDraw could not access the capture pixels.";
    }
    CopyCStringToPascal(reason, message);
    ParamText(message, empty, empty, empty);
    Alert(200, NULL);
}

void capwin_capture(NowCaptureWindow *win)
{
    CaptureImage image;
    int result;

    result = capture_window(win->window, win->depth, g_next_sequence, &image);
    if (result != kCaptureOK) {
        show_capture_error(result);
        return;
    }
    ++g_next_sequence;
    capture_store_append(&win->store, &image);
    update_history_controls(win);
    request_redraw(win);
}

static void cycle_depth(NowCaptureWindow *win)
{
    unsigned int index;

    for (index = 0; index < sizeof k_depths / sizeof k_depths[0]; ++index) {
        if (k_depths[index] == win->depth) {
            win->depth = k_depths[(index + 1)
                % (sizeof k_depths / sizeof k_depths[0])];
            break;
        }
    }
    set_depth_button_title(win);
    request_redraw(win);
}

static void draw_status(NowCaptureWindow *win, const CaptureImage *image)
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
                 win->store.selected + 1, win->store.count);
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

void capwin_draw(NowCaptureWindow *win)
{
    const CaptureImage *image = capture_store_current(&win->store);
    Rect window_bounds;
    Rect preview_box;
    Rect destination;
    RGBColor frame = { 0x7777, 0x7777, 0x7777 };

    SetPortWindowPort(win->window);
    GetWindowPortBounds(win->window, &window_bounds);
    EraseRect(&window_bounds);
    DrawControls(win->window);
    draw_status(win, image);

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

void capwin_content_click(NowCaptureWindow *win, Point local)
{
    ControlRef control = NULL;

    if (FindControl(local, win->window, &control) == 0 || control == NULL) {
        return;
    }
    if (TrackControl(control, local, NULL) == 0) {
        return;
    }
    if (control == win->capture_button) {
        capwin_capture(win);
    } else if (control == win->depth_button) {
        cycle_depth(win);
    } else if (control == win->previous_button
               && capture_store_select_previous(&win->store)) {
        update_history_controls(win);
        request_redraw(win);
    } else if (control == win->next_button
               && capture_store_select_next(&win->store)) {
        update_history_controls(win);
        request_redraw(win);
    }
}
