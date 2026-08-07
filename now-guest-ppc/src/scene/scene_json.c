#include "scene.h"

#include <stdio.h>
#include <string.h>

#include "axwalk.h"    /* NowAxDefProcOrigin: scene.h stores one as a short */
#include "control_cdef.h"  /* NowCdefState, and the documented CDEF table */
#include "json.h"
#include "scene_digest.h"
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
    /* WHERE EACH PIECE LANDED, filled only when a caller asks for it.
       The delta plane needs to name one window's bytes without knowing
       how a window is encoded, and this is the seam that keeps that
       knowledge here: scene_digest.c is handed offsets and never learns
       the shape of what it is copying. NULL costs one branch per piece
       and changes nothing about the bytes. */
    NowSceneSpans *sp;
} Sink;

/* Marks are taken from `len`, which counts identically in the sizing and
   the writing pass - so an offset is right in both. A HASH is not: it
   needs the bytes, so it is taken only when this pass actually wrote
   them and stays 0 otherwise. A caller that used a sizing pass's spans
   for anything but sizes would be comparing zeroes. */
static void entity_end(Sink *k, NowSceneSpan *e, long off, const char *key)
{
    if (e == NULL) {
        return;
    }
    e->off = off;
    e->len = k->len - off;
    e->hash = (k->out != NULL && !k->over)
        ? now_scene_fnv1a(kNowSceneFnvSeed, k->out + off, e->len) : 0;
    if (key == NULL || key[0] == '\0') {
        e->key[0] = '\0';
        if (k->sp != NULL) {
            k->sp->keyed_all = 0;
        }
    } else {
        strncpy(e->key, key, kNowSceneKeyMax - 1);
        e->key[kNowSceneKeyMax - 1] = '\0';
    }
}

/* An entity's key is its IR incarnation and nothing else. A row without
   one gets an empty key, which clears keyed_all and makes the whole
   scene ineligible as a delta baseline - deliberately, because
   MirrorReplicaReducer already refuses to key an incarnation-less row
   into its durable maps. A row the reducer will not key is a row a delta
   must not key either. */
static void proc_key(char *out, const NowSceneProc *p)
{
    if (p->incarnation == 0) {
        out[0] = '\0';
        return;
    }
    snprintf(out, kNowSceneKeyMax, "process-%08lx",
             p->incarnation & 0xffffffffUL);
}

static void window_key(char *out, const NowSceneProc *p,
                       const NowSceneWindow *w)
{
    if (p->incarnation == 0 || w->addr == 0) {
        out[0] = '\0';
        return;
    }
    snprintf(out, kNowSceneKeyMax, "process-%08lx/window-%08lx",
             p->incarnation & 0xffffffffUL, w->addr & 0xffffffffUL);
}

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

    put(k, ",\"apps\":");
    if (k->sp != NULL) {
        k->sp->apps_off = k->len;
    }
    put(k, "[");
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];
        const char *err = now_scene_proc_error(p);
        long at;
        char key[kNowSceneKeyMax];

        if (i > 0) {
            put(k, ",");
        }
        at = k->len;
        put(k, "{\"psn\":");
        put_psn(k, &p->psn);
        put(k, ",\"name\":");
        put_str(k, p->name);
        put(k, ",\"front\":");
        put(k, p->front ? "true" : "false");
        /* Present only when TRUE, like `isSelf` on ProcessListing: absence
           means the process did not declare `modeOnlyBackground`, and 24
           rows do not each pay for a false. It is the process's own
           statement that it has no user interface - never a conclusion
           drawn from an empty window list, which cannot tell "no UI by
           design" from "we failed to look". */
        if (p->background_only) {
            put(k, ",\"backgroundOnly\":true");
        }
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
        proc_key(key, p);
        entity_end(k, (k->sp != NULL) ? &k->sp->apps[i] : NULL, at, key);
    }
    put(k, "]");
    if (k->sp != NULL) {
        k->sp->apps_len = k->len - k->sp->apps_off;
        k->sp->app_count = s->proc_count;
    }
}

