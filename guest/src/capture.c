#include "capture.h"

#include <string.h>

Boolean capture_depth_is_supported(short depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

int banded_capture_begin_spans(short depth, const CaptureSpan *spans,
                               short n_spans, short row_scale,
                               short row_phase, BandedCapture *cap)
{
    GDHandle device;
    PixMapHandle screen_pix;
    Rect screen_bounds;
    Rect world_bounds;
    GWorldPtr world = NULL;
    PixMapHandle pixels;
    OSErr err;
    long height, dest_height;
    short i;

    memset(cap, 0, sizeof *cap);
    if (!capture_depth_is_supported(depth) || n_spans < 1
        || n_spans > kCaptureMaxBands
        || (row_scale != 1 && row_scale != 2)) {
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
    dest_height = (height - row_phase + row_scale - 1) / row_scale;

    for (i = 0; i < n_spans; ++i) {
        if (spans[i].row < 0 || spans[i].n_rows < 1
            || spans[i].row + spans[i].n_rows > dest_height) {
            return kCaptureInvalidDepth;
        }
    }

    world_bounds = screen_bounds;
    world_bounds.bottom = (short)(world_bounds.top + dest_height);
    err = NewGWorld(&world, depth, &world_bounds, NULL, NULL, useTempMem);
    if (err != noErr || world == NULL) {
        return kCaptureNoMemory;
    }
    pixels = GetGWorldPixMap(world);
    if (pixels == NULL) {
        DisposeGWorld(world);
        return kCapturePixelsUnavailable;
    }

    cap->image.world = world;
    cap->image.bounds = world_bounds;
    cap->image.depth = depth;
    cap->image.row_bytes = (short)((**pixels).rowBytes & 0x3FFF);
    cap->image.pixel_bytes = (long)cap->image.row_bytes * dest_height;
    cap->screen_bounds = screen_bounds;
    cap->row_scale = row_scale;
    cap->row_phase = row_phase;
    memcpy(cap->spans, spans, (size_t)n_spans * sizeof *spans);
    cap->n_spans = n_spans;
    cap->cur_span = 0;
    cap->row_in_span = 0;
    cap->steps = 0;
    return kCaptureOK;
}

int banded_capture_begin(short depth, short bands, BandedCapture *cap)
{
    GDHandle device;
    CaptureSpan spans[kCaptureMaxBands];
    long height;
    short i;

    device = GetMainDevice();
    if (device == NULL || (**device).gdPMap == NULL) {
        return kCaptureNoScreen;
    }
    height = (**(**device).gdPMap).bounds.bottom
        - (**(**device).gdPMap).bounds.top;
    if (bands < 1) {
        bands = 1;
    }
    if (bands > kCaptureMaxBands) {
        bands = kCaptureMaxBands;
    }
    if ((long)bands > height) {
        bands = (short)height;
    }
    for (i = 0; i < bands; ++i) {
        long top = (height * (long)i) / bands;
        long bottom = (height * ((long)i + 1)) / bands;

        spans[i].row = (short)top;
        spans[i].n_rows = (short)(bottom - top);
    }
    return banded_capture_begin_spans(depth, spans, bands, 1, 0, cap);
}

/* At most this many destination rows per step, so a huge span still pumps
   in event-loop-sized bites. */
enum { kCaptureStepRows = 80 };

int banded_capture_step(BandedCapture *cap)
{
    GDHandle device;
    PixMapHandle screen_pix;
    PixMapHandle pixels;
    CGrafPtr saved_port;
    GDHandle saved_device;
    Rect src, dst;
    const CaptureSpan *span;
    long take, top;
    UnsignedWide t0, t1;

    if (cap->image.world == NULL) {
        return kCapturePixelsUnavailable;
    }
    if (cap->cur_span >= cap->n_spans) {
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

    span = &cap->spans[cap->cur_span];
    top = span->row + cap->row_in_span;
    take = span->n_rows - cap->row_in_span;
    if (take > kCaptureStepRows) {
        take = kCaptureStepRows;
    }
    dst = cap->screen_bounds;
    dst.top = (short)(cap->screen_bounds.top + top);
    dst.bottom = (short)(dst.top + take);
    src = cap->screen_bounds;
    src.top = (short)(cap->screen_bounds.top
                      + top * cap->row_scale + cap->row_phase);
    src.bottom = (short)(src.top + (take - 1) * cap->row_scale + 1);

    /* The timing brackets everything a step costs the event loop, not just
       the blit: the port swap and locks are part of the per-band price.
       With row_scale 2 the CopyBits decimates: dst is half src's height,
       and QuickDraw's point sampling picks exactly our parity's rows. */
    Microseconds(&t0);
    GetGWorld(&saved_port, &saved_device);
    SetGWorld(cap->image.world, NULL);
    LockPixels(screen_pix);
    CopyBits((BitMapPtr)*screen_pix,
             GetPortBitMapForCopyBits(cap->image.world),
             &src, &dst, srcCopy, NULL);
    UnlockPixels(screen_pix);
    SetGWorld(saved_port, saved_device);
    Microseconds(&t1);
    if (cap->steps < kCaptureMaxBands) {
        cap->band_us[cap->steps] = t1.lo - t0.lo;
    }
    ++cap->steps;

    UnlockPixels(pixels);
    cap->row_in_span = (short)(cap->row_in_span + take);
    if (cap->row_in_span >= span->n_rows) {
        ++cap->cur_span;
        cap->row_in_span = 0;
    }
    return cap->cur_span < cap->n_spans ? kCaptureMoreBands : kCaptureOK;
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
    /* Steps are bounded to kCaptureStepRows, so one span takes several -
       treating kCaptureMoreBands as failure here was the "capture ended
       without a begin" regression. */
    do {
        rc = banded_capture_step(&cap);
    } while (rc == kCaptureMoreBands);
    if (rc != kCaptureOK) {
        return rc;
    }
    *image = cap.image;
    return kCaptureOK;
}

int capture_screen_rect(short depth, const Rect *screen_rect,
                        CaptureImage *image)
{
    GDHandle device;
    PixMapHandle screen_pix;
    PixMapHandle pixels;
    GWorldPtr world = NULL;
    Rect screen_bounds;
    Rect clip;
    Rect world_bounds;
    CGrafPtr saved_port;
    GDHandle saved_device;
    RGBColor black = { 0, 0, 0 };
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    OSErr err;
    long w, h;

    memset(image, 0, sizeof *image);
    if (!capture_depth_is_supported(depth)) {
        return kCaptureInvalidDepth;
    }
    device = GetMainDevice();
    if (device == NULL || (**device).gdPMap == NULL) {
        return kCaptureNoScreen;
    }
    screen_pix = (**device).gdPMap;
    screen_bounds = (**screen_pix).bounds;

    /* Clamp the requested rect to the screen: a window may extend past an
       edge, and CopyBits must not read outside the framebuffer. */
    clip = *screen_rect;
    if (clip.left < screen_bounds.left) {
        clip.left = screen_bounds.left;
    }
    if (clip.top < screen_bounds.top) {
        clip.top = screen_bounds.top;
    }
    if (clip.right > screen_bounds.right) {
        clip.right = screen_bounds.right;
    }
    if (clip.bottom > screen_bounds.bottom) {
        clip.bottom = screen_bounds.bottom;
    }
    w = clip.right - clip.left;
    h = clip.bottom - clip.top;
    if (w < 1 || h < 1) {
        return kCaptureNoScreen;      /* wholly off-screen */
    }

    SetRect(&world_bounds, 0, 0, (short)w, (short)h);
    err = NewGWorld(&world, depth, &world_bounds, NULL, NULL, useTempMem);
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
    RGBForeColor(&black);
    RGBBackColor(&white);
    LockPixels(screen_pix);
    CopyBits((BitMapPtr)*screen_pix, GetPortBitMapForCopyBits(world),
             &clip, &world_bounds, srcCopy, NULL);
    UnlockPixels(screen_pix);
    SetGWorld(saved_port, saved_device);
    UnlockPixels(pixels);

    image->world = world;
    image->bounds = world_bounds;
    image->depth = depth;
    image->row_bytes = (short)((**pixels).rowBytes & 0x3FFF);
    image->pixel_bytes = (long)image->row_bytes * h;
    return kCaptureOK;
}

void capture_image_dispose(CaptureImage *image)
{
    if (image != NULL && image->world != NULL) {
        DisposeGWorld(image->world);
        memset(image, 0, sizeof *image);
    }
}
