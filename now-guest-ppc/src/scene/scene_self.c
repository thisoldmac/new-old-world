#include "scene_self.h"

#include <Controls.h>

#include "control_kind.h"
#include "observe.h"
#include "workshop_window.h"
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

typedef struct WorkshopWriterContext {
    NowScene *scene;
    int window;
    short next_number;
} WorkshopWriterContext;

static short workshop_semantic_kind(WorkshopSceneKind kind)
{
    switch (kind) {
    case kWorkshopScenePanel: return kNowSceneSemanticPanel;
    case kWorkshopScenePlacard: return kNowSceneSemanticPlacard;
    case kWorkshopSceneSelectionBand: return kNowSceneSemanticSelectionBand;
    case kWorkshopSceneSeparator: return kNowSceneSemanticSeparator;
    case kWorkshopSceneStaticText: return kNowSceneSemanticStaticText;
    case kWorkshopSceneIcon: return kNowSceneSemanticIcon;
    case kWorkshopScenePicture: return kNowSceneSemanticPicture;
    default: return kNowSceneSemanticUnknown;
    }
}

static void add_workshop_scene_item(void *opaque, WorkshopSceneKind kind,
                                    const char *title, const Rect *rect,
                                    Boolean enabled, Boolean visible)
{
    WorkshopWriterContext *context = (WorkshopWriterContext *)opaque;

    if (!now_scene_add_dialog_item(
            context->scene, context->window, context->next_number++,
            workshop_semantic_kind(kind), title,
            rect->top, rect->left, rect->bottom, rect->right,
            enabled ? 1 : 0, visible ? 1 : 0)) {
        return;
    }
    now_scene_set_dialog_item_provenance(
        context->scene, context->window,
        context->scene->windows[context->window].dialog_item_count - 1,
        "guest-workshop-model");
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
            const char *role = now_control_role(control);

            now_scene_set_control_role(s, window, index, role);
            now_scene_set_control_handle(s, window, index,
                                         (unsigned long)control);
            if (role != NULL && strcmp(role, "popup") == 0) {
                MenuHandle menu = NULL;
                Size got = 0;
                short item = GetControlValue(control);

                /* The Appearance popup owns its menu through control data.
                   GetControlMinimum is only a compatibility hint: the CDEF
                   may keep a private MenuRef without inserting it into the
                   process menu list, in which case GetMenuHandle(min) is
                   NULL and the old code fell back to the numeric item index
                   ("4") instead of the visible title ("8-bit"). Ask the
                   control first, exactly as the Workshop's Cloud popup does,
                   then retain the older menu-list path as a fallback. */
                if (GetControlData(control, kControlEntireControl,
                                   kControlPopupButtonMenuHandleTag,
                                   sizeof menu, (Ptr)&menu, &got) != noErr
                        || got != (Size)sizeof menu) {
                    menu = NULL;
                }
                if (menu == NULL) {
                    menu = GetMenuHandle(GetControlMinimum(control));
                }

                if (menu != NULL && item > 0
                    && item <= CountMenuItems(menu)) {
                    Str255 value;
                    char cvalue[64];

                    value[0] = 0;
                    GetMenuItemText(menu, item, value);
                    pascal_to_c(value, cvalue, sizeof cvalue);
                    now_scene_set_control_semantic_value(s, window, index,
                                                         cvalue);
                }
            }
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

   `LMGetMenuList` hands back THIS application's live MenuList. Its layout
   is measured by axmenu.c: a count in bytes, then pairs of {MenuHandle,
   left}. Reading the live list gives the exact positions the Menu Manager
   itself uses - including Apple, Help, and the right-aligned Application
   menu. `GetMenuBar` is not equivalent here: its copy omitted those three
   system-owned entries on Mac OS 9.1, which left Apple inert and moved both
   ends of the bar in the mirror. */

typedef struct {
    short         last_offset;     /* bytes; last entry is at this offset */
    short         last_right;
    short         mb_res_id;
} NowMenuListHead;

typedef struct {
    MenuHandle menu;
    short      left;
} NowMenuListEntry;

/* Universal Interfaces' LMGetMenuList accessor reads this low-memory
   global, but deliberately hides the accessor from CarbonLib builds. NOW's
   PPC guest runs only on classic Mac OS 8.6-9.2.2, where the low-memory
   globals are real on metal as well as in an emulator. Read the one address
   the platform header assigns to MenuList; this is not a QEMU interface.

   Keep the address beside the only read. AXPeek publishes the same handle
   for foreign observation, and axmenu.c bounds every later structure walk. */
enum { kNowMenuListLowMemoryAddress = 0x0A1C };

static Handle current_live_menu_list(void)
{
    return *(Handle *)kNowMenuListLowMemoryAddress;
}

/* One menu and its items, from a MenuHandle we already hold.
 *
 * Pulled out of the menu-bar walk so the SYSTEM menus can go through
 * exactly the same path; a second copy of the item loop is how the two
 * would drift. */
static void add_one_menu(NowScene *s, MenuHandle menu, MenuRef items,
                         short left)
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
    count = (short)CountMenuItems(items);
    for (i = 1; i <= count; ++i) {
        Str255 text;
        char   ctext[64];
        short  mark = 0;
        short  cmd = 0;

        text[0] = 0;
        GetMenuItemText(items, i, text);
        pascal_to_c(text, ctext, sizeof ctext);
        GetItemMark(items, i, (short *)&mark);
        GetItemCmd(items, i, (short *)&cmd);
        (void)now_scene_add_menu_item(s, index, ctext, i,
                                      (ctext[0] == '-') ? 1 : 0,
                                      IsMenuItemEnabled(items, i) ? 1 : 0,
                                      (int)mark, (char)cmd);
    }
}

