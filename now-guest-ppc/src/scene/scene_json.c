#include "scene.h"

#include <stdio.h>
#include <string.h>

#include "axwalk.h"    /* NowAxDefProcOrigin: scene.h stores one as a short */
#include "json.h"
#include "scene_phase.h"

/* The IR v2 encoder.

   One pass, counting always and writing only while it fits, so a single
   walk yields both the bytes and the exact size a complete encode would
   have taken. That is what lets a caller ask "does this scene fit a
   4096-byte control frame" without encoding it twice - and the answer,
   for any real desktop, is no (docs/scene-producer.md).

   Field order follows the IR's own reading order rather than being
   alphabetised: version and the gate first, the planes after. A consumer
   parses by key, so the order is for the human reading a capture. */

typedef struct {
    char *out;                    /* may be NULL when sizing */
    long cap;                     /* bytes available including terminator */
    long len;                     /* bytes a complete encode needs, so far */
    int over;
} Sink;

static void put(Sink *k, const char *s)
{
    long n;

    if (s == NULL) {
        return;
    }
    n = (long)strlen(s);
    if (k->out != NULL && k->len + n < k->cap) {
        memcpy(k->out + k->len, s, (size_t)n);
    } else {
        k->over = 1;
    }
    k->len += n;
}

static void put_num(Sink *k, long v)
{
    char buf[24];

    snprintf(buf, sizeof buf, "%ld", v);
    put(k, buf);
}

/* A MacRoman string as a JSON string, quotes included. now_json_escape
   is the guest's one escaper: high MacRoman bytes become \uXXXX for
   their real Unicode value, because raw bytes there are both invalid
   JSON and invalid UTF-8 - which is exactly how a listing silently fails
   to parse on the modern side. */
static void put_str(Sink *k, const char *s)
{
    /* Sized for the LONGEST string any plane carries (a window's text),
       times the six bytes a MacRoman byte can become as `\uXXXX`, plus
       the terminator. One buffer rather than a per-caller size, because
       a caller that picked the wrong one would silently ship a truncated
       title - and this is a leaf function, so the stack cost is paid
       once. */
    char esc[6 * kNowSceneTextMax + 8];

    now_json_escape(s != NULL ? s : "", esc, (long)sizeof esc);
    put(k, "\"");
    put(k, esc);
    put(k, "\"");
}

static void put_psn(Sink *k, const NowScenePsn *psn)
{
    char buf[32];

    snprintf(buf, sizeof buf, "\"%ld.%lu\"", psn->hi, psn->lo);
    put(k, buf);
}

static void put_process_incarnation(Sink *k, unsigned long incarnation)
{
    char buf[40];

    snprintf(buf, sizeof buf, "\"process-%08lx\"",
             incarnation & 0xffffffffUL);
    put(k, buf);
}

/* The creator OSType as its four MacRoman characters. IR v1 promoted
   `processes[].signature` because the creator is the only app identity
   besides a display name; a process whose signature we could not read
   carries an empty string rather than four invented characters. */
static void put_signature(Sink *k, unsigned long sig)
{
    char buf[5];

    if (sig == 0) {
        put(k, "\"\"");
        return;
    }
    buf[0] = (char)((sig >> 24) & 0xFF);
    buf[1] = (char)((sig >> 16) & 0xFF);
    buf[2] = (char)((sig >> 8) & 0xFF);
    buf[3] = (char)(sig & 0xFF);
    buf[4] = '\0';
    put_str(k, buf);
}

static void put_captured_at(Sink *k, double t)
{
    char buf[32];

    /* Seconds, with the fractional place upstream's fixtures carry. The
       guest's clock is the only clock it has; whether it is RIGHT is a
       property of the machine (a PowerBook with a dead PRAM battery
       boots in 1904), and the scene reports what the machine believes
       rather than correcting it silently. */
    snprintf(buf, sizeof buf, "%.1f", t);
    put(k, buf);
}

static void put_apps(Sink *k, const NowScene *s)
{
    short i;

    put(k, ",\"apps\":[");
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];
        const char *err = now_scene_proc_error(p);

        put(k, i > 0 ? ",{\"psn\":" : "{\"psn\":");
        put_psn(k, &p->psn);
        put(k, ",\"name\":");
        put_str(k, p->name);
        put(k, ",\"front\":");
        put(k, p->front ? "true" : "false");
        if (p->incarnation != 0) {
            put(k, ",\"incarnation\":");
            put_process_incarnation(k, p->incarnation);
        }
        /* `error` is ABSENT when there is nothing wrong, not null: the
           key says something happened, and its absence says nothing
           did. */
        if (err != NULL) {
            put(k, ",\"error\":");
            put_str(k, err);
        }
        put(k, "}");
    }
    put(k, "]");
}

