#include "capture.h"

#include <string.h>

Boolean capture_depth_is_supported(short depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

int capture_screen(short depth, CaptureImage *image)
{
    GDHandle device;
    PixMapHandle screen_pix;
    Rect screen_bounds;
    GWorldPtr world = NULL;
    PixMapHandle pixels;
    CGrafPtr saved_port;
    GDHandle saved_device;
    OSErr err;

    memset(image, 0, sizeof *image);
    if (!capture_depth_is_supported(depth)) {
        return kCaptureInvalidDepth;
    }
    device = GetMainDevice();
    if (device == NULL) {
        return kCaptureNoScreen;
    }
    screen_pix = (**device).gdPMap;
    if (screen_pix == NULL) {
        return kCaptureNoScreen;
    }
    screen_bounds = (**screen_pix).bounds;

    err = NewGWorld(&world, depth, &screen_bounds, NULL, NULL, useTempMem);
    if (err != noErr || world == NULL) {
        return kCaptureNoMemory;
    }
    pixels = GetGWorldPixMap(world);
    if (pixels == NULL || !LockPixels(pixels)) {
        DisposeGWorld(world);
        return kCapturePixelsUnavailable;
    }

    GetGWorld(&saved_port, &saved_device);
    SetGWorld(world, NULL);
    LockPixels(screen_pix);
    CopyBits((BitMapPtr)*screen_pix,
             GetPortBitMapForCopyBits(world),
             &screen_bounds, &screen_bounds, srcCopy, NULL);
    UnlockPixels(screen_pix);
    SetGWorld(saved_port, saved_device);

    image->world = world;
    image->bounds = screen_bounds;
    image->depth = depth;
    image->row_bytes = (short)((**pixels).rowBytes & 0x3FFF);
    image->pixel_bytes = (long)image->row_bytes
        * (screen_bounds.bottom - screen_bounds.top);
    UnlockPixels(pixels);
    return kCaptureOK;
}

void capture_image_dispose(CaptureImage *image)
{
    if (image != NULL && image->world != NULL) {
        DisposeGWorld(image->world);
        memset(image, 0, sizeof *image);
    }
}
