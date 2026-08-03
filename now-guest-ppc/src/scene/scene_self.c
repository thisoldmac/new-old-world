#include "scene_self.h"

#include <Controls.h>

#include "control_kind.h"
#include "observe.h"
#include <MacWindows.h>
#include <Menus.h>

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
                             const Rect *content, int depth, int *budget,
                             NowObsWalk *refs, WindowRef owner)
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

    /* WHAT IT IS, remembered rather than inferred. GetControlKind is
       the Control Manager's own answer and CarbonLib 1.6 does not export
       it - the link fails. The procID does just as well and this
       application passes one every time it makes a control, so
       control_kind.c records it there and answers here. */
    if (now_scene_add_control(s, window, ctitle,
                              box.top, box.left, box.bottom, box.right,
                              IsControlActive(control) ? 1 : 0,
                              IsControlVisible(control) ? 1 : 0,
                              GetControlValue(control),
                              GetControlMinimum(control),
                              GetControlMaximum(control))) {
        {
            int index = now_scene_last_control(s, window);
            char token[64];

            now_scene_set_control_role(s, window, index,
                                       now_control_role(control));
            if (refs != NULL
                    && now_obs_walk_self_control_ref(
                           refs, (unsigned long)owner,
                           (unsigned long)control, token, sizeof token)) {
                now_scene_set_control_ref(s, window, index, token);
            }
        }
        --*budget;
    }

    if (CountSubControls(control, &count) != noErr) {
        return;
    }
    for (i = 1; i <= count && *budget > 0; ++i) {
        ControlRef child = NULL;

        if (GetIndexedSubControl(control, i, &child) == noErr) {
            add_control_tree(s, window, child, content, depth + 1,
                             budget, refs, owner);
        }
    }
}

/* Every control the Control Manager will admit to, found by asking
   where they are rather than by reading how they are stored.

   The step is the smallest widget this can miss: a checkbox is 12pt
   tall and a scroll arrow 16, so 6 finds both with room. Controls are
   deduplicated by ControlRef, which is the identity the Control Manager
   itself uses. */
static void find_controls_by_probe(NowScene *s, int index, WindowRef window,
                                   const Rect *content, int *budget,
                                   NowObsWalk *refs)
{
    enum { kStep = 10, kSeenMax = 64 };
    ControlRef seen[kSeenMax];
    int seen_count = 0;
    GrafPtr saved = NULL;
    short x, y;
    short w = (short)(content->right - content->left);
    short h = (short)(content->bottom - content->top);

    /* FindControl takes a point in the WINDOW'S local coordinates, so
       the port has to be this window's while we ask. */
    GetPort(&saved);
    SetPortWindowPort(window);

    for (y = 0; y < h && *budget > 0; y = (short)(y + kStep)) {
        for (x = 0; x < w && *budget > 0; x = (short)(x + kStep)) {
            Point pt;
            ControlRef hit = NULL;
            int i;
            int already = 0;

            pt.h = x;
            pt.v = y;
            if (FindControl(pt, window, &hit) == 0 || hit == NULL) {
                continue;
            }
            for (i = 0; i < seen_count; ++i) {
                if (seen[i] == hit) {
                    already = 1;
                    break;
                }
            }
            if (already) {
                continue;
            }
            if (seen_count < kSeenMax) {
                seen[seen_count++] = hit;
            }
            add_control_tree(s, index, hit, content, kSelfMaxDepth,
                             budget, refs, window);
        }
    }

    if (saved != NULL) {
        SetPort(saved);
    }
}

/* --- this application's own menu bar ------------------------------------

   With NOW in front the scene carried NO menu bar at all: the collector
   walks a foreign process's MenuList through a memory reader and self
   never binds, so the mirror drew an empty, inert bar. That is not a
   cosmetic gap - it is why the Application menu fell back to a
   synthesised switcher listing only ourselves, and therefore why a
   person could not switch to the Finder from the mirror.

   `GetMenuBar` hands back THIS application's own MenuList. Its layout is
   documented and the memory is ours: a count in bytes, then pairs of
   {MenuHandle, left}. Reading it gives the exact positions the Menu
   Manager itself uses - which a computed layout could not, and a click
   that misses a title by four pixels opens the wrong menu. */

typedef struct {
    short         last_offset;     /* bytes; last entry is at this offset */
    short         last_right;
    short         mb_res_id;
} NowMenuListHead;

typedef struct {
    MenuHandle menu;
    short      left;
} NowMenuListEntry;

/* One menu and its items, from a MenuHandle we already hold.
 *
 * Pulled out of the menu-bar walk so the SYSTEM menus can go through
 * exactly the same path; a second copy of the item loop is how the two
 * would drift. */
static void add_one_menu(NowScene *s, MenuHandle menu, short left)
{
    Str255 title;
    char   ctitle[64];
    short  count;
    short  i;
    int    index;

    if (menu == NULL) {
        return;
    }
    title[0] = 0;
    GetMenuTitle(menu, title);
    pascal_to_c(title, ctitle, sizeof ctitle);
    index = now_scene_add_menu(s, ctitle, GetMenuID(menu), left);
    if (index < 0) {
        return;
    }
    count = (short)CountMenuItems(menu);
    for (i = 1; i <= count; ++i) {
        Str255 text;
        char   ctext[64];
        short  mark = 0;
        short  cmd = 0;

        text[0] = 0;
        GetMenuItemText(menu, i, text);
        pascal_to_c(text, ctext, sizeof ctext);
        GetItemMark(menu, i, (short *)&mark);
        GetItemCmd(menu, i, (short *)&cmd);
        (void)now_scene_add_menu_item(s, index, ctext, i,
                                      (ctext[0] == '-') ? 1 : 0,
                                      IsMenuItemEnabled(menu, i) ? 1 : 0,
                                      (int)mark, (char)cmd);
    }
}