static void put_processes(Sink *k, const NowScene *s)
{
    short i;

    put(k, ",\"processes\":[");
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];

        put(k, i > 0 ? ",{\"psn\":" : "{\"psn\":");
        put_psn(k, &p->psn);
        put(k, ",\"name\":");
        put_str(k, p->name);
        put(k, ",\"front\":");
        put(k, p->front ? "true" : "false");
        put(k, ",\"signature\":");
        put_signature(k, p->signature);
        if (p->incarnation != 0) {
            put(k, ",\"incarnation\":");
            put_process_incarnation(k, p->incarnation);
        }
        put(k, "}");
    }
    put(k, "]");
}

/* The menu bar, and only when the front process's walk produced one.
   `menubar` absent means this scene does not report a menu bar;
   `menubar` present with an empty `menus` means the front process has
   none, which a faceless background application genuinely does not.

   `menus[].apple` is NOT emitted. IR v1 carries it, but nothing this
   walk reads says which menu is the Apple menu - a title byte or a menu
   id could be made to look like evidence and would be a guess - so the
   key stays absent rather than becoming a plausible false claim. A
   menu's `items` is absent when its item walk did not complete, per the
   retraction rule. */
static void put_menubar(Sink *k, const NowScene *s)
{
    short i;
    short j;

    if (!s->menubar_present) {
        return;
    }
    put(k, ",\"menubar\":{\"app\":");
    put_str(k, (s->menubar_proc >= 0 && s->menubar_proc < s->proc_count)
            ? s->procs[s->menubar_proc].name : "");
    put(k, ",\"menus\":[");
    for (i = 0; i < s->menu_count; ++i) {
        const NowSceneMenu *m = &s->menus[i];

        /* THE IR DECLARES `apple`, and it is not optional there. The
           Apple menu carries the Chicago apple byte (0x14) as its title
           on this machine; the IR says the title is EMPTY for it and the
           flag is what identifies it, so that is what goes on the wire.
           A renderer draws the apple from the flag, not from a byte
           whose glyph is font-dependent. */
        {
            int is_apple = (unsigned char)m->title[0] == 0x14;

            put(k, i > 0 ? ",{\"title\":" : "{\"title\":");
            put_str(k, is_apple ? "" : m->title);
            put(k, ",\"apple\":");
            put(k, is_apple ? "true" : "false");
        }
        put(k, ",\"id\":");
        put_num(k, m->id);
        put(k, ",\"left\":");
        put_num(k, m->left);
        /* Same rule as controls: the IR declares `items` required, so a
           menu nobody walked reports an empty list rather than omitting
           the key and making the whole document unreadable. */
        put(k, ",\"items\":[");
        if (m->items_present) {
            for (j = 0; j < m->item_count; ++j) {
                const NowSceneMenuItem *it =
                    &s->menu_items[m->first_item + j];

                put(k, j > 0 ? ",{\"title\":" : "{\"title\":");
                put_str(k, it->title);
                put(k, ",\"index\":");
                put_num(k, it->index);
                put(k, ",\"separator\":");
                put(k, it->separator ? "true" : "false");
                put(k, ",\"enabled\":");
                put(k, it->enabled ? "true" : "false");
                put(k, ",\"mark\":");
                put(k, it->mark ? "true" : "false");
                /* ALWAYS PRESENT, and this is the one place the
                   absent-key rule yields. That rule is right when the
                   producer is defining the shape: an absent key says
                   "there is none" without a sentinel. Here the shape is
                   the IR, which declares `cmd` as a required string whose
                   EMPTY value means no shortcut - so omitting it does not
                   say "no shortcut", it makes the document undecodable by
                   the consumer this producer exists to feed. Measured
                   2026-08-02: MirrorKit refused a NOW scene on exactly
                   this key. */
                {
                    char one[2];

                    one[0] = it->cmd;
                    one[1] = '\0';
                    put(k, ",\"cmd\":");
                    put_str(k, it->cmd != '\0' ? one : "");
                }
                put(k, "}");
            }
        }
        put(k, "]");
        put(k, "}");
    }
    put(k, "]}");
}

