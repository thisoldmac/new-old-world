#include "capture.h"

#include <string.h>

Boolean capture_depth_is_supported(short depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

int banded_capture_begin(short depth, short bands, BandedCapture *cap)
{
    GDHandle device;
    PixMapHandle screen_pix;
    Rect screen_bounds;
    GWorldPtr world = NULL;
    PixMapHandle pixels;
    OSErr err;
    long height;

    memset(cap, 0, sizeof *cap);
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
    height = screen_bounds.bottom - screen_bounds.top;
    if (bands < 1) {
        bands = 1;
    }
    if (bands > kCaptureMaxBands) {
        bands = kCaptureMaxBands;
    }
    if ((long)bands > height) {
        bands = (short)height;
    }

    err = NewGWorld(&world, depth, &screen_bounds, NULL, NULL, useTempMem);
    if (err != noErr || world == NULL) {
        return kCaptureNoMemory;
    }
    pixels = GetGWorldPixMap(world);
    if (pixels == NULL) {
        DisposeGWorld(world);
        return kCapturePixelsUnavailable;
    }

    cap->image.world = world;
    cap->image.bounds = screen_bounds;
    cap->image.depth = depth;
    cap->image.row_bytes = (short)((**pixels).rowBytes & 0x3FFF);
    cap->image.pixel_bytes = (long)cap->image.row_bytes * height;
    cap->screen_bounds = screen_bounds;
    cap->bands = bands;
    cap->next_band = 0;
    return kCaptureOK;
}

int banded_capture_step(BandedCapture *cap)
{
    GDHandle device;
    PixMapHandle screen_pix;
    PixMapHandle pixels;
    CGrafPtr saved_port;
    GDHandle saved_device;
    Rect band;
    long height, top, bottom;
    UnsignedWide t0, t1;

    if (cap->image.world == NULL) {
        return kCapturePixelsUnavailable;
    }
    if (cap->next_band >= cap->bands) {
        return kCaptureOK;
    }
    device = GetMainDevice();
    if (device == NULL || (**device).gdPMap == NULL) {
        banded_capture_abort(cap);
        return kCaptureNoScreen;
    }
    screen_pix = (**device).gdPMap;
    pixels = GetGWorldPixMap(cap->image.world);
    if (pixels == NULL || !LockPixels(pixels)) {
        banded_capture_abort(cap);
        return kCapturePixelsUnavailable;
    }

    height = cap->screen_bounds.bottom - cap->screen_bounds.top;
    top = cap->screen_bounds.top
        + (height * (long)cap->next_band) / cap->bands;
    bottom = cap->screen_bounds.top
        + (height * ((long)cap->next_band + 1)) / cap->bands;
    band = cap->screen_bounds;
    band.top = (short)top;
    band.bottom = (short)bottom;

    /* The timing brackets everything a step costs the event loop, not just
       the blit: the port swap and locks are part of the per-band price. */
    Microseconds(&t0);
    GetGWorld(&saved_port, &saved_device);
    SetGWorld(cap->image.world, NULL);
    LockPixels(screen_pix);
    CopyBits((BitMapPtr)*screen_pix,
             GetPortBitMapForCopyBits(cap->image.world),
             &band, &band, srcCopy, NULL);
    UnlockPixels(screen_pix);
    SetGWorld(saved_port, saved_device);
    Microseconds(&t1);
    cap->band_us[cap->next_band] = t1.lo - t0.lo;

    UnlockPixels(pixels);
    ++cap->next_band;
    return cap->next_band < cap->bands ? kCaptureMoreBands : kCaptureOK;
}

void banded_capture_abort(BandedCapture *cap)
{
    if (cap != NULL) {
        capture_image_dispose(&cap->image);
        memset(cap, 0, sizeof *cap);
    }
}

int capture_screen(short depth, CaptureImage *image)
{
    BandedCapture cap;
    int rc;

    memset(image, 0, sizeof *image);
    rc = banded_capture_begin(depth, 1, &cap);
    if (rc != kCaptureOK) {
        return rc;
    }
    rc = banded_capture_step(&cap);
    if (rc != kCaptureOK) {
        return rc;
    }
    *image = cap.image;
    return kCaptureOK;
}

void capture_image_dispose(CaptureImage *image)
{
    if (image != NULL && image->world != NULL) {
        DisposeGWorld(image->world);
        memset(image, 0, sizeof *image);
    }
}
