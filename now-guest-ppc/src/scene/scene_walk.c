/* Walk to scene. See scene_walk.h for why this is a separate,
   Toolbox-free file. */

#include "scene_walk.h"

#include <string.h>

#include "axmenu.h"
#include "axtext.h"

/* The one file that sees both a scene's reference buffer and the
   reference layer's own token size, pinned at compile time exactly as
   scene_collect.c pins the anchor verdicts. A scene buffer shorter than
   a token would not overflow anything - copy_ref refuses a reference
   that does not fit - it would silently drop EVERY reference in every
   scene, and the symptom would be "the guest stopped minting". */
/* The casts are not decoration: the two constants belong to different
   anonymous enums, and Retro68's GCC treats comparing them as an error
   under -Werror=enum-compare. */
typedef char now_scene_ref_pin[
    ((int)kNowSceneRefMax >= (int)kNowObsTokenMax) ? 1 : -1];

enum {
    /* windowKind for a Dialog Manager window. Inside Macintosh:
       Macintosh Toolbox Essentials defines dialogKind = 2, and it is the
       same discriminator IR v1's `windows[].kind` is read for on the
       consuming side. */
    kNowSceneDialogKind = 2,

    /* A menu item's cmdChar below this is a MARKER, not a command key -
       the Menu Manager overloads the byte for hierarchical menus, script
       codes and reduced icons. Reporting one as a keyboard shortcut
       would put a control character in front of a person. */
    kNowSceneFirstCmdChar = 0x20
};

/* A separator is the Menu Manager's own convention: an item whose text
   is a single hyphen draws as a disabled dividing line. Documented
   behaviour, not a guess about this machine. */
static int item_is_separator(const NowAxMenuItem *item)
{
    return item->title_len == 1 && item->title[0] == '-';
}

/* The reference for one element, or nothing. A seam that declines is not
   a failure of the walk: the element keeps every other claim the walk
   made about it and loses only its address, which is what an absent
   `ref` says. */
static void name_window(NowScene *s, int window, NowObsWalk *refs,
                        unsigned long address)
{
    char token[kNowSceneRefMax];

    if (refs == NULL) {
        return;
    }
    if (now_obs_walk_window_ref(refs, address, token, sizeof token)) {
        now_scene_set_window_ref(s, window, token);
    }
}

static void name_control(NowScene *s, int window, int index,
                         NowObsWalk *refs, unsigned long address,
                         unsigned long handle)
{
    char token[kNowSceneRefMax];

    if (refs == NULL) {
        return;
    }
    if (now_obs_walk_control_ref(refs, address, handle, token,
                                 sizeof token)) {
        now_scene_set_control_ref(s, window, index, token);
    }
}

static void walk_controls(NowScene *s, int window, const NowAxMemory *memory,
                          const NowAxWindow *win, NowObsWalk *refs)
{
    NowAxControl control;
    unsigned long handle;
    int hops;

    /* Declared BEFORE the first read: from here on the window either
       reports its controls or explicitly retracts them, and there is no
       path that leaves a half-filled list standing. */
    if (!now_scene_open_controls(s, window)) {
        return;
    }
    handle = win->control_list;
    for (hops = 0; handle != 0; ++hops) {
        if (hops >= kNowSceneWalkMaxControls) {
            /* Longer than a scene carries, or cyclic. Either way what
               has been collected is a PREFIX of this window's controls
               with nothing beside it to say so. */
            now_scene_retract_controls(s, window);
            return;
        }
        if (now_ax_read_control(memory, win, handle, &control) != kNowAxOk) {
            /* The chain left the readable zones or failed a check. A
               refusal rather than a bound, and it drops the plane for
               the same reason: what stands is a prefix. */
            now_scene_retract_controls(s, window);
            return;
        }
        if (!now_scene_add_control(s, window, control.title, control.top,
                                   control.left, control.bottom,
                                   control.right, control.enabled,
                                   control.visible, control.value,
                                   control.min, control.max)) {
            now_scene_retract_controls(s, window);
            return;
        }
        /* Named AFTER it is admitted, and by its position in this
           window's block - which is `hops`, because every hop that got
           here appended exactly one control. A reference filed against
           the wrong index would name a sibling, and both rows would look
           complete. */
        name_control(s, window, hops, refs, win->address, handle);
        handle = control.next_control;
    }
}