/* An observation reference, and ONLY when there is one.

   The empty string is not a reference and must never reach the wire as
   one: the host's adapter reads a present-but-empty `ref` as "this
   producer has no reference layer" and reports the element
   unactionable, which is a different claim from "this element was not
   minted". Both are honest sentences; only one of them is true of an
   element the walk could not name, and it is the one absence says. */
/* A CONTROL's reference, which is always present because IR v1 freezes
   it (`windows[].controls[].ref` in IRSchema.v1Frozen). The distinction
   the note above draws - absent means "not minted", empty means "no
   reference layer" - is real and is NOT EXPRESSIBLE in this contract, so
   the producer emits the one the contract admits rather than the one it
   would prefer.

   Measured 2026-08-03: with self-described windows, whose controls the
   Toolbox names and the reference layer does not, omitting the key made
   the whole scene undecodable - `keyNotFound: Key 'ref'` - and the
   mirror went blank with that sentence in its status line. The decode
   gate could not have caught it: every control in the fixture HAS a
   reference. */
static void put_ref_required(Sink *k, const char *ref)
{
    put(k, ",\"ref\":");
    put_str(k, (ref == NULL) ? "" : ref);
}

static void put_ref(Sink *k, const char *ref)
{
    if (ref == NULL || ref[0] == '\0') {
        return;
    }
    put(k, ",\"ref\":");
    put_str(k, ref);
}

/* What a walk of a foreign ControlRecord may honestly say about KIND.
 *
 * It may not say much: the record holds no kind field, and its defProc
 * is a Handle whose resource identity we cannot ask for from outside the
 * owning application. So this is a guess, and the job is to make it a
 * guess that fails SAFELY - towards "some control", which draws as a
 * plain control and actuates as a button press, rather than towards
 * "scroll bar", which draws as a track and actuates as a page-scroll.
 *
 * The rule it replaces was `min != max ? scrollbar : control`, and it
 * was measured wrong on 2026-08-03 by reading the guest's own memory
 * through the emulator monitor. Mail's alert buttons - contrlTitle
 * 'Yes', 'No', 'Set Up Now' at ControlRecord+40 - each carry min 0 and
 * max 1, so every one of them was called a scroll bar. They drew as
 * three tracks with no labels, and a click on them sent a page-scroll
 * part, so the button never fired: the mirror could not dismiss the
 * alert, and the alert held the whole machine. A control drawn as the
 * wrong thing is a control that cannot be driven.
 *
 * What is left to reason from is the title and the shape:
 *
 *   - A titled control is not a scroll bar. Scroll bars carry no title,
 *     and everything that does - buttons, checkboxes, radio buttons,
 *     popups - wants its title drawn.
 *   - An untitled control that is THIN and LONG is a scroll bar. Thin
 *     means within a pixel or two of 16, which is the Platinum scroll
 *     bar's thickness and has been since System 7; a push button is 20
 *     high and wider than it is tall, which is exactly what the old
 *     20-pixel threshold could not separate.
 *
 * Anything else stays unknown and unactionable. For NOW-owned controls,
 * `now_scene_set_control_role` carries the exact procID-derived role; the
 * encoder must preserve that distinction rather than flattening every known
 * role back into a push button. */
/* WHOSE definition function draws this control - a strictly weaker claim
   than `kind`, and the only one a foreign ControlRecord read can support
   on its own. It is emitted BESIDE knowledge rather than folded into it:
   "the Toolbox supplies this control's definition" does not say which
   control it is, so it can never authorise an action, and a reader that
   treats it as a kind is reading a key that does not say that.
   `Absent` omits the key, per the absent-key rule. */
static const char *control_definition(short origin)
{
    switch (origin) {
    case kNowAxDefProcSystem: return "system";
    case kNowAxDefProcApplication: return "application";
    case kNowAxDefProcIndeterminate: return "indeterminate";
    default: return NULL;
    }
}

static const char *control_kind(const char *role)
{
    if (strcmp(role, "button") == 0) return "pushButton";
    if (strcmp(role, "checkbox") == 0) return "checkBox";
    if (strcmp(role, "radio") == 0) return "radioButton";
    if (strcmp(role, "popup") == 0) return "popupMenu";
    if (strcmp(role, "scrollbar") == 0) return "scrollBar";
    if (strcmp(role, "group") == 0) return "groupBox";
    if (strcmp(role, "progress") == 0) return "progressIndicator";
    if (strcmp(role, "triangle") == 0) return "disclosureTriangle";
    if (strcmp(role, "listBox") == 0) return "listBox";
    if (strcmp(role, "edit") == 0) return "editText";
    if (strcmp(role, "static") == 0) return "staticText";
    if (strcmp(role, "header") == 0) return "columnHeader";
    if (strcmp(role, "dataBrowser") == 0) return "dataBrowser";
    if (strcmp(role, "userPane") == 0) return "userPane";
    if (strcmp(role, "imageWell") == 0) return "imageWell";
    if (strcmp(role, "systemControl") == 0) return "systemControl";
    return "unknown";
}

