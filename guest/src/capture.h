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
    kCaptureMoreBands = 1,
    kCaptureInvalidDepth = -1,
    kCaptureNoScreen = -2,
    kCaptureNoMemory = -3,
    kCapturePixelsUnavailable = -4
};

enum { kCaptureMaxBands = 32 };

/* Incremental screen capture: the screen is blitted into the GWorld one
   horizontal band per step() call, so a capture can be pumped from the
   event loop alongside wire.c's service_transfer — that is what lets a
   fresh frame be captured while the previous one is still going out.
   Each band's cost (the whole step: port swap, locks, CopyBits) is
   recorded in microseconds.

   begin() allocates the GWorld and blits nothing. step() blits the next
   band and returns kCaptureMoreBands while bands remain, kCaptureOK when
   the image is complete (the caller then owns .image), or a negative
   error (the state is already cleaned up). abort() disposes a capture
   that will not be finished. */
/* A run of destination rows to capture. For a decimated (interlaced)
   capture the coordinates are FIELD rows; the source rows they sample are
   row * row_scale + row_phase. */
typedef struct {
    short row, n_rows;
} CaptureSpan;

typedef struct {
    CaptureImage image;
    Rect screen_bounds;
    short row_scale;                  /* 1 = every row, 2 = every other */
    short row_phase;
    CaptureSpan spans[kCaptureMaxBands];
    short n_spans;
    short cur_span;
    short row_in_span;
    short steps;
    unsigned long band_us[kCaptureMaxBands];
} BandedCapture;

Boolean capture_depth_is_supported(short depth);

int banded_capture_begin(short depth, short bands, BandedCapture *cap);

/* Capture only `spans` (destination rows), each step blitting one bounded
   bite. row_scale 2 captures a field: destination row j samples screen
   row j * 2 + row_phase via CopyBits' point-sampling decimation, so a
   field costs one blit per span, not one per row. The GWorld is sized
   screen_height / row_scale. */
int banded_capture_begin_spans(short depth, const CaptureSpan *spans,
                               short n_spans, short row_scale,
                               short row_phase, BandedCapture *cap);
int banded_capture_step(BandedCapture *cap);
void banded_capture_abort(BandedCapture *cap);

/* Captures the entire main screen into a fresh GWorld at `depth` (QuickDraw
   converts during the blit). Caller owns the image; dispose when done. */
int capture_screen(short depth, CaptureImage *image);

void capture_image_dispose(CaptureImage *image);

#endif
