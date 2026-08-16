#ifndef NOW_DEVELOPMENT_LAYOUT_H
#define NOW_DEVELOPMENT_LAYOUT_H

/* Pure rectangle arithmetic for the Development page - no Toolbox call
   lives here, so the host cc compiles it for the native test, the
   pattern processes_layout.c set. */

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

enum {
    kDevMargin = 12,
    kDevPaneGap = 10,
    /* The list narrows on a 640x480 screen so the detail column keeps
       enough width for a toolchain pin; the threshold is BODY width,
       not window width, the way the Processes page states it. */
    kDevListWide = 210,
    kDevListNarrow = 176,
    kDevListNarrowBelow = 520,
    kDevLineHeight = 15,
    kDevTitleHeight = 18,
    kDevButtonHeight = 20,
    kDevButtonWidthProjects = 190,
    kDevButtonWidthToolchain = 170,
    kDevButtonWidthCancel = 100,
    kDevButtonWidthBuild = 76,
    kDevButtonWidthRun = 64,
    /* Three settled jobs on the page; the ring remembers eight, and the
       rest are scrolled off rather than summarised, because a count of
       forgotten builds is not something anyone acts on. */
    kDevJobRowsShown = 3,
    kDevJobsBoxHeight = 88
};

typedef struct DevelopmentLayout {
    Rect list;                /* the projects Data Browser */
    Rect projects_choose;     /* "Choose Projects Folder...", under it */
    Rect detail;              /* the selected project's pane */
    Rect title_line;
    Rect id_line;
    Rect target_line;
    Rect configuration_line;
    Rect toolchain_pin_line;  /* what the PROJECT pins */
    Rect product_line;
    Rect toolchain_status;    /* what THIS Mac has registered */
    Rect register_toolchain;
    Rect build_btn;
    Rect run_btn;
    Rect jobs_box;
    Rect jobs_status;
    Rect job_rows[kDevJobRowsShown];
    Rect cancel_job;
} DevelopmentLayout;

void development_layout_compute(const Rect *body, DevelopmentLayout *out);

#endif