static void put_processes(Sink *k, const NowScene *s)
{
    short i;

    put(k, ",\"processes\":");
    if (k->sp != NULL) {
        k->sp->procs_off = k->len;
    }
    put(k, "[");
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];
        long at;
        char key[kNowSceneKeyMax];

        if (i > 0) {
            put(k, ",");
        }
        at = k->len;
        put(k, "{\"psn\":");
        put_psn(k, &p->psn);
        put(k, ",\"name\":");
        put_str(k, p->name);
        put(k, ",\"front\":");
        put(k, p->front ? "true" : "false");
        put(k, ",\"signature\":");
        put_signature(k, p->signature);
        if (p->background_only) {
            put(k, ",\"backgroundOnly\":true");
        }
        if (p->incarnation != 0) {
            put(k, ",\"incarnation\":");
            put_process_incarnation(k, p->incarnation);
        }
        put(k, "}");
        proc_key(key, p);
        entity_end(k, (k->sp != NULL) ? &k->sp->procs[i] : NULL, at, key);
    }
    put(k, "]");
    if (k->sp != NULL) {
        k->sp->procs_len = k->len - k->sp->procs_off;
        k->sp->proc_count = s->proc_count;
    }
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
    put(k, ",\"menubar\":");
    if (k->sp != NULL) {
        k->sp->menubar_off = k->len;
    }
    put(k, "{\"app\":");
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
    if (k->sp != NULL) {
        k->sp->menubar_len = k->len - k->sp->menubar_off;
    }
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

/* The role the CDEF route supports for a control the Control Manager
   would not name, or NULL. It is consulted ONLY where `role` is empty:
   a control that told us what it is outranks the identity of the code
   that draws it, and averaging the two would be the laundering this
   whole split exists to prevent. */
