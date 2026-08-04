#ifndef NOW_CLOUD_PHOTO_SIZE_H
#define NOW_CLOUD_PHOTO_SIZE_H

/* Pure longest-edge arithmetic for the Photos Size popup's labels
   (docs/icloud.md: "a guest that wants to SHOW the exact resolution a
   photo will render at computes it itself from the entry's own
   width/height (CloudListing) and the chosen long edge"). Toolbox-free
   so the host cc can test it (cloud_photo_size_test.c) the way every
   other decidable half of this page is.

   LONGEST EDGE, not a box, and the difference is the whole point: the
   contract's longN tokens scale a photo so its LONGER dimension is
   exactly N, whichever way up the photo is. A portrait 3024x4032 at
   long640 is 480x640. The fit-box arithmetic this replaced answered
   360x480 for that photo — it gave the portrait the SHORT edge's
   number — which is the defect a person met on metal (2026-08-02).

   Deliberately a SEPARATE function from cloud_preview.c's
   cloud_preview_fit: that one fills a preview PANE, a rectangle with
   two independent bounds, and may enlarge a small photo to cover it (a
   preview is drawn state, not a file). This one labels a DOWNLOAD,
   takes ONE number, and never upscales — "a photo smaller than the
   stop shows its own size and sends the token anyway" — so the two
   must not share an implementation even though the shape looks
   similar. */

void cloud_photo_long_edge(long orig_w, long orig_h, long edge,
                           long *out_w, long *out_h);

#endif /* NOW_CLOUD_PHOTO_SIZE_H */
