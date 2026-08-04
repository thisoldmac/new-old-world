#ifndef NOW_MIRROR_LAYOUT_H
#define NOW_MIRROR_LAYOUT_H

#include "mirror_facts.h"

enum {
    kMirrorMargin = 14,
    kMirrorHeadingHeight = 17,
    kMirrorRowHeight = 16,
    kMirrorLabelWidth = 116,
    kMirrorSectionGap = 12,
    kMirrorLifecycleRows = 4,
    kMirrorNoteLines = 2
};

typedef struct MirrorLayout {
    Rect heading;
    Rect lifecycle_rows[kMirrorLifecycleRows];
    Rect plane_heading;
    Rect plane_rows[kMirrorPlaneCount];
    Rect note[kMirrorNoteLines];
} MirrorLayout;

void now_mirror_layout_compute(const Rect *body, MirrorLayout *out);
void now_mirror_lifecycle_text(const MirrorFacts *facts, char *out, long cap);
const char *now_mirror_plane_name(MirrorPlane plane);
const char *now_mirror_plane_purpose(MirrorPlane plane);
void now_mirror_plane_value(const MirrorFacts *facts, MirrorPlane plane,
                            char *out, long cap);
const char *now_mirror_note(int line);
void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap);

#endif /* NOW_MIRROR_LAYOUT_H */
