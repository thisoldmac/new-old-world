#include "scene_self.h"

#include <Controls.h>
#include <MacWindows.h>

#include <string.h>

/* **This Mac describing its own application, which it alone can do.**
 *
 * Every other process in the scene is read by WALKING it: an anchor is
 * validated, a foreign A5 world is bound, and the Window Manager's
 * structures are read at the offsets a classic application has. NOW is
 * Carbon, so its own records are NOT at those offsets, and
 * `scene_collect.c` therefore skips itself. That was correct and it left
 * a hole a person sees immediately: NOW's own window - usually the
 * largest thing on the screen - mirrored as an empty white box with no
 * close box and no content, while every foreign window drew properly.
 *
 * The hole was never about a missing capability. An application does not
 * need to walk memory to know its own interface; it asks the Toolbox,
 * which is what the Toolbox is for. `GetNextWindow`, `GetRootControl`
 * and the embedding hierarchy answer directly, in this process, with no
 * anchor, no validation and no foreign read - so this path is exempt
 * from the passive-observation rule by construction rather than by
 * exception. It cannot wedge another application because it never
 * touches one.
 *
 * WHAT IT DELIBERATELY DOES NOT DO is mint act references. A mirror
 * clicking NOW's own window would be the host driving its own guest
 * through a loop, which is a confusion rather than a feature; the rows
 * carry no `ref`, so the act plane refuses them by name and the drawing
 * is honest about being a picture.
 */

enum {
    /* An embedding hierarchy deeper or wider than this is not a window
       this scene can carry, and a prefix is what stands. */
    kSelfMaxControls = 64,
    kSelfMaxDepth = 6,
    kSelfMaxWindows = 16
};

static void pascal_to_c(ConstStr255Param src, char *dst, size_t cap)
{
    size_t len = (src == NULL) ? 0 : (size_t)src[0];

    if (cap == 0) {
        return;
    }
    if (len > cap - 1) {
        len = cap - 1;
    }
    if (len > 0) {
        memcpy(dst, src + 1, len);
    }
    dst[len] = '\0';
}

/* One control and everything embedded in it. Depth-first, because that
   is the order they are DRAWN in and therefore the order a hit test
   wants: a control that embeds another is behind it. */
static void add_control_tree(NowScene *s, int window, ControlRef control,
                             const Rect *content, int depth, int *budget)
{
    Rect box;
    Str255 title;
    char ctitle[64];
    UInt16 count = 0;
    UInt16 i;

    if (control == NULL || depth > kSelfMaxDepth || *budget <= 0) {
        return;
    }

    GetControlBounds(control, &box);
    title[0] = 0;
    GetControlTitle(control, title);
    pascal_to_c(title, ctitle, sizeof ctitle);

    /* CONTENT-RELATIVE, which is what IR v1 says a control's rect is.
       The Toolbox answers in the window's own local coordinates and the
       content origin is local (0,0), so this is already right - the
       subtraction is stated rather than assumed because getting this
       backwards is precisely what made every click miss by a title
       bar. */
    (void)content;

    if (now_scene_add_control(s, window, ctitle,
                              box.top, box.left, box.bottom, box.right,
                              IsControlActive(control) ? 1 : 0,
                              IsControlVisible(control) ? 1 : 0,
                              GetControlValue(control),
                              GetControlMinimum(control),
                              GetControlMaximum(control))) {
        --*budget;
    }

    if (CountSubControls(control, &count) != noErr) {
        return;
    }
    for (i = 1; i <= count && *budget > 0; ++i) {
        ControlRef child = NULL;

        if (GetIndexedSubControl(control, i, &child) == noErr) {
            add_control_tree(s, window, child, content, depth + 1, budget);
        }
    }
}

void now_scene_collect_self(NowScene *s, int row)
{
    WindowRef window = GetWindowList();
    int hops = 0;

    for (; window != NULL && hops < kSelfMaxWindows;
         window = GetNextWindow(window), ++hops) {
        Rect structure;
        Rect content;
        Str255 title;
        char ctitle[64];
        ControlRef root = NULL;
        int budget = kSelfMaxControls;
        int index;

        /* The STRUCTURE region, which is the box a person sees and the
           box IR v1 carries - the same choice peek_read makes for every
           other process, so the two agree. */
        if (GetWindowBounds(window, kWindowStructureRgn, &structure)
                != noErr) {
            continue;
        }
        if (GetWindowBounds(window, kWindowContentRgn, &content) != noErr) {
            content = structure;
        }
        title[0] = 0;
        GetWTitle(window, title);
        pascal_to_c(title, ctitle, sizeof ctitle);

        if (!now_scene_add_window(s, row, ctitle,
                                  structure.top, structure.left,
                                  structure.bottom, structure.right,
                                  IsWindowVisible(window) ? 1 : 0)) {
            continue;
        }
        index = now_scene_last_window(s);
        now_scene_set_window_kind(s, index, (short)GetWindowKind(window));

        /* Declared even when the walk finds none: "this window has no
           controls" and "nobody looked" are different facts and the
           scene has room to say which. */
        (void)now_scene_open_controls(s, index);
        if (GetRootControl(window, &root) == noErr && root != NULL) {
            UInt16 count = 0;
            UInt16 i;

            /* The ROOT itself is not a control a person clicks - it is
               the window's own embedder, filling the content area - so
               its children are what the scene carries. */
            if (CountSubControls(root, &count) == noErr) {
                for (i = 1; i <= count && budget > 0; ++i) {
                    ControlRef child = NULL;

                    if (GetIndexedSubControl(root, i, &child) == noErr) {
                        add_control_tree(s, index, child, &content, 0,
                                         &budget);
                    }
                }
            }
        }
    }
}
