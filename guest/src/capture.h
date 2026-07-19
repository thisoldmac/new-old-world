#ifndef NOW_CAPTURE_H
#define NOW_CAPTURE_H

#include <Carbon.h>

typedef struct {
    GWorldPtr world;
    Rect bounds;
    short depth;
    short row_bytes;
    long pixel_bytes;
} CaptureImage;

enum {
    kCaptureOK = 0,
    kCaptureInvalidDepth = -1,
    kCaptureNoScreen = -2,
    kCaptureNoMemory = -3,
    kCapturePixelsUnavailable = -4
};

Boolean capture_depth_is_supported(short depth);

/* Captures the entire main screen into a fresh GWorld at `depth` (QuickDraw
   converts during the blit). Caller owns the image; dispose when done. */
int capture_screen(short depth, CaptureImage *image);

void capture_image_dispose(CaptureImage *image);

#endif
