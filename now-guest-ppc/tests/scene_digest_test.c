/* Native test for the scene delta plane (src/scene/scene_digest.c and the
 * span table scene_json.c fills for it).
 *
 * WHAT IS ACTUALLY BEING PINNED, because "deltas work" is not a property:
 *
 * 1. THE DIGEST IGNORES WHAT MOVES AND NOTICES WHAT MATTERS. Two walks of
 *    an unchanged machine differ in seq, capturedAt, latencyMs and phases,
 *    and must produce the SAME number - otherwise the no-change answer can
 *    never be given and the whole plane is dead weight. A window that
 *    moved by one pixel must produce a different one.
 *
 * 2. RECONSTRUCTION IS BYTE-EXACT. This test applies a delta the way the
 *    host does - splice the baseline's entity bytes with the delta's - and
 *    requires the result to equal the whole document the guest would have
 *    sent, byte for byte. That equality is the entire resync guarantee;
 *    if it holds here it holds on the wire, and if it does not, the
 *    digest check on the host is checking nothing.
 *
 * 3. AN UNKEYED ROW DISQUALIFIES THE SCENE. A process with no
 *    incarnation cannot be named in a delta, and the scene must refuse to
 *    become a baseline rather than inventing a key. MirrorReplicaReducer
 *    already refuses to key such a row into its durable maps.
 *
 * 4. THE HASH IS THE HASH EVERYONE ELSE COMPUTES. FNV-1a/32 is pinned
 *    against its published vectors, because a hash that drifted would
 *    make each side agree with itself and with nobody else - which is
 *    exactly the class of defect this repository names
 *    two-halves-never-met-in-a-test.
 *
 * Mutation-checked 2026-08-06: each check below was watched failing with
 * the corresponding line of scene_digest.c or scene_json.c reverted.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "scene.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* now_scene_add_window returns SUCCESS, not an index - the row is the
   one just appended. Reading its return as an index silently addressed
   the wrong window and cost the first run of this test. */
static void add_window(NowScene *s, int proc, const char *title, short t,
                       short l, short b, short r, unsigned long addr)
{
    if (now_scene_add_window(s, proc, title, t, l, b, r, 1)) {
        now_scene_set_window_addr(s, s->window_count - 1, addr);
    }
}

/* A small machine: the Finder with two windows and a front application
   with one, every row carrying the incarnation a delta keys on. */
static void build(NowScene *s, long seq, double at, short title_x)
{
    int finder, text;

    now_scene_begin(s, seq, at, "peek", 640, 480, 20000, 0);
    finder = now_scene_add_process(s, 0, 29884417UL, "Finder", 0x4D414353UL,
                                   0, kNowSceneAnchorOk, 19990);
    now_scene_set_process_incarnation(s, finder, 0x1a2b3c4dUL);
    text = now_scene_add_process(s, 0, 32636930UL, "SimpleText",
                                 0x74747874UL, 1, kNowSceneAnchorOk, 19995);
    now_scene_set_process_incarnation(s, text, 0x55667788UL);

    add_window(s, finder, "Macintosh HD", 20, 4, 300, 420, 0x0034ab10UL);
    add_window(s, finder, "Lab", 60, 40, 340, 460, 0x00120040UL);
    /* The one row the caller can move, so a test can change exactly one
       window and nothing else. */
    add_window(s, text, "untitled", title_x, 4, 581, 619, 0x00998800UL);

    now_scene_set_processes_coverage(s, kNowSceneCoverageComplete);
    now_scene_set_windows_coverage(s, finder, kNowSceneCoverageComplete);
    now_scene_set_windows_coverage(s, text, kNowSceneCoverageComplete);
}

static long encode(NowScene *s, char *out, long cap, NowSceneSpans *sp)
{
    long needed = 0;

    if (now_scene_encode_spans(s, out, cap, &needed, sp) != kNowSceneEncodeOk) {
        fprintf(stderr, "FAIL: the fixture did not encode (%ld needed)\n",
                needed);
        ++g_failures;
        return -1;
    }
    return needed - 1;
}

static void test_fnv_is_the_published_function(void)
{
    /* The FNV-1a/32 vectors from the reference implementation. If these
       move, every side of this protocol is hashing something private. */
    check(now_scene_fnv1a(kNowSceneFnvSeed, "", 0) == 2166136261UL,
          "FNV-1a of the empty string is the offset basis");
    check(now_scene_fnv1a(kNowSceneFnvSeed, "a", 1) == 0xe40c292cUL,
          "FNV-1a(\"a\")");
    check(now_scene_fnv1a(kNowSceneFnvSeed, "foobar", 6) == 0xbf9cf968UL,
          "FNV-1a(\"foobar\")");
}

