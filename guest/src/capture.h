#ifndef SCREENSHOTS_CAPTURE_H
#define SCREENSHOTS_CAPTURE_H

#include <Carbon.h>

typedef struct {
    GWorldPtr world;
    Rect bounds;
    short depth;
    short row_bytes;
    long pixel_bytes;
    unsigned long sequence;
} CaptureImage;

enum {
    kCaptureOK = 0,
    kCaptureInvalidDepth = -1,
    kCaptureEmptyWindow = -2,
    kCaptureNoMemory = -3,
    kCapturePixelsUnavailable = -4
};

Boolean capture_depth_is_supported(short depth);
int capture_window(WindowRef window, short depth, unsigned long sequence,
                   CaptureImage *image);
void capture_image_draw(const CaptureImage *image, const Rect *destination);
void capture_image_dispose(CaptureImage *image);

#endif

