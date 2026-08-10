#ifndef NOW_DEVELOPMENT_LAYOUT_H
#define NOW_DEVELOPMENT_LAYOUT_H

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
#endif

typedef struct DevelopmentLayout {
    Rect projects_box;
    Rect projects_path;
    Rect projects_choose;
    Rect toolchain_box;
    Rect toolchain_status;
    Rect register_toolchain;
    Rect jobs_box;
    Rect jobs_status;
    Rect cancel_job;
} DevelopmentLayout;

void development_layout_compute(const Rect *body, DevelopmentLayout *out);

#endif
