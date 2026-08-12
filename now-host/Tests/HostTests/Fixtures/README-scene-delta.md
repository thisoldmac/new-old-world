<!-- now-doc-provenance: generated reviewed=false -->

# The scene-delta fixtures

`scene-delta-baseline.json`, `scene-delta-next-whole.json` and
`scene-delta-next-delta.json` were **emitted by the guest's own encoder**,
not written by hand. That is their whole value: every other case in
`MirrorSceneDeltaTests` parses documents the test file wrote, which tests
one half twice.

They describe one machine at two moments — the Finder with two windows and
SimpleText with one — where exactly one window moved by a pixel.
`MirrorSceneDeltaTests.testTheGuestsOwnDeltaRebuildsTheGuestsOwnNextScene`
applies the delta to the baseline and requires the result to equal
`scene-delta-next-whole.json` **byte for byte**.

**It has already earned its place.** On the run that minted it, the guest
emitted `"source":,"screen":,` — two empty values — because
`now_scene_encode_spans` recorded every span except those two. The
guest's own native test did not notice: it rebuilt the body using the same
zero-length spans on both sides, so it agreed with itself perfectly. Only
a consumer that had never seen those spans could tell. That is
`two-halves-never-met-in-a-test` in one afternoon, and the reason these
files are committed rather than generated.

## Refreshing them

They change only when the guest's encoder changes. Regenerate from the
guest sources — never edit them by hand, because a fixture edited to make
a test pass no longer describes anything:

```sh
cat > /tmp/gen.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include "scene.h"

static void add_window(NowScene *s, int p, const char *t, short l,
                       unsigned long addr)
{
    if (now_scene_add_window(s, p, t, 4, l, 420, 300, 1))
        now_scene_set_window_addr(s, s->window_count - 1, addr);
}

static void build(NowScene *s, long seq, double at, short left)
{
    int finder, text;
    now_scene_begin(s, seq, at, "peek", 640, 480, 20000, 0);
    finder = now_scene_add_process(s, 0, 29884417UL, "Finder", 0x4D414353UL, 0,
                                   kNowSceneAnchorOk, 19990);
    now_scene_set_process_incarnation(s, finder, 0x1a2b3c4dUL);
    text = now_scene_add_process(s, 0, 32636930UL, "SimpleText", 0x74747874UL, 1,
                                 kNowSceneAnchorOk, 19995);
    now_scene_set_process_incarnation(s, text, 0x55667788UL);
    add_window(s, finder, "Macintosh HD", left, 0x0034ab10UL);
    add_window(s, finder, "Lab", 60, 0x00120040UL);
    add_window(s, text, "untitled", 20, 0x00998800UL);
    now_scene_set_processes_coverage(s, kNowSceneCoverageComplete);
    now_scene_set_windows_coverage(s, finder, kNowSceneCoverageComplete);
    now_scene_set_windows_coverage(s, text, kNowSceneCoverageComplete);
}

static void dump(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

int main(int argc, char **argv)
{
    static NowScene a, b;
    static char da[65536], db[65536], dd[65536];
    static NowSceneSpans sa, sb;
    static NowSceneBaseline base;
    long n = 0, dl;
    char hex[9];

    build(&a, 41, 1786000100.0, 20);
    now_scene_encode_spans(&a, da, sizeof da, &n, &sa);
    now_scene_digest_hex(now_scene_body_digest(da, &sa), hex);
    now_scene_baseline_adopt(&base, da, &sa, now_scene_body_digest(da, &sa));

    build(&b, 42, 1786000130.0, 21);
    now_scene_encode_spans(&b, db, sizeof db, &n, &sb);
    dl = now_scene_delta_encode(&base, db, &sb, b.seq, b.captured_at, hex,
                                dd, sizeof dd);
    fprintf(stderr, "baseline=%s whole=%ld delta=%ld\n", hex,
            (long)strlen(db), dl);
    dump(argv[1], da);
    dump(argv[2], db);
    dump(argv[3], dd);
    (void)argc;
    return 0;
}
EOF

cd <repo root>
cc -std=c89 -I now-guest-ppc/src/scene -I now-guest-ppc/src/core \
   -I now-guest-ppc/src/axwalk -I now-guest-ppc/src/observe \
   -I now-guest-ppc/src/peek -o /tmp/gen /tmp/gen.c \
   now-guest-ppc/src/scene/scene_build.c now-guest-ppc/src/scene/scene_json.c \
   now-guest-ppc/src/scene/scene_phase.c now-guest-ppc/src/scene/scene_digest.c \
   now-guest-ppc/src/core/json.c
/tmp/gen now-host/Tests/HostTests/Fixtures/scene-delta-baseline.json \
         now-host/Tests/HostTests/Fixtures/scene-delta-next-whole.json \
         now-host/Tests/HostTests/Fixtures/scene-delta-next-delta.json
```
