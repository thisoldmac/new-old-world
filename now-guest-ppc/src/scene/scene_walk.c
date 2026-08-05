/* Walk to scene. See scene_walk.h for why this is a separate,
   Toolbox-free file. */

#include "scene_walk.h"

#include <string.h>

#include "axmenu.h"
#include "axtext.h"
#include "semantic_client.h"

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
        /* BACK TO CONTENT-RELATIVE, which is what the IR names.
         *
         * now_ax_read_control returns GLOBAL coordinates - it adds the
         * window's content origin, and says so - because that is what
         * the act plane wants: a click lands somewhere on a screen. The
         * SCENE is a different consumer with a different contract. IR v1
         * documents `Control.rect` as "content-relative", Mirror's own
         * SceneBuilder subtracts the content origin to produce one, and
         * MirrorKit's hit tester converts a click into that space before
         * it compares. Handing it global numbers does not fail: it hit
         * tests every control against a rect displaced by the window's
         * own origin, so a person clicks one thing and actuates its
         * neighbour - or nothing - while the render still looks right.
         *
         * That is the shape of the defect that made a rendered mirror
         * "connected but unclickable", and no decode test can see it,
         * because both conventions are four honest integers. */
        if (!now_scene_add_control(s, window,
                                   control.title,
                                   (short)(control.top - win->origin_top),
                                   (short)(control.left - win->origin_left),
                                   (short)(control.bottom - win->origin_top),
                                   (short)(control.right - win->origin_left),
                                   control.enabled,
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
        now_scene_set_control_handle(s, window, hops, handle);
        /* Free with the read - contrlDefProc is inside the 296 bytes the
           control walk already validated. It answers a strictly weaker
           question than the semantic plane below and is set first, so a
           resident that does answer overwrites nothing. */
        now_scene_set_control_definition(s, window, hops,
                                         control.def_proc_origin);
        /* P2 is a target-context description of every live control, not a
           Date & Time resource-control special case. This is what lets the
           same extension inventory Sherlock's ordinary window controls. */
        now_semantic_client_join_control(s, window, hops,
                                         win->address, handle);
        handle = control.next_control;
    }
}

static short scene_dialog_kind(short kind)
{
    switch (kind) {
    case kNowAxDialogPushButton: return kNowSceneSemanticPushButton;
    case kNowAxDialogCheckBox: return kNowSceneSemanticCheckBox;
    case kNowAxDialogRadioButton: return kNowSceneSemanticRadioButton;
    case kNowAxDialogPopupMenu: return kNowSceneSemanticPopupMenu;
    case kNowAxDialogStaticText: return kNowSceneSemanticStaticText;
    case kNowAxDialogEditText: return kNowSceneSemanticEditText;
    case kNowAxDialogIcon: return kNowSceneSemanticIcon;
    case kNowAxDialogPicture: return kNowSceneSemanticPicture;
    case kNowAxDialogResourceControl: return kNowSceneSemanticUnknown;
    default: return kNowSceneSemanticUserItem;
    }
}

static NowSceneControl *control_for_handle(NowScene *s, int window,
                                           unsigned long handle)
{
    NowSceneWindow *w = &s->windows[window];
    short i;

    if (handle == 0 || !w->controls_present) {
        return NULL;
    }
    for (i = 0; i < w->control_count; ++i) {
        NowSceneControl *c = &s->controls[w->first_control + i];

        if (c->handle == handle) {
            return c;
        }
    }
    return NULL;
}

