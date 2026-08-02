#ifndef NOW_CLOUD_PHOTO_SIZE_H
#define NOW_CLOUD_PHOTO_SIZE_H

/* Pure fit-box arithmetic for the Photos Size popup's labels
   (docs/icloud.md: "a guest that wants to SHOW the exact resolution a
   photo will render at computes it itself from the entry's own
   width/height (CloudListing) and the chosen box"). Toolbox-free so
   the host cc can test it (cloud_photo_size_test.c) the way every
   other decidable half of this page is.

   Deliberately a SEPARATE function from cloud_preview.c's
   cloud_preview_fit: that one fills a preview PANE and may enlarge a
   small photo to cover it (a preview is drawn state, not a file).
   This one labels a DOWNLOAD, and the contract's fitN tokens never
   upscale — "a photo smaller than the box shows its own size and
   sends the token anyway" (docs/icloud.md) — so the two must not
   share an implementation even though the shape looks similar. */

void cloud_photo_fit(long orig_w, long orig_h, long box_w, long box_h,
                     long *out_w, long *out_h);

#endif /* NOW_CLOUD_PHOTO_SIZE_H */