static const char *control_action(const char *role)
{
    if (strcmp(role, "button") == 0
            || strcmp(role, "checkbox") == 0
            || strcmp(role, "radio") == 0
            || strcmp(role, "triangle") == 0) {
        return "press";
    }
    if (strcmp(role, "popup") == 0) return "choose";
    if (strcmp(role, "scrollbar") == 0) return "scroll";
    return NULL;
}

static int control_has_state(const char *role)
{
    return strcmp(role, "checkbox") == 0
        || strcmp(role, "radio") == 0
        || strcmp(role, "triangle") == 0;
}

static int control_has_value(const char *role)
{
    return strcmp(role, "popup") == 0
        || strcmp(role, "scrollbar") == 0
        || strcmp(role, "progress") == 0
        || strcmp(role, "listBox") == 0
        || strcmp(role, "edit") == 0
        || strcmp(role, "static") == 0
        || strcmp(role, "dataBrowser") == 0
        || strcmp(role, "userPane") == 0
        || strcmp(role, "imageWell") == 0
        || strcmp(role, "systemControl") == 0;
}

/* A window's controls, and only for a window whose whole chain was
   walked. `checked` is absent throughout: the walk reads a
   ControlRecord, not its defProc, so it cannot say whether a control
   that HAS a checked state is in it. `ref` is present for every control
   the reference layer could name and absent for the rest. */
static void put_controls(Sink *k, const NowScene *s, const NowSceneWindow *w)
{
    short i;

    /* ALWAYS AN ARRAY, even when this window's controls were not walked.
       The absent key used to mean "not looked at", which is a real
       distinction and not one the IR has: it declares `controls`
       required, so omitting it makes the document undecodable rather
       than subtly informative. What was lost is recovered where it
       belongs - meta carries the truncation note when a list was
       dropped, and a window nobody could walk reports none. */
    put(k, ",\"controls\":[");
    if (!w->controls_present) {
        put(k, "]");
        return;
    }
    for (i = 0; i < w->control_count; ++i) {
        const NowSceneControl *c = &s->controls[w->first_control + i];
        char rect[64];

        /* `role` is required by the IR, so SOMETHING is always emitted.
           When a reader could actually say what the control is, that
           wins; the range guess below is the fallback and is now known
           to be actively wrong rather than merely coarse.
         *
         * Measured 2026-08-03 by hovering the mirror: a push button made
         * with NewControl carries min 0 max 1, so `min != max` called it
         * a SCROLL BAR - drawn as a track, hit-tested as `pageDown`, and
         * a click on it would have sent a page-scroll part instead of a
         * button press. A walk of a foreign ControlRecord still cannot do
         * better; an application asking the Control Manager about its own
         * control can, and scene_self.c does. */
        put(k, i > 0 ? ",{\"role\":" : "{\"role\":");
        /* IR v2 keeps the legacy role only so v1-era renderers can draw an
           approximation. Unknown is explicit: geometry and a value range
           never become an action-bearing type. */
        put_str(k, c->role[0] != '\0' ? c->role : "unknown");
        put(k, ",\"title\":");
        put_str(k, c->title);
        snprintf(rect, sizeof rect, ",\"rect\":{\"l\":%d,\"t\":%d,\"r\":%d,"
                 "\"b\":%d}", (int)c->rect.l, (int)c->rect.t, (int)c->rect.r,
                 (int)c->rect.b);
        put(k, rect);
        put(k, ",\"enabled\":");
        put(k, c->enabled ? "true" : "false");
        put(k, ",\"visible\":");
        put(k, c->visible ? "true" : "false");
        put(k, ",\"value\":");
        put_num(k, c->value);
        put(k, ",\"min\":");
        put_num(k, c->min);
        put(k, ",\"max\":");
        put_num(k, c->max);
        put_ref_required(k, c->ref);
        put(k, ",\"semantic\":{\"knowledge\":");
        if (c->role[0] == '\0') {
            const char *definition = control_definition(c->definition);

            put_str(k, "unknown");
            /* Only where the kind is unknown. Where a role exists the
               answer is already better, and a second, weaker provenance
               beside it invites a reader to average the two. */
            if (definition != NULL) {
                put(k, ",\"definition\":");
                put_str(k, definition);
            }
        } else {
            const char *action = control_action(c->role);
            char value[16];

            put_str(k, "known");
            put(k, ",\"kind\":");
            put_str(k, control_kind(c->role));
            if (action != NULL) {
                put(k, ",\"action\":");
                put_str(k, action);
            }
            if (control_has_state(c->role)) {
                put(k, ",\"state\":");
                put_str(k, c->value != 0 ? "on" : "off");
            }
            if (control_has_value(c->role)) {
                put(k, ",\"value\":");
                if (c->semantic_value_known) {
                    put_str(k, c->semantic_value);
                } else {
                    snprintf(value, sizeof value, "%d", (int)c->value);
                    put_str(k, value);
                }
            }
            if (strcmp(c->role, "listBox") == 0
                && c->list_cells_present) {
                short cell_index;

                put(k, ",\"listCells\":[");
                for (cell_index = 0;
                     cell_index < c->list_cell_count; ++cell_index) {
                    const NowSceneListCell *cell =
                        &s->list_cells[c->first_list_cell + cell_index];

                    put(k, cell_index == 0 ? "{\"row\":"
                                           : ",{\"row\":");
                    put_num(k, cell->row);
                    put(k, ",\"column\":");
                    put_num(k, cell->column);
                    put(k, ",\"text\":");
                    put_str(k, cell->text);
                    put(k, ",\"selected\":");
                    put(k, cell->selected ? "true}" : "false}");
                }
                put(k, "],\"listTotalCount\":");
                put_num(k, c->list_total_count);
            }
        }
        if (strcmp(c->role, "listBox") == 0) {
            put(k, ",\"provenance\":\"guest-semantic-assist\","
                   "\"completeness\":");
            put_str(k, c->list_cells_present && c->list_cells_complete
                       ? "complete" : "partial");
            put(k, "}");
        } else {
            put(k, ",\"provenance\":\"guest-control-manager\","
                   "\"completeness\":\"complete\"}");
        }
        put(k, "}");
    }
    put(k, "]");
}

