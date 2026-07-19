#include "capture.h"

#include <string.h>

Boolean capture_depth_is_supported(short depth)
{
    return depth == 1 || depth == 8 || depth == 16 || depth == 32;
}

int capture_window(WindowRef window, short depth, unsigned long sequence,
                   CaptureImage *image)
{
    Rect source_bounds;
    Rect capture_bounds;
    GWorldPtr world = NULL;
    PixMapHandle pixels;
    CGrafPtr saved_port;
    GDHandle saved_device;
    const BitMap *source;
    OSErr err;

    memset(image, 0, sizeof *image);
    if (!capture_depth_is_supported(depth)) {
        return kCaptureInvalidDepth;
    }

    GetWindowPortBounds(window, &source_bounds);
    if (source_bounds.right <= source_bounds.left
        || source_bounds.bottom <= source_bounds.top) {
        return kCaptureEmptyWindow;
    }
    SetRect(&capture_bounds, 0, 0,
            (short)(source_bounds.right - source_bounds.left),
            (short)(source_bounds.bottom - source_bounds.top));

    err = NewGWorld(&world, depth, &capture_bounds, NULL, NULL, useTempMem);
    if (err != noErr || world == NULL) {
        return kCaptureNoMemory;
    }
    pixels = GetGWorldPixMap(world);
    if (pixels == NULL || !LockPixels(pixels)) {
        DisposeGWorld(world);
        return kCapturePixelsUnavailable;
    }

    source = GetPortBitMapForCopyBits(GetWindowPort(window));
    GetGWorld(&saved_port, &saved_device);
    SetGWorld(world, NULL);
    CopyBits(source, GetPortBitMapForCopyBits(world),
             &source_bounds, &capture_bounds, srcCopy, NULL);
    SetGWorld(saved_port, saved_device);

    image->world = world;
    image->bounds = capture_bounds;
    image->depth = depth;
    image->row_bytes = (short)((*pixels)->rowBytes & 0x3FFF);
    image->pixel_bytes = (long)image->row_bytes
        * (capture_bounds.bottom - capture_bounds.top);
    image->sequence = sequence;
    UnlockPixels(pixels);
    return kCaptureOK;
}

void capture_image_draw(const CaptureImage *image, const Rect *destination)
{
    PixMapHandle pixels;
    CGrafPtr port;

    if (image == NULL || image->world == NULL) {
        return;
    }
    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL || !LockPixels(pixels)) {
        return;
    }
    GetPort(&port);
    CopyBits(GetPortBitMapForCopyBits(image->world),
             GetPortBitMapForCopyBits(port),
             &image->bounds, destination, srcCopy, NULL);
    UnlockPixels(pixels);
}

void capture_image_dispose(CaptureImage *image)
{
    if (image != NULL && image->world != NULL) {
        DisposeGWorld(image->world);
        memset(image, 0, sizeof *image);
    }
}
