/* Walk to scene. See scene_walk.h for why this is a separate,
   Toolbox-free file. */

#include "scene_walk.h"

#include <string.h>

#include "axmenu.h"
#include "axtext.h"
#include "cdef_resolver.h"
#include "dialog_text.h"
#include "scene_phase.h"
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

/* The blank-system-menu bridge is called serially from one scene walk and
 * never pumps the event loop. Keep its maximum menu page out of a classic
 * Mac stack frame: GCC measures the automatic form at roughly 9 KiB, close
 * to a third of the application's ordinary 24-32 KiB stack. */
static NowAxMenuItem g_blank_apple_rows[kNowAxMenuItemMax];

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

/* THE CHAIN, and only the chain. What each control IS - its rect, its
   value, its enabled and visible flags - and nothing about what the act
   plane or a resident will later say about it. Split out from the two
   passes below so that "reading controls", "naming them" and "joining
   semantics onto them" are three separate spans of time rather than
   three things interleaved 300 times, which is the difference between a
   breakdown that costs six clock reads per window and one that costs
   four per control. */
/* How long is the rest of this chain? Called only when the bound above
   has already bitten, so it costs nothing on the ordinary path.
 *
   It records NOTHING - no pool slots, no references, no semantics - it
   only follows `next_control` and counts, which is why it can afford a
   bound an order of magnitude larger than the one a scene carries. That
   larger bound is still a bound, because the other thing this path
   catches is a cyclic chain, and a cycle would otherwise hang the guest
   inside the event loop.

   Returns the total length from the head; sets *exact to 0 if the probe
   bound stopped the count, in which case the answer is a floor. */
static short measure_chain(const NowAxMemory *memory, const NowAxWindow *win,
                           int *exact)
{
    NowAxControl control;
    unsigned long handle = win->control_list;
    int hops;

    *exact = 1;
    for (hops = 0; handle != 0; ++hops) {
        if (hops >= kNowSceneWalkChainProbeMax) {
            *exact = 0;
            break;
        }
        if (now_ax_read_control(memory, win, handle, &control) != kNowAxOk) {
            /* The count is a floor for a different reason: the chain is
               longer than `hops`, we simply cannot see past here. */
            *exact = 0;
            break;
        }
        handle = control.next_control;
    }
    return (short)hops;
}

