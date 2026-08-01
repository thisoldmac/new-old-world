#include "capture_region_args.h"

#include <string.h>
#include <stdio.h>

static int depth_is_supported(long depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

int now_capture_region_parse(long left, long top, long right, long bottom,
                             long depth_in, CaptureRegionArgs *out,
                             char *msg, long cap)
{
    long w, h;

    memset(out, 0, sizeof *out);
    if (right <= left || bottom <= top) {
        snprintf(msg, (size_t)cap,
                 "capture.region: rect is empty or inverted");
        return 0;
    }
    w = right - left;
    h = bottom - top;
    if (w > kCaptureRegionMaxDim || h > kCaptureRegionMaxDim) {
        snprintf(msg, (size_t)cap,
                 "capture.region: %ld x %ld exceeds the %d px side limit",
                 w, h, kCaptureRegionMaxDim);
        return 0;
    }
    if (depth_in != 0 && !depth_is_supported(depth_in)) {
        snprintf(msg, (size_t)cap,
                 "capture.region: depth must be 1, 2, 4, 8, 16 or 32");
        return 0;
    }
    out->left = left;
    out->top = top;
    out->right = right;
    out->bottom = bottom;
    out->depth = (short)depth_in;
    return 1;
}