static void test_digest_ignores_the_moment_but_not_the_machine(void)
{
    static NowScene a, b;
    static char da[32768], db[32768];
    static NowSceneSpans sa, sb;
    unsigned long ha, hb;

    build(&a, 3, 1000000000.0, 20);
    build(&b, 4, 1000000077.0, 20);   /* later scene, same machine */
    if (encode(&a, da, sizeof da, &sa) < 0) return;
    if (encode(&b, db, sizeof db, &sb) < 0) return;

    check(strcmp(da, db) != 0,
          "two walks of one machine differ as DOCUMENTS (seq, capturedAt)");
    ha = now_scene_body_digest(da, &sa);
    hb = now_scene_body_digest(db, &sb);
    check(ha == hb,
          "...and hash the SAME, or the no-change answer can never be given");

    /* One window moved by one pixel. Nothing else. */
    build(&b, 5, 1000000090.0, 21);
    if (encode(&b, db, sizeof db, &sb) < 0) return;
    check(now_scene_body_digest(db, &sb) != ha,
          "a window that moved one pixel changes the digest");
}

static void test_hex_round_trip(void)
{
    char hex[9];

    now_scene_digest_hex(0x0a1b2c3dUL, hex);
    check(strcmp(hex, "0a1b2c3d") == 0, "a digest renders as eight hex digits");
    check(now_scene_digest_is(0x0a1b2c3dUL, "0a1b2c3d"), "and matches itself");
    check(!now_scene_digest_is(0x0a1b2c3dUL, "0A1B2C3D"),
          "uppercase is NOT a match: the wire form is exactly one spelling");
    check(!now_scene_digest_is(0x0a1b2c3dUL, ""),
          "an empty since matches nothing, so it is served a whole document");
    check(!now_scene_digest_is(0x0a1b2c3dUL, "nonsense"),
          "and so is a malformed one - never refused, never matched");
}

/* The host's half, written here so the guest's half is tested against
   something that is not itself: pull each ordered entry out of the delta,
   take its bytes from the delta when it carries them and from the
   baseline document when it does not, and rebuild the whole value. */
static const char *plane_of(const char *delta, const char *name)
{
    static char key[32];

    snprintf(key, sizeof key, "\"%s\":[", name);
    return strstr(delta, key);
}

/* Copies the balanced JSON value starting at `p` (which points at '{' or
   '[') into `out`; returns the byte after it. */
static const char *copy_value(const char *p, char *out, long *len)
{
    int depth = 0;
    int in_str = 0;
    const char *start = p;

    for (; *p != '\0'; ++p) {
        if (in_str) {
            if (*p == '\\' && p[1] != '\0') ++p;
            else if (*p == '"') in_str = 0;
            continue;
        }
        if (*p == '"') in_str = 1;
        else if (*p == '{' || *p == '[') ++depth;
        else if (*p == '}' || *p == ']') {
            if (--depth == 0) {
                ++p;
                break;
            }
        }
    }
    *len = (long)(p - start);
    memcpy(out, start, (size_t)*len);
    out[*len] = '\0';
    return p;
}

/* Rebuilds one plane's array value from a delta's ordered entries and the
   baseline's element spans. This is the host's algorithm; if it does not
   reproduce the guest's bytes, the digest check on the host proves
   nothing. */
