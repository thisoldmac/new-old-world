#include "cloud_photo_size.h"

/* See cloud_photo_size.h: aspect-preserving, never-upscale fit-box
   arithmetic, the guest's own mirror of the host's fitN scaling
   (PhotosCloudProvider's "never enlarge" rule in CloudServices.swift)
   run on the entry's width/height the guest already has. */
void cloud_photo_fit(long orig_w, long orig_h, long box_w, long box_h,
                     long *out_w, long *out_h)
{
    long w, h;

    if (orig_w < 1 || orig_h < 1 || box_w < 1 || box_h < 1) {
        *out_w = orig_w > 0 ? orig_w : 0;
        *out_h = orig_h > 0 ? orig_h : 0;
        return;
    }
    if (orig_w <= box_w && orig_h <= box_h) {
        /* Already fits: the fitN token still goes out, but the box
           does not enlarge a smaller original. */
        *out_w = orig_w;
        *out_h = orig_h;
        return;
    }
    w = box_w;
    h = orig_h * box_w / orig_w;
    if (h > box_h) {
        h = box_h;
        w = orig_w * box_h / orig_h;
    }
    if (w < 1) {
        w = 1;
    }
    if (h < 1) {
        h = 1;
    }
    *out_w = w;
    *out_h = h;
}