static void read_controls(NowScene *s, int window, const NowAxMemory *memory,
                          const NowAxWindow *win)
{
    NowAxControl control;
    unsigned long handle;
    int hops;

    handle = win->control_list;
    for (hops = 0; handle != 0; ++hops) {
        if (hops >= kNowSceneWalkMaxControls) {
            /* Longer than a scene carries, or cyclic. Either way what
               has been collected is a PREFIX of this window's controls
               with nothing beside it to say so.

               Say HOW LONG before dropping it. The bound being ours is
               only half an answer; a reader deciding whether to raise it
               needs the other half, and this is the one moment the chain
               is in front of us. */
            int exact;
            short len = measure_chain(memory, win, &exact);

            now_scene_retract_controls(s, window);
            /* A chain that ran past the probe bound is not a long chain,
               it is a broken one, and the two argue for opposite
               responses. Distinguished here, where the evidence is. */
            now_scene_set_walk_verdict(
                s, window,
                (!exact && len >= kNowSceneWalkChainProbeMax)
                    ? kNowSceneWalkControlsCyclic
                    : kNowSceneWalkControlsBound);
            now_scene_set_control_chain_len(s, window, len, exact);
            return;
        }
        if (now_ax_read_control(memory, win, handle, &control) != kNowAxOk) {
            /* The chain left the readable zones or failed a check. A
               refusal rather than a bound, and it drops the plane for
               the same reason: what stands is a prefix. */
            now_scene_retract_controls(s, window);
            now_scene_set_walk_verdict(s, window,
                                       kNowSceneWalkControlsInvalid);
            /* A FLOOR, not a length: the chain is at least this long and
               we cannot see past the record that failed. Marked inexact
               so nobody sizes a cap from it. */
            now_scene_set_control_chain_len(s, window, (short)hops, 0);
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
            /* WHOSE FAULT THE SILENCE IS, before the plane goes.
             *
               The control pool is shared across every window in the
               scene, so this refusal is usually not about this window at
               all: the slots were spent walking earlier ones. Retracting
               without saying so published `controls: []` for a panel with
               twenty controls, indistinguishable from a panel proven to
               have none - which is the empty/unknown conflation wearing
               a third face, and the one face a consumer could fix by
               asking again.
             *
               `now_scene_add_control` also refuses an interleaved block,
               which is a misattribution rather than an overflow, so the
               cause is read off the pool rather than assumed from the
               refusal. */
            int pool_full = s->control_count >= kNowSceneMaxControls;

            now_scene_retract_controls(s, window);
            if (pool_full) {
                now_scene_set_walk_verdict(s, window,
                                           kNowSceneWalkControlsPoolFull);
                /* And how long the chain WAS, for the same reason the
                   bound path measures it: a cap raised without the
                   distribution is a cap fitted to one panel. */
                {
                    int exact;
                    short len = measure_chain(memory, win, &exact);

                    now_scene_set_control_chain_len(s, window, len, exact);
                }
            }
            return;
        }
        /* Filed by its position in this window's block - which is
           `hops`, because every hop that got here appended exactly one
           control. A handle filed against the wrong index would name a
           sibling, and both rows would look complete. */
        now_scene_set_control_handle(s, window, hops, handle);
        /* Free with the read - contrlDefProc is inside the 296 bytes the
           control walk already validated. It answers a strictly weaker
           question than the semantic plane below and is set first, so a
           resident that does answer overwrites nothing. */
        now_scene_set_control_definition(s, window, hops,
                                         control.def_proc_origin);
        /* And WHICH definition, when the Resource Manager can say. Asked
           only for a definition function in the system heap: that is the
           zone the read above validated, and the only one whose CDEFs
           are in this process's resource chain. An application's own
           CDEF is in a resource file we never opened, so there is no
           lookup to make and the resolver is not asked to make one. */
        if (control.def_proc_origin == (short)kNowAxDefProcSystem) {
            short state, cdef_id = 0, cdef_variant = 0;

            state = now_cdef_resolve(control.def_proc,
                                     memory->system_lo, memory->system_hi,
                                     &cdef_id, &cdef_variant);
            now_scene_set_control_cdef(s, window, hops, state,
                                       cdef_id, cdef_variant);
        }
        handle = control.next_control;
    }
    /* The chain ended on its own sentinel: the count is exact and equals
       what the scene carries. Recorded on the ordinary path too so a
       reader never has to infer the length from the absence of a note. */
    now_scene_set_control_chain_len(s, window, (short)hops, 1);
}

/* The three passes, in the order their claims depend on each other.
 *
 * READ, then NAME, then JOIN - and the split is not only about
 * measurement. The chain used to be read and named and joined one
 * control at a time, so a control that failed to read on hop 40 retracted
 * a plane whose first 39 references had already been minted out of the
 * registry's finite slots. Names are now minted only for controls that
 * SURVIVED the read, which is the same rule the walk already applied to
 * everything else it publishes. */