static const char *dialog_kind(short kind)
{
    switch (kind) {
    case kNowSceneSemanticPushButton: return "pushButton";
    case kNowSceneSemanticCheckBox: return "checkBox";
    case kNowSceneSemanticRadioButton: return "radioButton";
    case kNowSceneSemanticPopupMenu: return "popupMenu";
    case kNowSceneSemanticStaticText: return "staticText";
    case kNowSceneSemanticEditText: return "editText";
    case kNowSceneSemanticIcon: return "icon";
    case kNowSceneSemanticPicture: return "picture";
    case kNowSceneSemanticUserItem: return "userItem";
    case kNowSceneSemanticPanel: return "panel";
    case kNowSceneSemanticPlacard: return "placard";
    case kNowSceneSemanticSelectionBand: return "selectionBand";
    case kNowSceneSemanticSeparator: return "separator";
    default: return "unknown";
    }
}

static const char *dialog_action(short kind)
{
    switch (kind) {
    case kNowSceneSemanticPushButton:
    case kNowSceneSemanticCheckBox:
    case kNowSceneSemanticRadioButton:
        return "press";
    case kNowSceneSemanticPopupMenu:
        return "choose";
    case kNowSceneSemanticEditText:
        return "edit";
    default:
        return NULL;
    }
}