/* The menus the SYSTEM put in this application's bar, which the walk
 * above cannot see.
 *
 * `GetMenuBar`'s menu list enumerates the LEFT-hand menus, terminated by
 * its `lastMenu` offset. The right-hand ones - Help, and the Application
 * menu that is the app switcher - live past that terminator in a region
 * whose layout is not in the Universal Interfaces on this toolchain, so
 * walking it would mean inventing an offset. Asking for them by id needs
 * no layout at all.
 *
 * The ids are not in a header here either. They are a MEASUREMENT: on
 * 2026-08-03 a scene from this machine carried a menu with id -16489
 * whose items were Hide Mail / Hide Others / Show All / Finder / General
 * Controls / Mail / New Old World, and MirrorKit's hit tester has keyed
 * on that number since. -16490 is the Help menu beside it.
 *
 * WHY THIS MATTERS, and it is not cosmetic: the host draws Apple's own
 * switcher when the scene carries -16489, and SYNTHESISES one from the
 * process list when it does not. Synthesised, it can only ever offer the
 * applications - so Hide, Hide Others and Show All are simply absent,
 * and a person mirroring a machine on which NOW is frontmost gets a
 * switcher that is not the Macintosh's. Michelle called that a
 * regression twice before this was traced to its cause: NOW was not
 * reporting the menu it actually has.
 *
 * A left of 0 is honest: these are right-aligned by the Menu Manager and
 * their position is not ours to state. The host lays them out on the
 * right and never uses the left for them. */
enum {
    kNowSelfApplicationMenuID = -16489,
    kNowSelfHelpMenuID        = -16490
};

static void collect_self_system_menus(NowScene *s)
{
    add_one_menu(s, GetMenuHandle(kNowSelfHelpMenuID), 0);
    add_one_menu(s, GetMenuHandle(kNowSelfApplicationMenuID), 0);
}

static void collect_self_menubar(NowScene *s, int row)
{
    Handle bar = GetMenuBar();
    NowMenuListHead *head;
    short offset;

    if (bar == NULL || *bar == NULL) {
        return;
    }
    if (!now_scene_open_menubar(s, row)) {
        DisposeHandle(bar);
        return;
    }
    head = (NowMenuListHead *)*bar;
    for (offset = 6; offset <= head->last_offset; offset = (short)(offset + 6)) {
        NowMenuListEntry *entry =
            (NowMenuListEntry *)((char *)*bar + offset);

        add_one_menu(s, entry->menu, entry->left);
    }
    /* And the ones the system put there, which the walk above cannot
       reach. Without these the host synthesises a switcher of its own. */
    collect_self_system_menus(s);
    DisposeHandle(bar);
}

void now_scene_collect_self(NowScene *s, int row,
                            const ProcessSerialNumber *psn,
                            NowObsWalk *refs)
{
    WindowRef window = GetWindowList();
    int hops = 0;

    /* AIMED AT OURSELVES, so these windows can be addressed. Without a
       reference a window is a picture: close, move, resize and zoom are
       all refused on it, which is what a person meets first because
       this application's own window is the one always on screen. */
    if (refs != NULL && psn != NULL) {
        now_observe_walk_aim_self(refs, psn);
    }
    /* One menu bar per machine and it is the FRONT process's - the same
       rule the foreign path follows. */
    {
        ProcessSerialNumber front;
        Boolean             same = false;

        if (GetFrontProcess(&front) == noErr && psn != NULL
                && SameProcess(&front, (ProcessSerialNumber *)psn, &same)
                       == noErr && same) {
            collect_self_menubar(s, row);
        }
    }

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
        if (refs != NULL) {
            char token[64];

            if (now_obs_walk_self_window_ref(refs, (unsigned long)window,
                                             token, sizeof token)) {
                now_scene_set_window_ref(s, index, token);
            }
        }

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
                                         &budget, refs, window);
                    }
                }
            }
        } else {
            /* NO ROOT CONTROL, which is what actually happens here: the
               embedding hierarchy exists only once something calls
               CreateRootControl, and this application never does - it
               makes its widgets with NewControl, which puts them in the
               window's own control LIST. So GetRootControl fails, and
               every window mirrored as an empty box with correct chrome,
               which is a very convincing way to look broken.
             *
             * The list itself is unreachable: `ControlRecord` is behind
             * OPAQUE_TOOLBOX_STRUCTS in a Carbon build, so `nextControl`
             * does not exist to follow. Two ways out were rejected before
             * this one. Calling CreateRootControl WOULD adopt the
             * existing controls - and it reshapes the interface it is
             * describing, which is not a read. Reading the record behind
             * the opaque type is a guess at a layout this build
             * deliberately hides.
             *
             * So: ASK. `FindControl` is the public question "what control
             * is under this point", and a grid over the content area asks
             * it often enough to meet every control wider than the step.
             * It is O(points x controls) of rect tests on one window and
             * costs less than the transfer that carries the answer. */
            find_controls_by_probe(s, index, window, &content, &budget,
                                   refs);
        }    }
}