static void rebuild_plane(const char *delta, const char *name,
                          const char *base_doc, const NowSceneSpan *base,
                          short base_count, char *out)
{
    const char *p = plane_of(delta, name);
    long n = 0;

    check(p != NULL, "the delta carries every plane, even an untouched one");
    if (p == NULL) {
        strcpy(out, "[]");
        return;
    }
    p = strchr(p, '[');
    ++p;
    out[n++] = '[';
    while (*p != ']') {
        char entry[32768];
        char key[kNowSceneKeyMax];
        const char *kq;
        long elen = 0;
        long i;

        if (*p == ',') { out[n++] = ','; ++p; continue; }
        p = copy_value(p, entry, &elen);
        kq = strstr(entry, "\"k\":\"");
        check(kq != NULL, "every delta entry names a key");
        if (kq == NULL) break;
        kq += 5;
        for (i = 0; kq[i] != '"' && i < kNowSceneKeyMax - 1; ++i) key[i] = kq[i];
        key[i] = '\0';
        {
            const char *v = strstr(entry, "\"v\":");
            if (v != NULL) {
                char val[32768];
                long vlen = 0;

                copy_value(v + 4, val, &vlen);
                memcpy(out + n, val, (size_t)vlen);
                n += vlen;
            } else {
                short at = -1;
                short j;

                for (j = 0; j < base_count; ++j) {
                    if (strcmp(base[j].key, key) == 0) { at = j; break; }
                }
                /* A k-only entry naming a key the consumer does not hold
                   is a provable fault, caught before any hashing. */
                check(at >= 0, "a k-only entry names a key the consumer holds");
                if (at < 0) break;
                memcpy(out + n, base_doc + base[at].off, (size_t)base[at].len);
                n += base[at].len;
            }
        }
    }
    out[n++] = ']';
    out[n] = '\0';
}

static void test_reconstruction_is_byte_exact(void)
{
    static NowScene a, b;
    static char da[32768], db[32768], delta[32768];
    static NowSceneSpans sa, sb;
    static NowSceneBaseline base;
    static char got[32768];
    char hex[9];
    long dlen;
    unsigned long digest_a, digest_b;

    build(&a, 3, 1000000000.0, 20);
    if (encode(&a, da, sizeof da, &sa) < 0) return;
    digest_a = now_scene_body_digest(da, &sa);
    now_scene_digest_hex(digest_a, hex);
    check(now_scene_baseline_adopt(&base, da, &sa, digest_a),
          "a fully keyed scene can become a baseline");

    /* One window moves. Everything else is identical. */
    build(&b, 4, 1000000030.0, 21);
    if (encode(&b, db, sizeof db, &sb) < 0) return;
    digest_b = now_scene_body_digest(db, &sb);

    dlen = now_scene_delta_encode(&base, db, &sb, b.seq, b.captured_at, hex,
                                  delta, sizeof delta);
    check(dlen > 0, "the delta encodes");
    if (dlen <= 0) return;
    check(dlen == (long)strlen(delta), "the delta's reported length is its length");
    check(dlen < (long)strlen(db),
          "and it is SMALLER than the document it replaces - a delta that "
          "costs more has no case");

    /* Exactly one window's bytes are carried. Two would mean the hash is
       noticing something that did not change; none would mean it is
       missing something that did. */
    {
        const char *p = plane_of(delta, "windows");
        int carried = 0;
        const char *q;

        for (q = p; q != NULL && *q != '\0' && *q != ']'; ++q) {
            if (strncmp(q, "\"v\":", 4) == 0) ++carried;
        }
        check(carried == 1, "exactly one window's bytes cross the wire");
    }
    check(strstr(delta, "\"menubar\":{\"same\":true}") != NULL
          || strstr(delta, "\"menubar\":{") != NULL,
          "the menu bar is named rather than implied");

    /* Now the host's half: rebuild every plane and hash the result the
       way the contract says, then compare to what the guest published. */
    {
        static char apps[32768], procs[32768], wins[32768];
        unsigned long h = kNowSceneFnvSeed;

        rebuild_plane(delta, "apps", da, sa.apps, sa.app_count, apps);
        rebuild_plane(delta, "processes", da, sa.procs, sa.proc_count, procs);
        rebuild_plane(delta, "windows", da, sa.windows, sa.window_count, wins);

        check(strncmp(apps, db + sb.apps_off, (size_t)sb.apps_len) == 0
              && (long)strlen(apps) == sb.apps_len,
              "the rebuilt apps array is byte-for-byte the guest's");
        check(strncmp(procs, db + sb.procs_off, (size_t)sb.procs_len) == 0
              && (long)strlen(procs) == sb.procs_len,
              "the rebuilt processes array is byte-for-byte the guest's");
        check(strncmp(wins, db + sb.windows_off, (size_t)sb.windows_len) == 0
              && (long)strlen(wins) == sb.windows_len,
              "the rebuilt windows array is byte-for-byte the guest's");

        /* The digest, in the contract's fixed order, over the rebuilt
           body - the host's actual test, computed here from rebuilt
           bytes rather than from the guest's document. */
        h = now_scene_fnv1a(h, db + sb.screen_off, sb.screen_len);
        h = now_scene_fnv1a(h, db + sb.source_off, sb.source_len);
        h = now_scene_fnv1a(h, apps, (long)strlen(apps));
        h = now_scene_fnv1a(h, procs, (long)strlen(procs));
        h = now_scene_fnv1a(h, "-", 1);
        h = now_scene_fnv1a(h, wins, (long)strlen(wins));
        h = now_scene_fnv1a(h, db + sb.coverage_off, sb.coverage_len);
        h = now_scene_fnv1a(h, db + sb.errors_off, sb.errors_len);
        check(h == digest_b,
              "a consumer that applied the delta computes the digest the "
              "guest published - which is the whole resync guarantee");
        (void)got;
    }
}