void now_scene_walk_window(NowScene *s, int window,
                           const NowAxMemory *memory, unsigned long address,
                           NowObsWalk *refs)
{
    NowAxWindow win;
    NowAxText text;

    if (s == NULL || memory == NULL || address == 0) {
        return;
    }
    if (now_ax_read_window(memory, address, &win) != kNowAxOk) {
        return;                       /* every sub-plane stays absent */
    }
    now_scene_set_window_kind(s, window, win.kind);
    name_window(s, window, refs, address);
    walk_controls(s, window, memory, &win, refs);

    /* The text read is GATED ON THE KIND, and that gate is safety rather
       than tidiness: a DialogRecord's TEHandle sits at 160, which is
       past the end of a plain 156-byte WindowRecord. Reading it
       unconditionally would interpret whatever follows an ordinary
       window as a TextEdit handle, and the coherence checks inside the
       reader only catch that most of the time. */
    if (win.kind != kNowSceneDialogKind) {
        return;
    }
    if (now_ax_read_dialog_text(memory, address, &text) != kNowAxOk) {
        return;                       /* no TextEdit record: an answer */
    }
    now_scene_set_window_text(s, window, text.text, text.active,
                              text.truncated);
}

static void walk_items(NowScene *s, int menu_row, const NowAxMemory *memory,
                       const NowAxMenu *menu)
{
    NowAxMenuCursor cursor;
    NowAxMenuItem item;

    now_ax_menu_cursor_init(menu, &cursor);
    for (;;) {
        int rc = now_ax_menu_next(memory, &cursor, &item);

        if (rc == kNowAxNotFound) {
            return;                   /* the list's own sentinel: complete */
        }
        if (rc == kNowAxTruncated) {
            now_scene_retract_menu_items(s, menu_row);
            return;
        }
        if (rc != kNowAxOk) {
            now_scene_retract_menu_items(s, menu_row);
            return;
        }
        if (!now_scene_add_menu_item(s, menu_row, item.title,
                                     (short)item.index,
                                     item_is_separator(&item),
                                     item.enabled, item.mark != 0,
                                     item.command >= kNowSceneFirstCmdChar
                                     ? (char)item.command : '\0')) {
            now_scene_retract_menu_items(s, menu_row);
            return;
        }
    }
}

void now_scene_walk_menubar(NowScene *s, int proc,
                            const NowAxMemory *memory,
                            unsigned long menu_list)
{
    NowAxMenuList list;
    unsigned int i;

    if (s == NULL || memory == NULL) {
        return;
    }
    /* Assembly's own refusal, and the only gate that matters here: a
       menu bar read under an Ambiguous or Mismatch anchor is the
       coin-flip walk, and this returns 0 for it. */
    if (!now_scene_open_menubar(s, proc)) {
        return;
    }
    if (now_ax_open_menu_list(memory, menu_list, &list) != kNowAxOk) {
        /* The front process HAS a menu bar; a list that will not parse
           means we cannot report it, not that there are no menus. */
        now_scene_retract_menubar(s);
        return;
    }
    if (list.truncated) {
        s->menus_truncated = 1;
    }
    for (i = 0; i < list.count; ++i) {
        NowAxMenu menu;
        int row;

        if (now_ax_read_menu(memory, &list, i, &menu) != kNowAxOk) {
            /* One unreadable menu makes the BAR a partial list, and
               unlike a window's controls the menu bar has no per-owner
               marker either. Drop the plane. */
            now_scene_retract_menubar(s);
            return;
        }
        row = now_scene_add_menu(s, menu.title, menu.id, menu.left);
        if (row < 0) {
            return;                   /* assembly set menus_truncated */
        }
        walk_items(s, row, memory, &menu);
    }
}