static void put_dialog_items(Sink *k, const NowScene *s,
                             const NowSceneWindow *w)
{
    short i;

    if (!w->dialog_items_present) {
        return;
    }
    put(k, ",\"dialogItems\":[");
    for (i = 0; i < w->dialog_item_count; ++i) {
        const NowSceneDialogItem *item =
            &s->dialog_items[w->first_dialog_item + i];
        const char *action = dialog_action(item->kind);
        char buf[96];

        put(k, i > 0 ? ",{\"number\":" : "{\"number\":");
        put_num(k, item->number);
        put(k, ",\"title\":");
        put_str(k, item->title);
        snprintf(buf, sizeof buf,
                 ",\"rect\":{\"l\":%d,\"t\":%d,\"r\":%d,\"b\":%d}",
                 (int)item->rect.l, (int)item->rect.t,
                 (int)item->rect.r, (int)item->rect.b);
        put(k, buf);
        put(k, ",\"enabled\":");
        put(k, item->enabled ? "true" : "false");
        put(k, ",\"visible\":");
        put(k, item->visible ? "true" : "false");
        put_ref(k, item->ref);
        put(k, ",\"semantic\":{\"knowledge\":");
        put_str(k, item->kind == kNowSceneSemanticUnknown
                   ? "unknown" : "known");
        if (item->kind == kNowSceneSemanticUnknown) {
            const char *definition = control_definition(item->definition);

            /* The `resCtrl` case, and the only dialog item type whose kind
               the DITL cannot supply. Same rule as a control's: emitted
               only where the kind is missing. */
            if (definition != NULL) {
                put(k, ",\"definition\":");
                put_str(k, definition);
            }
        }
        if (item->kind != kNowSceneSemanticUnknown) {
            put(k, ",\"kind\":");
            put_str(k, dialog_kind(item->kind));
        }
        if (action != NULL) {
            put(k, ",\"action\":");
            put_str(k, action);
        }
        if (item->state_known) {
            put(k, ",\"state\":");
            put_str(k, item->state_on ? "on" : "off");
        }
        if (item->value_known) {
            put(k, ",\"value\":");
            put_str(k, item->value);
        }
        if (item->selection_known) {
            snprintf(buf, sizeof buf,
                     ",\"selection\":{\"start\":%d,\"end\":%d}",
                     (int)item->selection_start, (int)item->selection_end);
            put(k, buf);
        }
        if (item->focus_known) {
            put(k, ",\"focused\":");
            put(k, item->focused ? "true" : "false");
        }
        if (item->default_known) {
            put(k, ",\"isDefault\":");
            put(k, item->is_default ? "true" : "false");
        }
        put(k, ",\"provenance\":");
        put_str(k, item->provenance[0] != '\0'
                   ? item->provenance : "guest-ditl");
        put(k, ",\"completeness\":\"complete\"}}");
    }
    put(k, "]");
}

static void put_windows(Sink *k, const NowScene *s)
{
    short i;

    put(k, ",\"windows\":[");
    for (i = 0; i < s->window_count; ++i) {
        const NowSceneWindow *w = &s->windows[i];
        const NowSceneProc *p = &s->procs[w->proc];
        char rect[64];

        put(k, i > 0 ? ",{\"id\":" : "{\"id\":");
        put_str(k, w->id);
        put(k, ",\"app\":");
        put_str(k, p->name);
        put(k, ",\"psn\":");
        put_psn(k, &p->psn);
        put(k, ",\"title\":");
        put_str(k, w->title);
        snprintf(rect, sizeof rect, ",\"rect\":{\"l\":%d,\"t\":%d,\"r\":%d,"
                 "\"b\":%d}", (int)w->rect.l, (int)w->rect.t, (int)w->rect.r,
                 (int)w->rect.b);
        put(k, rect);
        put(k, ",\"front\":");
        put(k, w->front ? "true" : "false");
        put(k, ",\"z\":");
        put_num(k, w->z);
        put(k, ",\"visible\":");
        put(k, w->visible ? "true" : "false");
        /* An ADDITION to IR v1's window field set, taken under the
           accretive rule (additive fields do not move the version). A
           window is the other thing an act can name - `windowact` takes
           a window reference, not a control's - so a scene that named
           only controls would leave half the act plane unaddressable. */
        put_ref(k, w->ref);
        /* The window record's address: the exact join key between this
           scene and the machine, for a differ that has to decide which
           reported window IS which real one. Absent when the producer
           could not say, because a 0 would read as an address. */
        if (w->addr != 0) {
            char addr[32];

            snprintf(addr, sizeof addr, ",\"addr\":%lu",
                     (unsigned long)w->addr);
            put(k, addr);
        }
        if (p->incarnation != 0 && w->addr != 0) {
            char incarnation[80];

            snprintf(incarnation, sizeof incarnation,
                     ",\"incarnation\":\"process-%08lx/window-%08lx\"",
                     p->incarnation & 0xffffffffUL,
                     w->addr & 0xffffffffUL);
            put(k, incarnation);
        }
        /* The walked sub-planes, each present only for the rows whose
           walk ran and completed. `display` and `items` are still absent
           everywhere: this producer does not report them at all, and an
           empty array would say it looked and found none. */
        if (w->kind_known) {
            put(k, ",\"kind\":");
            put_num(k, w->kind);
        }
        put_controls(k, s, w);
        put_dialog_items(k, s, w);
        if (w->text >= 0 && w->text < s->text_count) {
            const NowSceneText *x = &s->texts[w->text];

            put(k, ",\"text\":{\"content\":");
            put_str(k, x->content);
            put(k, ",\"active\":");
            put(k, x->active ? "true" : "false");
            /* Not IR v1's field set: `truncated` is this producer saying
               the content is a PREFIX, which the IR has no word for and
               a consumer must not have to infer from a length. Additive,
               so the version does not move (IR-V1.md). */
            if (x->truncated) {
                put(k, ",\"truncated\":true");
            }
            put(k, "}");
        }
        put(k, "}");
    }
    put(k, "]");
}