static const char *derived_role(const NowSceneControl *c)
{
    if (c->cdef_state != (short)kNowCdefNamed) {
        return NULL;
    }
    return now_cdef_role(c->cdef_id, c->cdef_variant);
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
    if (strcmp(role, "tab") == 0) return "tab";
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
    /* A TAB and a LIST BOX both answer to a click at a POINT, and until
       2026-08-07 neither had an action at all - so `authorizesAction` was
       false and every driver declined them, which is most of what
       "lists, scrollbars and tabs render now but they cant be used"
       named. `press` is the honest word for both: the act is a mouse
       click the owning application routes through its own handler, the
       same mechanism a push button uses. Which tab, and which row, is
       decided by WHERE - so a caller sends `ctlact` a point, and the
       point is what makes these two rows worth having. */
    if (strcmp(role, "tab") == 0) return "press";
    if (strcmp(role, "listBox") == 0) return "press";
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
    /* WHAT IS KNOWN ABOUT THEM, beside the list rather than inside it.
     *
       The array below cannot carry this. It is required by the IR, so
       "not looked at" and "looked at, none there" both arrive as `[]`,
       and since 2026-08-07 a third fact has been hiding in the same two
       characters: a window walked after the shared pool filled reports
       `[]` for a reason that has nothing to do with that window. The
       verdict prose in meta.errors says which, in a sentence, keyed on a
       window TITLE - readable by a person and by nothing else.
       This is the same knowledge as a word a consumer branches on.

       EMITTED ONLY WHERE THE ARRAY CANNOT SPEAK FOR ITSELF - that is,
       whenever it is empty. A non-empty array is `complete` by
       construction and no other state can produce one, so spending 28
       bytes per window to say so costs 900 of a 64 KB ceiling this scene
       already touches (measured: the ceiling case went to 66447 bytes
       and the gate caught it). This is scene.h's own `backgroundOnly`
       rule, made for the same arithmetic - and it is safe here for the
       reason that one had to argue: absence is not ambiguous, because
       the array beside it decides which reading applies. */
    if (!(w->controls_present && w->control_count > 0)) {
        put(k, ",\"controlsState\":");
        switch (now_scene_controls_state(w)) {
        case kNowSceneControlsEmpty:   put_str(k, "empty"); break;
        case kNowSceneControlsUnknown: put_str(k, "unknown"); break;
        default:                       put_str(k, "notFetched"); break;
        }
    }
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
        /* A derived role rides here too. This field is documented as the
           APPROXIMATION a v1-era renderer draws from, and "the Toolbox
           runs the scroll bar CDEF for this control" is a strictly better
           approximation than the word `unknown` - which is what every
           OS 9 control panel's controls carried before the CDEF route
           existed. The semantic object below still says which of the two
           it was. */
        put_str(k, c->role[0] != '\0' ? c->role
                                      : (derived_role(c) != NULL
                                         ? derived_role(c) : "unknown"));
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
        if (c->role[0] == '\0' && derived_role(c) != NULL) {
            /* THE THIRD STATE, and it is deliberately not `known`.
               `known` is the control answering about itself through
               `kControlKindTag`; this is the Resource Manager naming the
               CDEF that draws it and this guest looking the id up in a
               header. That is the machine stating something rather than
               us guessing - which is why it may carry an action at all -
               and it is still one remove from the control's own word,
               which is why it may not be spelled the same. A reader that
               cannot tell them apart is reading a document that no longer
               says which it got. */
            const char *role = derived_role(c);
            const char *action = control_action(role);

            put_str(k, "derived");
            put(k, ",\"kind\":");
            put_str(k, control_kind(role));
            if (action != NULL) {
                put(k, ",\"action\":");
                put_str(k, action);
            }
            if (control_has_state(role)) {
                put(k, ",\"state\":");
                put_str(k, c->value != 0 ? "on" : "off");
            }
            /* NO `semantic.value` HERE, and its absence is the answer.
               The CDEF id names a KIND; it does not read a control's
               contents, so this branch has nothing to say about them.
               `semantic.value` is the control's own words - the text in
               the field, the item chosen in the menu - and every consumer
               DRAWS it. Emitting `GetControlValue` into it published the
               integer 0 as the text of every static field and every user
               pane, and on 2026-08-07 that erased the whole Appearance
               panel: its root pane came back captioned "0" and, being the
               last control in the chain, painted over all six tabs.

               The number is not lost and never was - it rides the
               control's own `value` key a few lines above, where it means
               what the Control Manager means. Saying it twice under two
               meanings is how it came to be read as prose. */
            put(k, ",\"provenance\":\"guest-cdef-resource\","
                   "\"completeness\":\"complete\"}}");
            continue;
        }
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
            /* WHY nobody could say, when the guest knows. The semantic
               client computes exactly this - "Unsupported custom
               control", "Control kind undetermined", "Semantic
               classification unavailable" - and until 2026-08-07 it was
               emitted ONLY beside a role, which is the one case where it
               is least needed. So every unclassified control reached the
               host as a bare `unknown` and the guest's own diagnosis of
               its own gap was dropped on the floor: 71 of Appearance's 73
               controls read identically whether the resident had refused
               them, never reached them, or been asked at all.

               It is a REASON, not a value, and it rides the existing
               field rather than a new one because that field already
               carries this class of string beside a known role. A reader
               must not promote it into a kind: knowledge is still
               `unknown` here and that is the load-bearing key. */
            if (c->semantic_value_known) {
                put(k, ",\"value\":");
                put_str(k, c->semantic_value);
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

    put(k, ",\"windows\":");
    if (k->sp != NULL) {
        k->sp->windows_off = k->len;
    }
    put(k, "[");
    for (i = 0; i < s->window_count; ++i) {
        const NowSceneWindow *w = &s->windows[i];
        const NowSceneProc *p = &s->procs[w->proc];
        char rect[64];
        char key[kNowSceneKeyMax];
        long at;

        if (i > 0) {
            put(k, ",");
        }
        at = k->len;
        put(k, "{\"id\":");
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
        window_key(key, p, w);
        entity_end(k, (k->sp != NULL) ? &k->sp->windows[i] : NULL, at, key);
    }
    put(k, "]");
    if (k->sp != NULL) {
        k->sp->windows_len = k->len - k->sp->windows_off;
        k->sp->window_count = s->window_count;
    }
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

static const char *coverage_reason(NowSceneCoverage coverage,
                                   const NowSceneProc *owner)
{
    /* "not-observed" is the right word for an application we could not
       look inside, and the WRONG one for a process that declared it has
       no user interface: there was nothing there to observe. Same
       status - we did not enumerate - but a consumer deciding whether a
       gap is a defect needs the reason, and `no-ui` says the gap is the
       machine working correctly. */
    if (coverage == kNowSceneCoverageUnavailable
        && owner != NULL && owner->background_only) {
        return "no-ui";
    }
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
                               NowSceneCoverage coverage, int first,
                               unsigned long evicted)
{
    const char *reason = coverage_reason(coverage, owner);

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
    /* HOW MANY THIS CLAIM'S LEDGER FORGOT. Only the `depth` scope has
       one, and it rides only when nonzero: 0 is the ordinary case and a
       key present on every claim in every scene would cost more than it
       says. What it buys is the difference between "we never saw this
       process come forward" and "we saw it and then forgot", which is
       the empty-versus-unknown split this IR makes everywhere else and
       could not make here. */
    if (evicted != 0) {
        put(k, ",\"evicted\":");
        put_num(k, (long)evicted);
    }
    put(k, "}");
}

static void put_coverage(Sink *k, const NowScene *s)
{
    short i;
    const NowSceneProc *front = NULL;
    NowSceneCoverage menubar_coverage;

    put(k, ",\"coverage\":");
    if (k->sp != NULL) {
        k->sp->coverage_off = k->len;
    }
    put(k, "[");
    put_coverage_claim(k, "processes", NULL, s->processes_coverage, 1, 0);
    /* ONE CLAIM FOR THE WHOLE ROSTER, and the reason `backgroundOnly` can
       stay true-only: this says whether an absent key means "has a face"
       or "nobody asked". See NowScene.process_kind_coverage. */
    put_coverage_claim(k, "process-kind", NULL,
                       s->process_kind_coverage, 0, 0);
    /* AND ONE FOR THE ORDER THE ARRAY ITSELF CARRIES. Every other claim
       here is about a list's membership; this one is about its
       SEQUENCE, which is meaning too - the front process is first - and
       until now was the one piece of the scene that could be wrong with
       nothing saying so. See NowScene.depth_coverage. */
    put_coverage_claim(k, "depth", NULL, s->depth_coverage, 0,
                       s->depth_evicted);
    for (i = 0; i < s->proc_count; ++i) {
        const NowSceneProc *p = &s->procs[i];

        put_coverage_claim(k, "windows", p, p->windows_coverage, 0, 0);
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
    put_coverage_claim(k, "menubar", front, menubar_coverage, 0, 0);
    put(k, "]");
    if (k->sp != NULL) {
        k->sp->coverage_len = k->len - k->sp->coverage_off;
    }
}

/* meta.theme: the colours the MACHINE gave, as `#RRGGBB` strings.
 *
 * A string rather than a number because a colour read out of a capture
 * by a person is going to be compared against a hex pixel, and
 * `14540253` is not that. Every key is omitted when the ask failed, and
 * the whole object is omitted when nothing was asked - so a consumer
 * meeting no `theme` knows this producer did not ask, and one meeting
 * `theme` without `alertBackground` knows the ask was made and refused.
 * Those are different facts and the old single constant could carry
 * neither. See scene.h, NowSceneTheme. */
static void put_theme_key(Sink *k, int *first, const char *name, long rgb)
{
    char hex[10];

    if (rgb < 0) {
        return;
    }
    put(k, *first ? "" : ",");
    put_str(k, name);
    put(k, ":");
    snprintf(hex, sizeof hex, "#%02lX%02lX%02lX",
             (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    put_str(k, hex);
    *first = 0;
}

static void put_theme(Sink *k, const NowScene *s)
{
    int first = 1;

    if (s->theme.dialog_background < 0 && s->theme.alert_background < 0
        && s->theme.document_background < 0 && s->theme.highlight < 0) {
        return;
    }
    put(k, ",\"theme\":{");
    put_theme_key(k, &first, "dialogBackground", s->theme.dialog_background);
    put_theme_key(k, &first, "alertBackground", s->theme.alert_background);
    put_theme_key(k, &first, "documentBackground",
                  s->theme.document_background);
    put_theme_key(k, &first, "highlight", s->theme.highlight);
    if (s->theme.depth >= 0) {
        put(k, first ? "" : ",");
        put(k, "\"depth\":");
        put_num(k, (long)s->theme.depth);
    }
    put(k, "}");
}

/* meta.desktop: what the MACHINE says its desktop is drawn from.
 *
 * The whole object is omitted when this producer never asked, which is
 * the same absent-means-unknown rule meta.theme follows - and it is
 * load-bearing here rather than tidy. The consumer's alternative source
 * is an offline asset pack's record of the disk image it was extracted
 * from, which is true only for a guest booted from that image and
 * unchanged since. A consumer that cannot tell "the machine said so"
 * from "nobody asked" cannot tell which of those two it is looking at,
 * and would render the pack's answer as the machine's.
 *
 * `source: unknown` with `asked` true is a DIFFERENT fact and it does
 * reach the wire: we asked, and this machine would not say. That one is
 * the marked unknown; the absent key is the substitution.
 *
 * The names are what the machine CHOSE. They are not art - the flattened
 * `ppat` bytes the command verb carries as hex are an identity, and the
 * pixels come from the pack either way. Naming is exactly the job:
 * it lets a consumer check whether the art it holds is the art this
 * machine is showing, instead of assuming it. */
static void put_desktop(Sink *k, const NowScene *s)
{
    if (!s->desktop.asked) {
        return;
    }
    put(k, ",\"desktop\":{\"source\":");
    switch (s->desktop.source) {
    case kDesktopSourcePattern: put_str(k, "pattern"); break;
    case kDesktopSourcePicture: put_str(k, "picture"); break;
    default:                    put_str(k, "unknown"); break;
    }
    put(k, ",\"hasPattern\":");
    put(k, s->desktop.has_pattern ? "true" : "false");
    put(k, ",\"hasPicture\":");
    put(k, s->desktop.has_picture ? "true" : "false");
    if (s->desktop.pattern_bytes >= 0) {
        put(k, ",\"patternBytes\":");
        put_num(k, s->desktop.pattern_bytes);
    }
    /* An empty name is an ABSENT tag, not a nameless desktop, so it is
       omitted rather than sent as "". */
    if (s->desktop.pattern_name[0] != '\0') {
        put(k, ",\"patternName\":");
        put_str(k, s->desktop.pattern_name);
    }
    if (s->desktop.picture_name[0] != '\0') {
        put(k, ",\"pictureName\":");
        put_str(k, s->desktop.picture_name);
    }
    put(k, "}");
}

/* meta.errors carries what the scene could not do, in upstream's
   "<name>: <token>" form, plus this producer's own truncation notices.
   A truncated walk that said nothing would be a partial scene delivered
   as a complete one, which is the one thing a scene must never be. */
static void put_meta(Sink *k, const NowScene *s)
{
    short i;
    int first = 1;

    put(k, ",\"meta\":{\"errors\":");
    if (k->sp != NULL) {
        k->sp->errors_off = k->len;
    }
    put(k, "[");
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
    /* WHICH WINDOW, by name. The sentences above and below say a plane
       was dropped somewhere in this scene; these say where. A driving
       agent meeting `controls: []` on a panel it can see six tabs in
       otherwise has no way to tell an empty window from an unread one -
       measured on the Appearance control panel, 2026-08-07, which
       published zero controls and zero dialog items with nothing naming
       it. Emitted per window rather than folded into one line because
       two silent windows are two separate errands. */
    for (i = 0; i < s->window_count; ++i) {
        const NowSceneWindow *w = &s->windows[i];
        /* +240, not +160: the longest reason below is ~170 characters and
           the chain figures add ~45 more. It was sized for the reason
           alone, so the number this line exists to carry would have been
           the part snprintf dropped. */
        char line[kNowSceneTitleMax + 240];
        const char *why;

        switch (w->walk_verdict) {
        case kNowSceneWalkRecordUnreadable:
            why = "window record failed validation, so no control or item "
                  "plane was attempted - absent here means unknown, "
                  "not empty";
            break;
        case kNowSceneWalkControlsBound:
            why = "control chain is longer than this scene carries, so its "
                  "controls are unknown rather than absent - the bound is "
                  "ours, not the machine's";
            break;
        case kNowSceneWalkControlsCyclic:
            why = "control chain did not end within the diagnostic probe "
                  "bound, so it is cyclic or corrupt rather than merely "
                  "long - raising a cap would not reach it";
            break;
        case kNowSceneWalkControlsInvalid:
            why = "control chain failed validation: a record left the "
                  "readable zones, so its controls are unknown rather than "
                  "absent and the fault is where we are allowed to look";
            break;
        case kNowSceneWalkControlsRetracted:
            why = "control chain hit a bound or failed validation, so its "
                  "controls are unknown rather than absent";
            break;
        case kNowSceneWalkControlsPoolFull:
            why = "the scene's shared control pool was already full when "
                  "this window was walked, so its controls were NOT FETCHED "
                  "rather than unknown - nothing here is a fact about this "
                  "window, and asking again with room would answer it";
            break;
        case kNowSceneWalkDialogItemsRetracted:
            why = "dialog item list hit a bound or failed validation, so "
                  "its items are unknown rather than absent";
            break;
        case kNowSceneWalkControlsAndItemsRetracted:
            why = "both the control chain and the dialog item list failed, "
                  "so nothing in this window is addressable and the reason "
                  "is the walk, not the window";
            break;
        default:
            continue;
        }
        /* THE NUMBER, beside the reason. "The bound is ours" told a
           reader which half of the system to look at and left them to
           measure the other half by hand - which is exactly what the
           Appearance investigation had to do to learn that the chain was
           73 against a bound of 48. Both figures are in the guest's hand
           here, so both go on the line, and a floor says it is one. */
        if (w->control_chain_len > 0
            && (w->walk_verdict == kNowSceneWalkControlsBound
                || w->walk_verdict == kNowSceneWalkControlsInvalid
                || w->walk_verdict == kNowSceneWalkControlsCyclic
                /* The pool-full case measures its chain too, and for the
                   sharper reason: sizing the pool needs the DISTRIBUTION
                   across the windows that lost, not one panel's number. */
                || w->walk_verdict == kNowSceneWalkControlsPoolFull)) {
            snprintf(line, sizeof line, "%s: %s (chain is %s%d, this scene "
                     "carries %d)",
                     w->title[0] != '\0' ? w->title : "(untitled window)",
                     why, w->control_chain_len_exact ? "" : "at least ",
                     (int)w->control_chain_len, (int)kNowSceneMaxControls);
        } else {
            snprintf(line, sizeof line, "%s: %s",
                     w->title[0] != '\0' ? w->title : "(untitled window)",
                     why);
        }
        put(k, first ? "" : ",");
        put_str(k, line);
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
    if (k->sp != NULL) {
        k->sp->errors_len = k->len - k->sp->errors_off;
    }
    put_coverage(k, s);
    if (k->sp != NULL) {
        k->sp->tail_off = k->len;
    }
    put_theme(k, s);
    put_desktop(k, s);
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
    if (k->sp != NULL) {
        k->sp->tail_len = k->len - k->sp->tail_off;
    }
    /* `bytes` is absent, not zero: it is the encoded size, and the
       encode is what is happening right now. */
    put(k, "}");
}

NowSceneEncodeStatus now_scene_encode(const NowScene *s, char *out, long cap,
                                      long *needed)
{
    return now_scene_encode_spans(s, out, cap, needed, NULL);
}

NowSceneEncodeStatus now_scene_encode_spans(const NowScene *s, char *out,
                                            long cap, long *needed,
                                            NowSceneSpans *spans)
{
    Sink k;

    if (needed != NULL) {
        *needed = 0;
    }
    if (spans != NULL) {
        memset(spans, 0, sizeof *spans);
        /* Starts TRUE and is cleared by the first unkeyed entity. The
           other way round - proving every row keyed at the end - would
           need a second walk of the tables to say the same thing. */
        spans->keyed_all = 1;
    }
    if (s == NULL) {
        return kNowSceneEncodeOverflow;
    }
    memset(&k, 0, sizeof k);
    k.out = (cap > 0) ? out : NULL;
    k.cap = (out != NULL) ? cap : 0;
    k.sp = spans;

    put(&k, "{\"version\":");
    put_num(&k, s->version);
    put(&k, ",\"seq\":");
    put_num(&k, s->seq);
    put(&k, ",\"capturedAt\":");
    put_captured_at(&k, s->captured_at);
    put(&k, ",\"source\":");
    if (spans != NULL) {
        spans->source_off = k.len;
    }
    put_str(&k, s->source);
    if (spans != NULL) {
        spans->source_len = k.len - spans->source_off;
    }
    put(&k, ",\"screen\":");
    if (spans != NULL) {
        spans->screen_off = k.len;
    }
    put(&k, "{\"w\":");
    put_num(&k, s->screen_w);
    put(&k, ",\"h\":");
    put_num(&k, s->screen_h);
    put(&k, "}");
    if (spans != NULL) {
        spans->screen_len = k.len - spans->screen_off;
    }
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