static void walk_controls(NowScene *s, int window, const NowAxMemory *memory,
                          const NowAxWindow *win, NowObsWalk *refs)
{
    const NowSceneWindow *w;
    short i;

    /* Declared BEFORE the first read: from here on the window either
       reports its controls or explicitly retracts them, and there is no
       path that leaves a half-filled list standing. */
    if (!now_scene_open_controls(s, window)) {
        return;
    }
    now_scene_phase_enter(kNowScenePhaseControls);
    read_controls(s, window, memory, win);
    now_scene_phase_leave(kNowScenePhaseControls);

    w = &s->windows[window];
    if (!w->controls_present) {
        return;                       /* the plane was retracted */
    }
    now_scene_phase_enter(kNowScenePhaseRefs);
    for (i = 0; i < w->control_count; ++i) {
        name_control(s, window, i, refs, win->address,
                     s->controls[w->first_control + i].handle);
    }
    now_scene_phase_leave(kNowScenePhaseRefs);

    /* P2 is a target-context description of every live control, not a
       Date & Time resource-control special case. This is what lets the
       same extension inventory Sherlock's ordinary window controls. */
    now_scene_phase_enter(kNowScenePhaseSemantics);
    for (i = 0; i < w->control_count; ++i) {
        now_semantic_client_join_control(s, window, i, win->address,
                                         s->controls[w->first_control + i]
                                             .handle);
    }
    now_scene_phase_leave(kNowScenePhaseSemantics);
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
        /* The DITL gave us the RESOURCE's text. An application that filled
           the item in at runtime wrote somewhere else entirely — see
           dialog_text.h, and Internet Explorer's Error alert, whose whole
           message was missing from the mirror because of this. The handle is
           proved through the memory seam FIRST; only then does the Memory
           Manager get asked how long it is. */
        if (item->kind == kNowSceneSemanticStaticText
            || item->kind == kNowSceneSemanticEditText) {
            unsigned long data;

            if (source.handle != 0
                && now_ax_read_handle(memory, source.handle, &data)
                       == kNowAxOk) {
                char live[kNowSceneDialogTitleMax];

                /* Validated on the way in, like every other title: this
                   path writes into the row directly and so is the one
                   place the assembly function's own gate cannot see. */
                if (now_scene_dialog_item_text(
                        source.handle, live,
                        (short)sizeof live) > 0
                    && now_scene_title_is_publishable(live)) {
                    strcpy(item->title, live);
                }
            }
        }
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
            /* THE LIVE CONTROL WINS, ALWAYS, and this used to be an
               "only if the DITL said nothing" rule.
             *
             * A DITL item's text is the RESOURCE's title, frozen at the
             * moment the dialog was built; SetControlTitle and ParamText
             * write to the ControlRecord and never back to the item list.
             * So the two walks describe the same ref from two different
             * moments, and sweep A caught exactly that on Mail's
             * Internet-setup alert: the control walk said Yes / No /
             * Set Up Now, the dialog-item walk said OK / Cancel /
             * Don't Save, same three refs, same three rects.
             *
             * That is the worst shape a defect can take here - an agent
             * reads one label and clicks another control - and it cannot
             * be fixed by making the host prefer one walk, because the
             * host cannot tell which one is stale. It is fixed by there
             * being one answer: after creation the ControlRecord is
             * authoritative for a control-backed item, the same rule the
             * `enabled` flag two lines above already follows. */
            if (control->title[0] != '\0') {
                strncpy(item->title, control->title,
                        sizeof item->title - 1);
                item->title[sizeof item->title - 1] = '\0';
            } else if (item->kind == kNowSceneSemanticPushButton
                       || item->kind == kNowSceneSemanticCheckBox
                       || item->kind == kNowSceneSemanticRadioButton) {
                /* The control is live and genuinely unnamed. Keeping the
                   resource's old text here would reinstate the same
                   contradiction from the other side. */
                item->title[0] = '\0';
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
                if (now_scene_title_is_publishable(text->text)) {
                    strncpy(item->value, text->text, sizeof item->value - 1);
                    item->value[sizeof item->value - 1] = '\0';
                }
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
        /* Every sub-plane stays absent - and SAYS SO. This used to be a
           bare return, so a window whose record failed validation
           published `controls: []` and no dialogItems key, which reads
           exactly like a window that has neither. */
        now_scene_note_window_unreadable(s, window);
        return;
    }
    now_scene_set_window_kind(s, window, win.kind);
    now_scene_set_window_widgets(s, window, win.go_away, win.zoom);
    now_scene_phase_enter(kNowScenePhaseRefs);
    name_window(s, window, refs, address);
    now_scene_phase_leave(kNowScenePhaseRefs);
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
        NowAxMenuItem *rows = g_blank_apple_rows;
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
            /* Same gate as every other title. This copy writes into the
               row directly, so the assembly function never sees it. */
            if (now_scene_title_is_publishable(src->title)) {
                strncpy(dst->title, src->title, sizeof dst->title - 1);
            }
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
            now_scene_phase_enter(kNowScenePhaseSemantics);
            now_semantic_client_join_menu(s, row, menu.handle, menu.id);
            now_scene_phase_leave(kNowScenePhaseSemantics);
        }
    }
}
