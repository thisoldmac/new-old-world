#include "scene.h"

#include <stdio.h>
#include <string.h>

#include "json.h"

/* The IR v1 encoder.

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
static void put_ref(Sink *k, const char *ref)
{
    if (ref == NULL || ref[0] == '\0') {
        return;
    }
    put(k, ",\"ref\":");
    put_str(k, ref);
}

/* A window's controls, and only for a window whose whole chain was
   walked. `role` and `checked` are absent throughout: the walk reads a
   ControlRecord, not its defProc, so it cannot say what KIND of control
   this is, and `checked` is meaningless without that. `ref` is present
   for every control the reference layer could name and absent for the
   rest. */
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

        /* `role` is required by the IR and has exactly two values there:
           "scrollbar" when the control carries a live range, "control"
           otherwise. The walk reads a ControlRecord and not its defProc,
           so it cannot say button-vs-checkbox - and the IR does not ask
           it to. A range is the one distinction this reader can make
           honestly, and it is the one the IR draws. */
        put(k, i > 0 ? ",{\"role\":" : "{\"role\":");
        put_str(k, c->min != c->max ? "scrollbar" : "control");
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
        put_ref(k, c->ref);
        put(k, "}");
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
        /* The walked sub-planes, each present only for the rows whose
           walk ran and completed. `display` and `items` are still absent
           everywhere: this producer does not report them at all, and an
           empty array would say it looked and found none. */
        if (w->kind_known) {
            put(k, ",\"kind\":");
            put_num(k, w->kind);
        }
        put_controls(k, s, w);
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
    if (s->plane[0] != '\0') {
        put(k, ",\"plane\":");
        put_str(k, s->plane);
    }
    if (s->latency_ms >= 0) {
        put(k, ",\"latencyMs\":");
        put_num(k, s->latency_ms);
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