static const char *coverage_status(NowSceneCoverage coverage)
{
    switch (coverage) {
    case kNowSceneCoverageComplete: return "complete";
    case kNowSceneCoveragePartial: return "partial";
    case kNowSceneCoverageRetracted: return "retracted";
    case kNowSceneCoverageFailed: return "failed";
    case kNowSceneCoverageStale: return "stale";
    default: return "unavailable";
    }
}

static const char *coverage_reason(NowSceneCoverage coverage)
{
    switch (coverage) {
    case kNowSceneCoveragePartial: return "bounded";
    case kNowSceneCoverageRetracted: return "validation";
    case kNowSceneCoverageFailed: return "read-failed";
    case kNowSceneCoverageStale: return "stale-anchor";
    case kNowSceneCoverageUnavailable: return "not-observed";
    default: return NULL;
    }
}

static void put_coverage_claim(Sink *k, const char *scope,
                               const NowSceneProc *owner,
                               NowSceneCoverage coverage, int first)
{
    const char *reason = coverage_reason(coverage);

    put(k, first ? "{\"scope\":" : ",{\"scope\":");
    put_str(k, scope);
    if (owner != NULL && owner->incarnation != 0) {
        put(k, ",\"owner\":");
        put_process_incarnation(k, owner->incarnation);
    }
    put(k, ",\"status\":");
    put_str(k, coverage_status(coverage));
    if (reason != NULL) {
        put(k, ",\"reason\":");
        put_str(k, reason);
    }
    put(k, "}");
}

static void put_coverage(Sink *k, const NowScene *s)
{
    short i;
    const NowSceneProc *front = NULL;
    NowSceneCoverage menubar_coverage;

    put(k, ",\"coverage\":[");
    put_coverage_claim(k, "processes", NULL, s->processes_coverage, 1);
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];

        put_coverage_claim(k, "windows", p, p->windows_coverage, 0);
        if (p->front) {
            front = p;
        }
    }
    if (s->menubar_refused) {
        menubar_coverage = kNowSceneCoverageRetracted;
    } else if (s->menubar_present
               && (s->menus_truncated || s->menu_items_truncated)) {
        menubar_coverage = kNowSceneCoveragePartial;
    } else if (s->menubar_present) {
        menubar_coverage = kNowSceneCoverageComplete;
    } else {
        menubar_coverage = kNowSceneCoverageUnavailable;
    }
    put_coverage_claim(k, "menubar", front, menubar_coverage, 0);
    put(k, "]");
}

/* meta.errors carries what the scene could not do, in upstream's
   "<name>: <token>" form, plus this producer's own truncation notices.
   A truncated walk that said nothing would be a partial scene delivered
   as a complete one, which is the one thing a scene must never be. */
