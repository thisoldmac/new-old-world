#ifndef NOW_CLOUD_NAV_H
#define NOW_CLOUD_NAV_H

/* The drive browser's Back/Forward history: browser-history semantics
   over colon paths, and nothing else. Toolbox-free on purpose — this
   is the half of the navigation worth proving with the host cc
   (cloud_nav_test.c; scripts/test-native), the way cloud_layout.c and
   files_path_label.c are split.

   The caller keeps the current path (cloud_drive_view.c's
   g_drive_path); this records only where it has been. A plain
   navigation — descending into a folder, Up, a breadcrumb jump —
   pushes the path being LEFT onto the back stack and forfeits the
   forward stack, exactly as a web browser does. Back moves the current
   path onto the forward stack and pops the destination; Forward is the
   mirror. Both stacks are bounded at kCloudNavDepth: a back stack past
   the bound drops its OLDEST entry, so the last sixteen steps are
   always retraceable and memory never grows. */

enum {
    kCloudNavDepth = 16,
    kCloudNavPathCap = 224            /* matches g_drive_path */
};

typedef struct {
    char back[kCloudNavDepth][kCloudNavPathCap];
    int back_count;
    char fwd[kCloudNavDepth][kCloudNavPathCap];
    int fwd_count;
} CloudNav;

/* Empty both stacks (a new service, or the page's first visit). */
void cloud_nav_reset(CloudNav *nav);

/* A plain navigation is leaving `from`: push it for Back, forfeit
   Forward. `from` may be "" (the share root is a real place). */
void cloud_nav_visit(CloudNav *nav, const char *from);

/* Back: writes the destination into `out` (nul-terminated, cap > 0)
   and records `current` for Forward. Returns 1, or 0 when there is no
   history — `out` is untouched then, so callers need no scratch guard.
   Forward is the exact mirror. */
int cloud_nav_back(CloudNav *nav, const char *current, char *out, long cap);
int cloud_nav_forward(CloudNav *nav, const char *current,
                      char *out, long cap);

/* What the toolbar buttons dim by. */
int cloud_nav_can_back(const CloudNav *nav);
int cloud_nav_can_forward(const CloudNav *nav);

#endif /* NOW_CLOUD_NAV_H */
