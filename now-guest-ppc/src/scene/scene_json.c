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
    char esc[4 * kNowSceneIdMax];

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
        /* No `controls`, no `text`, no `kind`, no `display`: this
           producer does not report them, and an empty array would say it
           looked and found none. */
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
