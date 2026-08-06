#ifndef NOW_SCENE_DIGEST_H
#define NOW_SCENE_DIGEST_H

/* WHAT A SCENE LOOKS LIKE, as one number and a table of entities - the
 * machinery behind scene.same and scene.begin's delta form.
 *
 * The problem this exists for is measured, not assumed: on 2026-08-06
 * the guest's whole walk was 3-8.5 ms while the host's transfer clock
 * read 111-710 ms for the same scene, and a real document ran 15 KB idle
 * and 26-28 KB with windows and a menu bar open. The sizing pass alone
 * is 589 us. The cost is BYTES, and several times a second we were
 * shipping all of them for a Macintosh that mostly had not changed.
 *
 * TOOLBOX-FREE ON PURPOSE, the same split scene_build.c / scene_collect.c
 * already draws. Everything here works on the ENCODED DOCUMENT and a
 * table of byte ranges within it, so the whole of the "did anything
 * move, and what do I send instead" decision is reachable from
 * tests/scene_digest_test.c on a host compiler. A Macintosh is needed to
 * produce a scene; it is not needed to decide what to do with two.
 *
 * THE UNIT IS A WHOLE ENTITY - one app row, one process row, one window
 * with everything under it, or the whole menu bar. Nothing smaller is
 * ever sent, which is the property the rest rests on: A DELTA CAN LOSE
 * AN ENTITY, BUT IT CAN NEVER CORRUPT ONE. There is no field-level patch
 * to get wrong and no meaning to assign to half an applied window.
 *
 * THE HASH IS NEVER CACHED, only the comparison is. Every scene encodes
 * every entity afresh and hashes the bytes it just wrote. A producer
 * that hashed a remembered value would be able to claim "unchanged"
 * about something it had not looked at, which is exactly the stale-model
 * failure plan 013 names as the thing that would make this wrong.
 *
 * See docs/scene-deltas.md and contract/asyncapi.yaml (SceneBegin.digest). */

/* An entity's key is its IR incarnation: "process-1a2b3c4d" for a row,
   "process-1a2b3c4d/window-0034ab10" for a window. 33 bytes with the
   terminator; the slack is for a longer form arriving additively. */
enum { kNowSceneKeyMax = 40 };

/* A byte range in the encoded document, and what it hashes to. `key` is
   empty for a region that is not a keyed entity. */
typedef struct {
    long off;
    long len;
    unsigned long hash;
    char key[kNowSceneKeyMax];
} NowSceneSpan;

/* Where every digest-bearing region of one encoded document is. Filled
   by now_scene_encode() when a caller asks for it; meaningless without
   the document it was filled from.

   THE ARRAY SPANS COVER THE WHOLE VALUE, brackets included, because that
   is what the contract's digest hashes and what a consumer rebuilds by
   joining elements with commas. The element spans cover one element,
   comma excluded, because that is what a delta ships. */
typedef struct {
    long screen_off, screen_len;
    long source_off, source_len;
    long apps_off, apps_len;
    long procs_off, procs_len;
    long menubar_off, menubar_len;      /* len 0 = the key was absent */
    long windows_off, windows_len;
    long coverage_off, coverage_len;
    long errors_off, errors_len;
    /* Everything meta carries AFTER coverage - plane, latencyMs, phases -
       as one span, restated verbatim so a delta's meta is byte-for-byte
       the meta a whole document would have carried. It is deliberately
       NOT in the digest: phases move on every walk of a machine that did
       not change, and a digest that moved with them could never say
       "nothing changed". */
    long tail_off, tail_len;

    NowSceneSpan apps[40];              /* kNowSceneMaxProcs */
    short app_count;
    NowSceneSpan procs[40];
    short proc_count;
    NowSceneSpan windows[64];           /* kNowSceneMaxWindows */
    short window_count;

    /* Every entity carried a key. A scene with an unkeyed row cannot be
       a delta baseline: MirrorReplicaReducer already refuses to key an
       incarnation-less row into its durable maps, so a row the reducer
       will not key is a row a delta must not key either. The two rules
       agree because they are the same rule. */
    int keyed_all;
} NowSceneSpans;