static void walk_dialog_items(NowScene *s, int window,
                              const NowAxMemory *memory,
                              unsigned long address,
                              const NowAxText *text)
{
    NowAxDialogCursor cursor;

    if (now_ax_open_dialog_items(memory, address, &cursor) != kNowAxOk
        || !now_scene_open_dialog_items(s, window)) {
        s->dialog_items_truncated = 1;
        return;
    }
    for (;;) {
        NowAxDialogItem source;
        NowSceneDialogItem *item;
        NowSceneControl *control;
        int rc = now_ax_dialog_next(memory, &cursor, &source);

        if (rc == kNowAxNotFound) {
            return;
        }
        if (rc != kNowAxOk
            || !now_scene_add_dialog_item(
                s, window, source.number, scene_dialog_kind(source.kind),
                source.title, source.top, source.left,
                source.bottom, source.right, source.enabled,
                source.visible)) {
            now_scene_retract_dialog_items(s, window);
            return;
        }
        item = &s->dialog_items[s->dialog_item_count - 1];
        control = control_for_handle(s, window, source.handle);
        if (control != NULL) {
            /* DITL's disable bit is the resource default. The live
               ControlRecord is authoritative after creation. Date & Time
               disables two checkboxes at runtime while their DITL rows stay
               enabled. */
            item->enabled = control->enabled;
            item->definition = control->definition;
            if (control->ref[0] != '\0') {
                strcpy(item->ref, control->ref);
            }
            if (control->title[0] != '\0'
                && (item->kind == kNowSceneSemanticPopupMenu
                    || item->title[0] == '\0')) {
                strncpy(item->title, control->title,
                        sizeof item->title - 1);
                item->title[sizeof item->title - 1] = '\0';
            }
            if (item->kind == kNowSceneSemanticCheckBox
                || item->kind == kNowSceneSemanticRadioButton) {
                item->state_known = 1;
                item->state_on = control->value != 0;
            }
            if (item->kind == kNowSceneSemanticPopupMenu) {
                item->value_known = 1;
                strncpy(item->value, control->title,
                        sizeof item->value - 1);
                item->value[sizeof item->value - 1] = '\0';
            }
        }
        if (cursor.default_item > 0
            && item->kind == kNowSceneSemanticPushButton) {
            item->default_known = 1;
            item->is_default = source.number == cursor.default_item;
        }
        if (item->kind == kNowSceneSemanticEditText) {
            item->focus_known = 1;
            item->focused = source.number == cursor.edit_item;
            if (item->focused && text != NULL) {
                item->value_known = 1;
                strncpy(item->value, text->text, sizeof item->value - 1);
                item->value[sizeof item->value - 1] = '\0';
                item->selection_known = 1;
                item->selection_start = (short)text->selection_start;
                item->selection_end = (short)text->selection_end;
            }
        }
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
    if (now_ax_read_dialog_text(memory, address, &text) == kNowAxOk) {
        now_scene_set_window_text(s, window, text.text, text.active,
                                  text.truncated);
        if (s->windows[window].text >= 0) {
            NowSceneText *scene_text =
                &s->texts[s->windows[window].text];

            scene_text->selection_start = (short)text.selection_start;
            scene_text->selection_end = (short)text.selection_end;
        }
        walk_dialog_items(s, window, memory, address, &text);
    } else {
        /* A dialog may have no editable text and still has a DITL. */
        walk_dialog_items(s, window, memory, address, NULL);
    }
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

int now_scene_fill_blank_system_apple(NowScene *s,
                                      const NowAxMemory *memory,
                                      unsigned long menu_list)
{
    NowAxMenuList list;
    int target = -1;
    int i;

    if (s == NULL || memory == NULL || !s->menubar_present
            || menu_list == 0) {
        return 0;
    }
    for (i = 0; i < s->menu_count; ++i) {
        NowSceneMenu *menu = &s->menus[i];
        int j;

        if ((unsigned char)menu->title[0] != 0x14
                || !menu->items_present || menu->item_count <= 0) {
            continue;
        }
        for (j = 0; j < menu->item_count; ++j) {
            if (s->menu_items[menu->first_item + j].title[0] != '\0') {
                break;
            }
        }
        if (j == menu->item_count) {
            target = i;
            break;
        }
    }
    if (target < 0
            || now_ax_open_menu_list(memory, menu_list, &list) != kNowAxOk
            || list.truncated) {
        return 0;
    }
    for (i = 0; i < (int)list.count; ++i) {
        NowAxMenu menu;
        NowAxMenuCursor cursor;
        NowAxMenuItem rows[kNowAxMenuItemMax];
        int count = 0;
        int start;
        int j;

        if (now_ax_read_menu(memory, &list, (unsigned int)i, &menu)
                != kNowAxOk
                || menu.title_len != 1
                || (unsigned char)menu.title[0] != 0x14) {
            continue;
        }
        now_ax_menu_cursor_init(&menu, &cursor);
        for (;;) {
            int rc;

            if (count >= kNowAxMenuItemMax) {
                count = 0;
                break;
            }
            rc = now_ax_menu_next(memory, &cursor, &rows[count]);

            if (rc == kNowAxNotFound) {
                break;
            }
            if (rc != kNowAxOk) {
                count = 0;
                break;
            }
            ++count;
        }
        start = count - s->menus[target].item_count;
        if (start < 0) {
            continue;
        }
        /* The two-NUL prefix is the guest evidence that these are the
           system-managed Apple Menu Items rows, not an inactive
           application's own About item or separator. Requiring it for the
           entire equal-sized suffix prevents a plausible cross-menu copy. */
        for (j = start; j < count; ++j) {
            if (rows[j].title_nul_prefix != 2 || rows[j].title_len == 0) {
                break;
            }
        }
        if (j != count) {
            continue;
        }
        for (j = 0; j < s->menus[target].item_count; ++j) {
            NowSceneMenuItem *dst =
                &s->menu_items[s->menus[target].first_item + j];
            const NowAxMenuItem *src = &rows[start + j];

            memset(dst->title, 0, sizeof dst->title);
            strncpy(dst->title, src->title, sizeof dst->title - 1);
            dst->separator = item_is_separator(src);
            dst->enabled = src->enabled ? 1 : 0;
            dst->mark = src->mark != 0;
            dst->cmd = src->command >= kNowSceneFirstCmdChar
                ? (char)src->command : '\0';
            /* Keep dst->index: it belongs to the current front menu and is
               the value MenuSelect will receive. */
        }
        return 1;
    }
    return 0;
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
        if (s->menus[row].item_count == 0) {
            now_semantic_client_join_menu(s, row, menu.handle, menu.id);
        }
    }
}
