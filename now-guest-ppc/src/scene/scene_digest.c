#include "scene_digest.h"

#include <stdio.h>
#include <string.h>

/* The delta plane's arithmetic. Every function here takes an encoded
   document and a table of byte ranges within it and returns a number or
   writes bytes; nothing asks the machine for anything, which is what
   makes tests/scene_digest_test.c able to drive the whole decision on a
   host compiler. See scene_digest.h for why this plane exists. */

unsigned long now_scene_fnv1a(unsigned long seed, const char *bytes, long len)
{
    unsigned long h = seed & 0xffffffffUL;
    long i;

    if (bytes == NULL) {
        return h;
    }
    for (i = 0; i < len; ++i) {
        h ^= (unsigned long)(unsigned char)bytes[i];
        /* The 32-bit FNV prime, spelled as shifts. A `* 16777619` would
           be a 32-bit multiply the compiler is free to do in a wider
           type on one target and not on another, and this hash has to
           agree with a Swift host and a future 68K to the bit. */
        h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))
            & 0xffffffffUL;
    }
    return h;
}

static unsigned long fold_span(unsigned long h, const char *doc,
                               long off, long len)
{
    return now_scene_fnv1a(h, doc + off, len);
}

unsigned long now_scene_body_digest(const char *doc, const NowSceneSpans *sp)
{
    unsigned long h = kNowSceneFnvSeed;

    if (doc == NULL || sp == NULL) {
        return h;
    }
    h = fold_span(h, doc, sp->screen_off, sp->screen_len);
    h = fold_span(h, doc, sp->source_off, sp->source_len);
    h = fold_span(h, doc, sp->apps_off, sp->apps_len);
    h = fold_span(h, doc, sp->procs_off, sp->procs_len);
    if (sp->menubar_len > 0) {
        h = fold_span(h, doc, sp->menubar_off, sp->menubar_len);
    } else {
        /* An ABSENT menu bar hashes to something, and to something a
           present-but-empty one cannot collide with. "menubar absent"
           and "menubar present with no menus" are different claims about
           the machine (contract/asyncapi.yaml), so they must be
           different bytes here or the digest would call them equal. */
        h = now_scene_fnv1a(h, "-", 1);
    }
    h = fold_span(h, doc, sp->windows_off, sp->windows_len);
    h = fold_span(h, doc, sp->coverage_off, sp->coverage_len);
    h = fold_span(h, doc, sp->errors_off, sp->errors_len);
    return h;
}

void now_scene_digest_hex(unsigned long digest, char *out)
{
    if (out == NULL) {
        return;
    }
    snprintf(out, 9, "%08lx", digest & 0xffffffffUL);
}

int now_scene_digest_is(unsigned long digest, const char *hex)
{
    char mine[9];

    if (hex == NULL) {
        return 0;
    }
    now_scene_digest_hex(digest, mine);
    return strcmp(mine, hex) == 0;
}

void now_scene_baseline_clear(NowSceneBaseline *b)
{
    if (b == NULL) {
        return;
    }
    memset(b, 0, sizeof *b);
}

int now_scene_baseline_adopt(NowSceneBaseline *b, const char *doc,
                             const NowSceneSpans *sp, unsigned long digest)
{
    short i;

    if (b == NULL || doc == NULL || sp == NULL) {
        return 0;
    }
    now_scene_baseline_clear(b);
    if (!sp->keyed_all) {
        return 0;
    }
    for (i = 0; i < sp->app_count; ++i) {
        strcpy(b->app_key[i], sp->apps[i].key);
        b->app_hash[i] = sp->apps[i].hash;
    }
    b->app_count = sp->app_count;
    for (i = 0; i < sp->proc_count; ++i) {
        strcpy(b->proc_key[i], sp->procs[i].key);
        b->proc_hash[i] = sp->procs[i].hash;
    }
    b->proc_count = sp->proc_count;
    for (i = 0; i < sp->window_count; ++i) {
        strcpy(b->window_key[i], sp->windows[i].key);
        b->window_hash[i] = sp->windows[i].hash;
    }
    b->window_count = sp->window_count;
    b->menubar_present = (sp->menubar_len > 0);
    b->menubar_hash = b->menubar_present
        ? now_scene_fnv1a(kNowSceneFnvSeed, doc + sp->menubar_off,
                          sp->menubar_len)
        : 0;
    b->digest = digest;
    b->run = 0;
    b->held = 1;
    return 1;
}

/* Where a key sits in one of the baseline's tables, or -1.

   A LINEAR SCAN, and it stays one. The tables are 40 and 64 entries and
   the common case matches at the same index it had last time, so an
   index hint would win nothing a profile could see; a hash table here
   would be a second place for identity to be decided, which is exactly
   the kind of duplicate this project keeps paying for. */
static short find_key(const char keys[][kNowSceneKeyMax], short count,
                      const char *key)
{
    short i;

    for (i = 0; i < count; ++i) {
        if (strcmp(keys[i], key) == 0) {
            return i;
        }
    }
    return -1;
}

/* --- the delta document ------------------------------------------------- */

typedef struct {
    char *out;
    long cap;
    long len;
    int over;
} DSink;