/* Carbon's live low-memory MenuList has the authoritative identity and
   geometry for every title, but on Mac OS 9 its Apple entry is a shell
   with no items. The actual system-owned menu is attached to the
   corresponding item in Carbon's root menu. Match the submenu by menu ID:
   title text cannot identify the Apple glyph, and position is geometry,
   not identity. */
static MenuRef root_items_for(MenuRef root, MenuHandle entry)
{
    MenuItemIndex i;
    ItemCount     count;
    MenuID        wanted;
    MenuRef       installed;

    if (root == NULL || entry == NULL) {
        return entry;
    }
    wanted = GetMenuID(entry);
    count = CountMenuItems(root);

    for (i = 1; i <= count; ++i) {
        MenuRef child = NULL;
        MenuID  attached = 0;

        if (GetMenuItemHierarchicalID(root, i, &attached) == noErr
                && attached == wanted) {
            if (GetMenuItemHierarchicalMenu(root, i, &child) == noErr
                    && child != NULL) {
                return child;
            }
            installed = GetMenuHandle(attached);
            if (installed != NULL && CountMenuItems(installed) > 0) {
                return installed;
            }
        } else if (GetMenuItemHierarchicalMenu(root, i, &child) == noErr
                       && child != NULL && GetMenuID(child) == wanted) {
            return child;
        }
    }
    /* The live MenuList handle is frequently also the installed handle.
       For system menus that handle can contain the right row count and
       still hold only blank shell text, so it must not outrank an attached
       root submenu with the same ID. Ordinary application menus have no
       such root child and arrive here unchanged. */
    installed = GetMenuHandle(wanted);
    if (installed != NULL && CountMenuItems(installed) > 0) {
        return installed;
    }
    return entry;
}

static void collect_self_menubar(NowScene *s, int row)
{
    /* This is the same source AXPeek publishes for a foreign observer. The
       handle is owned by the Menu Manager; unlike GetMenuBar's copy it must
       not be disposed here. */
    Handle bar = current_live_menu_list();
    MenuRef root;
    NowMenuListHead *head;
    short offset;

    if (bar == NULL || *bar == NULL) {
        return;
    }
    if (!now_scene_open_menubar(s, row)) {
        return;
    }
    head = (NowMenuListHead *)*bar;
    root = AcquireRootMenu();
    for (offset = 6; offset <= head->last_offset; offset = (short)(offset + 6)) {
        NowMenuListEntry *entry =
            (NowMenuListEntry *)((char *)*bar + offset);
        /* Count is not completeness. On OS 9 the system Apple shell can
           carry the correct number of blank rows. Resolve every live entry
           through Carbon's attached root submenu by menu ID; normal menus
           simply fall back to their installed handle. */
        MenuRef items = root_items_for(root, entry->menu);
        add_one_menu(s, entry->menu, items, entry->left);
    }
    if (root != NULL) {
        (void)ReleaseMenu(root);
    }
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
        now_scene_set_window_addr(s, index, (unsigned long)window);
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
        }
        if (workshop_is(window)) {
            WorkshopWriterContext context = { s, index, 1 };
            WorkshopSceneWriter writer = { &context,
                                           add_workshop_scene_item };

            workshop_describe_scene(&writer);
        }
    }
}