static void put_meta(Sink *k, const NowScene *s)
{
    short i;
    int first = 1;

    put(k, ",\"meta\":{\"errors\":[");
    for (i = 0; i < s->proc_count; ++i) {
        const char *err = now_scene_proc_error(&s->procs[i]);
        char line[kNowSceneNameMax + 40];

        if (err == NULL) {
            continue;
        }
        snprintf(line, sizeof line, "%s: %s", s->procs[i].name, err);
        put(k, first ? "" : ",");
        put_str(k, line);
        first = 0;
    }
    if (s->procs_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "processes truncated: the machine had more than this "
                "scene carries");
        first = 0;
    }
    if (s->windows_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "windows truncated: the machine had more than this "
                "scene carries");
        first = 0;
    }
    if (s->menubar_refused) {
        put(k, first ? "" : ",");
        put_str(k, "menubar omitted: the front process's menu list did not "
                "parse, so no menu bar is reported rather than an empty one");
        first = 0;
    }
    if (s->menus_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "menus truncated: the menu bar had more than this "
                "scene carries");
        first = 0;
    }
    /* The three retraction notices. Each says the same thing in its own
       plane's words: a list stopped early, and rather than ship a short
       one that reads as complete, the key was dropped for that owner.
       Without these a retracted plane would be indistinguishable from a
       plane that was never walked, which is the one confusion the whole
       present-vs-absent split exists to prevent. */
    if (s->controls_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "controls omitted: a window's control list hit a bound "
                "or failed validation, so that window reports no controls "
                "rather than some of them");
        first = 0;
    }
    if (s->list_cells_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "list cells truncated: structured list content exceeded "
                "the scene pool and remains partial");
        first = 0;
    }
    if (s->dialog_items_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "dialog items omitted: the live DITL hit a bound or "
                "failed validation, so no partial item plane was emitted");
        first = 0;
    }
    if (s->menu_items_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "menu items omitted: a menu's item list hit a bound or "
                "failed validation, so that menu reports no items rather "
                "than some of them");
        first = 0;
    }
    if (s->texts_truncated) {
        put(k, first ? "" : ",");
        put_str(k, "window text omitted: more windows carried editable text "
                "than this scene carries");
        first = 0;
    }
    put(k, "]");
    put_coverage(k, s);
    if (s->plane[0] != '\0') {
        put(k, ",\"plane\":");
        put_str(k, s->plane);
    }
    if (s->latency_ms >= 0) {
        put(k, ",\"latencyMs\":");
        put_num(k, s->latency_ms);
    }
    /* WHERE THE TIME WENT, and it is ABSENT rather than zeroed when this
       producer did not measure. That distinction is the same one the IR
       already makes everywhere else: an absent `phases` says "this
       producer does not report phases", never "these phases took no
       time". Eight zeroes would be a measurement, and a false one.
       See scene_phase.h and contract/asyncapi.yaml. */
    if (now_scene_phase_reporting()) {
        int p;

        put(k, ",\"phases\":{\"us\":{");
        for (p = 0; p < kNowScenePhaseCount; ++p) {
            if (p) {
                put(k, ",");
            }
            put_str(k, now_scene_phase_name(p));
            put(k, ":");
            put_num(k, (long)now_scene_phase_us(p));
        }
        /* The breakdown's own weight, published beside the numbers it
           produced so nobody has to take "cheap enough to leave on" on
           trust. clockUs is the read count at the calibrated per-read
           price - an estimate, and named one in the contract. */
        put(k, "},\"clockReads\":");
        put_num(k, (long)now_scene_phase_clock_reads());
        put(k, ",\"clockUs\":");
        put_num(k, (long)now_scene_phase_clock_us());
        put(k, ",\"faults\":");
        put_num(k, (long)now_scene_phase_faults());
        put(k, "}");
    }
    /* `bytes` is absent, not zero: it is the encoded size, and the
       encode is what is happening right now. */
    put(k, "}");
}

NowSceneEncodeStatus now_scene_encode(const NowScene *s, char *out, long cap,
                                      long *needed)
{
    Sink k;

    if (needed != NULL) {
        *needed = 0;
    }
    if (s == NULL) {
        return kNowSceneEncodeOverflow;
    }
    memset(&k, 0, sizeof k);
    k.out = (cap > 0) ? out : NULL;
    k.cap = (out != NULL) ? cap : 0;

    put(&k, "{\"version\":");
    put_num(&k, s->version);
    put(&k, ",\"seq\":");
    put_num(&k, s->seq);
    put(&k, ",\"capturedAt\":");
    put_captured_at(&k, s->captured_at);
    put(&k, ",\"source\":");
    put_str(&k, s->source);
    put(&k, ",\"screen\":{\"w\":");
    put_num(&k, s->screen_w);
    put(&k, ",\"h\":");
    put_num(&k, s->screen_h);
    put(&k, "}");
    put_apps(&k, s);
    put_processes(&k, s);
    put_menubar(&k, s);
    put_windows(&k, s);
    put_meta(&k, s);
    put(&k, "}");

    if (needed != NULL) {
        *needed = k.len + 1;      /* the terminator */
    }
    if (k.over || k.out == NULL) {
        if (out != NULL && cap > 0) {
            out[0] = '\0';        /* fail closed: never half a scene */
        }
        return kNowSceneEncodeOverflow;
    }
    out[k.len] = '\0';
    return kNowSceneEncodeOk;
}

long now_scene_encoded_size(const NowScene *s)
{
    long needed = 0;

    (void)now_scene_encode(s, NULL, 0, &needed);
    return needed;
}