/* What the guest remembers between scenes: one key and one hash per
   entity, in scene order, plus the always-restated regions' hashes. A
   few kilobytes - deliberately, because the machine that needs deltas
   most has the least room, and nothing here is proportional to the size
   of the document. */
typedef struct {
    int held;                           /* false until a scene is adopted */
    unsigned long digest;               /* the body digest of that scene */
    unsigned long run;                  /* consecutive deltas sent against it */

    char app_key[40][kNowSceneKeyMax];
    unsigned long app_hash[40];
    short app_count;
    char proc_key[40][kNowSceneKeyMax];
    unsigned long proc_hash[40];
    short proc_count;
    char window_key[64][kNowSceneKeyMax];
    unsigned long window_hash[64];
    short window_count;
    unsigned long menubar_hash;
    int menubar_present;
} NowSceneBaseline;

/* The chain's bound. The 65th answer against one baseline is a whole
   document whatever the host asked for: an unbounded chain is a bet that
   no consumer will ever have a bug, and a product whose claim is a
   faithful mirror does not get to take that bet. */
enum { kNowSceneDeltaMaxRun = 64 };

/* FNV-1a/32, the one hash this plane uses. Exposed because the tests
   pin it against known vectors - a digest whose function drifted would
   make every side agree with itself and with nobody else. */
unsigned long now_scene_fnv1a(unsigned long seed, const char *bytes, long len);
enum { kNowSceneFnvSeed = 2166136261UL };

/* The body digest of an encoded document: FNV-1a over the concatenation,
   in the contract's fixed order, of screen, source, apps, processes,
   menubar (the single byte '-' when the key is absent), windows,
   meta.coverage and meta.errors.

   WHAT IT EXCLUDES IS THE POINT: seq, capturedAt, latencyMs, walkMs and
   meta.phases all move on every walk of a machine that did not change,
   so a digest over them could never say "nothing changed" - and saying
   that is what this is for. */
unsigned long now_scene_body_digest(const char *doc, const NowSceneSpans *sp);

/* Renders a digest as the eight lowercase hex digits the wire carries.
   `out` needs 9 bytes. */
void now_scene_digest_hex(unsigned long digest, char *out);

/* True when `hex` is exactly eight lowercase hex digits naming `digest`.
   The comparison is on the TEXT the host sent, so a host that quotes
   something malformed is simply not matched and is served a whole
   document - never refused, and never matched by accident. */
int now_scene_digest_is(unsigned long digest, const char *hex);

/* Forgets the baseline. Called when the connection changes, because a
   baseline is a claim about one consumer's state and a new consumer has
   none. */
void now_scene_baseline_clear(NowSceneBaseline *b);

/* Adopts this document as the baseline: key and hash per entity, and the
   body digest. Refuses (returns 0, leaving the baseline cleared) when
   any entity lacked a key, because such a scene cannot be described as
   a set of keyed deltas. */
int now_scene_baseline_adopt(NowSceneBaseline *b, const char *doc,
                             const NowSceneSpans *sp, unsigned long digest);

/* Encodes the delta document for `sp` against `b` into `out` (NULL to
   size only, exactly as now_scene_encode does). `baseline_hex` is echoed
   as the document's own `baseline`. Returns the byte length a complete
   encode needs, terminator excluded, or -1 when the baseline cannot
   describe this scene at all.

   The caller decides whether to USE it: a delta is sent only when it is
   smaller than the whole document, and there is no case for one that
   costs more. */
long now_scene_delta_encode(const NowSceneBaseline *b, const char *doc,
                            const NowSceneSpans *sp, long seq,
                            double captured_at, const char *baseline_hex,
                            char *out, long cap);

#endif /* NOW_SCENE_DIGEST_H */
