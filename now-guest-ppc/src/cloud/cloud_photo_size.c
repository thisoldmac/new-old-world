#include "cloud_photo_size.h"

/* See cloud_photo_size.h: aspect-preserving, never-upscale longest-edge
   arithmetic, the guest's own mirror of the host's longN scaling
   (PhotosCloudProvider.scaled in CloudServices.swift, truncating
   integer division on the same numbers) run on the entry's width/height
   the guest already has. Both sides truncate, so the label the popup
   shows and the file that lands cannot differ by a pixel. */
void cloud_photo_long_edge(long orig_w, long orig_h, long edge,
                           long *out_w, long *out_h)
{
    long longer;

    if (orig_w < 1 || orig_h < 1 || edge < 1) {
        *out_w = orig_w > 0 ? orig_w : 0;
        *out_h = orig_h > 0 ? orig_h : 0;
        return;
    }
    longer = orig_w > orig_h ? orig_w : orig_h;
    if (longer <= edge) {
        /* Already shorter than the stop: the longN token still goes
           out, but a stop does not enlarge a smaller original. */
        *out_w = orig_w;
        *out_h = orig_h;
        return;
    }
    if (orig_w >= orig_h) {
        *out_w = edge;
        *out_h = orig_h * edge / orig_w;
        if (*out_h < 1) {
            *out_h = 1;
        }
        return;
    }
    *out_h = edge;
    *out_w = orig_w * edge / orig_h;
    if (*out_w < 1) {
        *out_w = 1;
    }
}