static void test_an_unkeyed_row_cannot_be_a_baseline(void)
{
    static NowScene s;
    static char doc[32768];
    static NowSceneSpans sp;
    static NowSceneBaseline base;
    int p;

    now_scene_begin(&s, 1, 1000000000.0, "peek", 640, 480, 20000, 0);
    p = now_scene_add_process(&s, 0, 29884417UL, "Finder", 0x4D414353UL, 1,
                              kNowSceneAnchorOk, 19990);
    (void)p;  /* deliberately NO incarnation */
    if (encode(&s, doc, sizeof doc, &sp) < 0) return;
    check(!sp.keyed_all, "a row with no incarnation clears keyed_all");
    check(!now_scene_baseline_adopt(&base, doc, &sp,
                                    now_scene_body_digest(doc, &sp)),
          "and the scene refuses to become a baseline rather than "
          "inventing a key");
    check(now_scene_delta_encode(&base, doc, &sp, 1, 0.0, "00000000",
                                 NULL, 0) < 0,
          "no delta can be computed against a baseline that was refused");
}

static void test_a_window_that_left_is_simply_absent(void)
{
    static NowScene a, b;
    static char da[32768], db[32768], delta[32768];
    static NowSceneSpans sa, sb;
    static NowSceneBaseline base;
    char hex[9];
    unsigned long d;
    long dlen;

    build(&a, 1, 1000000000.0, 20);
    if (encode(&a, da, sizeof da, &sa) < 0) return;
    d = now_scene_body_digest(da, &sa);
    now_scene_digest_hex(d, hex);
    now_scene_baseline_adopt(&base, da, &sa, d);

    /* The same machine with SimpleText's window closed. */
    now_scene_begin(&b, 2, 1000000030.0, "peek", 640, 480, 20000, 0);
    {
        int finder = now_scene_add_process(&b, 0, 29884417UL, "Finder",
                                           0x4D414353UL, 0,
                                           kNowSceneAnchorOk, 19990);
        int text = now_scene_add_process(&b, 0, 32636930UL, "SimpleText",
                                         0x74747874UL, 1, kNowSceneAnchorOk,
                                         19995);
        now_scene_set_process_incarnation(&b, finder, 0x1a2b3c4dUL);
        now_scene_set_process_incarnation(&b, text, 0x55667788UL);
        add_window(&b, finder, "Macintosh HD", 20, 4, 300, 420, 0x0034ab10UL);
        add_window(&b, finder, "Lab", 60, 40, 340, 460, 0x00120040UL);
        now_scene_set_processes_coverage(&b, kNowSceneCoverageComplete);
        now_scene_set_windows_coverage(&b, finder, kNowSceneCoverageComplete);
        now_scene_set_windows_coverage(&b, text, kNowSceneCoverageComplete);
    }
    if (encode(&b, db, sizeof db, &sb) < 0) return;
    dlen = now_scene_delta_encode(&base, db, &sb, b.seq, b.captured_at, hex,
                                  delta, sizeof delta);
    check(dlen > 0, "a scene that lost a window still encodes as a delta");
    check(strstr(delta, "window-00998800") == NULL,
          "the departed window is ABSENT from the ordered array - a "
          "deletion is not a message and carries no authority of its own");
    check(strstr(delta, "window-0034ab10") != NULL,
          "and the windows that stayed are still named");
    check(strstr(delta, "\"coverage\":") != NULL,
          "coverage is restated WHOLE on every delta: it is the only thing "
          "that may authorise the deletion this absence implies");
}

int main(void)
{
    test_fnv_is_the_published_function();
    test_digest_ignores_the_moment_but_not_the_machine();
    test_hex_round_trip();
    test_reconstruction_is_byte_exact();
    test_an_unkeyed_row_cannot_be_a_baseline();
    test_a_window_that_left_is_simply_absent();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("scene_digest_test: ok\n");
    return 0;
}
