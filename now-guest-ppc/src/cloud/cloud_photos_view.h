#ifndef NOW_CLOUD_PHOTOS_VIEW_H
#define NOW_CLOUD_PHOTOS_VIEW_H

#include "cloud_view.h"

/* Photos: the generic listing+card render, plus a preview of the
   selected photo replacing the card — list and preview-on-select, no
   thumbnail grid (deferred indefinitely; docs/icloud.md says why).
   Selecting a row asks cloud.preview with the pane's dimensions and
   the screen's actual depth; the host decodes, resizes and dithers,
   and this view CopyBits the arrived rows from its one offscreen
   GWorld. Exactly one preview lives in memory at a time, evicted on
   every selection change — the 6 MB partition holds a photo, not a
   library. */

const CloudViewOps *cloud_photos_view_ops(void);

/* Owned by this view but called by the shell, the drive view's
   pattern: the window (and every control in it) outlives nothing, so
   dispose only drops this view's own offscreen world and hook. */
void cloud_photos_view_dispose(void);

#endif /* NOW_CLOUD_PHOTOS_VIEW_H */