static void dput(DSink *k, const char *s, long n)
{
    if (s == NULL) {
        return;
    }
    if (k->out != NULL && k->len + n < k->cap) {
        memcpy(k->out + k->len, s, (size_t)n);
    } else if (k->out != NULL) {
        k->over = 1;
    }
    k->len += n;
}

static void dputs(DSink *k, const char *s)
{
    dput(k, s, (long)strlen(s));
}

static void dputnum(DSink *k, long v)
{
    char buf[24];

    snprintf(buf, sizeof buf, "%ld", v);
    dputs(k, buf);
}

/* One plane's ordered entries. An entry is `{"k":"..."}` when the
   consumer already holds this entity unchanged in this position, and
   `{"k":"...","v":<the whole entity>}` otherwise. A key the consumer
   holds and that appears in NO entry is absent from this scene - and
   carries no deletion authority of its own, because the consumer
   rebuilds a whole document and the same meta.coverage rule decides. */
static void put_plane(DSink *k, const char *name, const char *doc,
                      const NowSceneSpan *spans, short count,
                      const char keys[][kNowSceneKeyMax],
                      const unsigned long *hashes, short base_count)
{
    short i;

    dputs(k, ",\"");
    dputs(k, name);
    dputs(k, "\":[");
    for (i = 0; i < count; ++i) {
        short at = find_key(keys, base_count, spans[i].key);

        if (i > 0) {
            dputs(k, ",");
        }
        dputs(k, "{\"k\":\"");
        dputs(k, spans[i].key);
        dputs(k, "\"");
        if (at < 0 || hashes[at] != spans[i].hash) {
            dputs(k, ",\"v\":");
            dput(k, doc + spans[i].off, spans[i].len);
        }
        dputs(k, "}");
    }
    dputs(k, "]");
}

long now_scene_delta_encode(const NowSceneBaseline *b, const char *doc,
                            const NowSceneSpans *sp, long seq,
                            double captured_at, const char *baseline_hex,
                            char *out, long cap)
{
    DSink k;
    char buf[32];

    if (b == NULL || doc == NULL || sp == NULL || baseline_hex == NULL) {
        return -1;
    }
    if (!b->held || !sp->keyed_all) {
        return -1;
    }
    memset(&k, 0, sizeof k);
    k.out = (cap > 0) ? out : NULL;
    k.cap = (out != NULL) ? cap : 0;

    dputs(&k, "{\"version\":");
    dputnum(&k, 2);
    dputs(&k, ",\"kind\":\"delta\",\"seq\":");
    dputnum(&k, seq);
    dputs(&k, ",\"baseline\":\"");
    dputs(&k, baseline_hex);
    dputs(&k, "\",\"capturedAt\":");
    snprintf(buf, sizeof buf, "%.1f", captured_at);
    dputs(&k, buf);
    dputs(&k, ",\"source\":");
    dput(&k, doc + sp->source_off, sp->source_len);
    dputs(&k, ",\"screen\":");
    dput(&k, doc + sp->screen_off, sp->screen_len);

    put_plane(&k, "apps", doc, sp->apps, sp->app_count,
              b->app_key, b->app_hash, b->app_count);
    put_plane(&k, "processes", doc, sp->procs, sp->proc_count,
              b->proc_key, b->proc_hash, b->proc_count);

    /* The menu bar is one entity, so it is one of three words rather
       than a list: unchanged, here it is whole, or this scene does not
       report one. An absent menubar is a different claim from an empty
       one and the third word is what keeps them apart. */
    dputs(&k, ",\"menubar\":");
    if (sp->menubar_len <= 0) {
        dputs(&k, b->menubar_present ? "{\"absent\":true}"
                                     : "{\"same\":true}");
    } else {
        unsigned long h = now_scene_fnv1a(kNowSceneFnvSeed,
                                          doc + sp->menubar_off,
                                          sp->menubar_len);

        if (b->menubar_present && b->menubar_hash == h) {
            dputs(&k, "{\"same\":true}");
        } else {
            dputs(&k, "{\"v\":");
            dput(&k, doc + sp->menubar_off, sp->menubar_len);
            dputs(&k, "}");
        }
    }

    put_plane(&k, "windows", doc, sp->windows, sp->window_count,
              b->window_key, b->window_hash, b->window_count);

    /* meta is RESTATED WHOLE, every time. It is small, it changes on
       almost every walk (phases do), and - the load-bearing reason -
       meta.coverage is the only thing that may authorise a deletion. A
       delta that carried coverage by reference would be a delta that
       could delete under a claim nobody restated. */
    dputs(&k, ",\"meta\":{\"errors\":");
    dput(&k, doc + sp->errors_off, sp->errors_len);
    dputs(&k, ",\"coverage\":");
    dput(&k, doc + sp->coverage_off, sp->coverage_len);
    dput(&k, doc + sp->tail_off, sp->tail_len);
    dputs(&k, "}}");

    if (k.over) {
        if (out != NULL && cap > 0) {
            out[0] = '\0';
        }
        return -1;
    }
    if (out != NULL && cap > 0) {
        out[k.len] = '\0';
    }
    return k.len;
}
