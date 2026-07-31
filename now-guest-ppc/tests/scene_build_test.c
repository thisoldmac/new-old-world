/* Native test for scene assembly (src/scene/scene_build.c).
 *
 * The scene is a claim about a machine, and every rule here is a clause
 * of that claim: which verdicts admit data, which ones only get to say
 * why not, what "front" means, and what happens when the machine has
 * more than a scene carries. Assembly was written Toolbox-free for this
 * file, the way peek_oracle.c was for peek_oracle_test.c - the anchor
 * verdicts that matter most (Ambiguous, Mismatch) cannot be arranged on
 * a real Macintosh at all.
 *
 * Mutation check, each watched failing 2026-07-31 - see the report in
 * docs/scene-producer.md.
 */

#include <stdio.h>
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

static void check_str(const char *got, const char *want, const char *what)
{
    if (got == NULL) {
        got = "(null)";
    }
    if (want == NULL) {
        want = "(null)";
    }
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL: %s (got \"%s\", want \"%s\")\n", what, got,
                want);
        ++g_failures;
    }
}

static void begin(NowScene *s)
{
    now_scene_begin(s, 7, 1000000000.0, "peek", 640, 480, 10000, 0);
}

/* The version is stamped from one constant, so the body's `version` and
   whatever a serving layer puts in the result's `irVersion` cannot
   diverge without editing source. Upstream's rule, restated at our end
   (IR-V1.md, "One number, two places"). */
static void test_version_stamp(void)
{
    NowScene s;

    begin(&s);
    check(s.version == NOW_SCENE_IR_VERSION, "version is the IR constant");
    check(s.version == 1, "the IR major is 1");
    check(s.latency_ms < 0, "latency is absent until measured");
}

/* The five oracle verdicts, plus the three reader states that are not
   the oracle's, each mapped to a token a consumer can act on. Ok and
   NoWindows are NOT errors: "this process has no windows" is an answer
   about the machine, not a failure to find out. */
static void test_verdict_tokens(void)
{
    check(now_scene_anchor_error(kNowSceneAnchorOk) == NULL,
          "Ok is not an error");
    check(now_scene_anchor_error(kNowSceneAnchorNoWindows) == NULL,
          "NoWindows is not an error");
    check_str(now_scene_anchor_error(kNowSceneAnchorNotFound),
              "ax_oracle_not_found", "NotFound token");
    check_str(now_scene_anchor_error(kNowSceneAnchorAmbiguous),
              "ax_oracle_ambiguous", "Ambiguous token");
    check_str(now_scene_anchor_error(kNowSceneAnchorMismatch),
              "ax_oracle_mismatch", "Mismatch token");
    check_str(now_scene_anchor_error(kNowSceneAnchorUnreadable), "ax_read",
              "Unreadable token");
    check_str(now_scene_anchor_error(kNowSceneAnchorNoPlane), "now_no_plane",
              "NoPlane is NOW's own state, so NOW's own prefix");
    check_str(now_scene_anchor_error(kNowSceneAnchorStub), "now_not_walked",
              "Stub is NOW's own state");
    check_str(now_scene_stale_error(), "ax_oracle_stale", "Stale token");
}

/* A window under a refused anchor is the coin-flip walk the validation
   layer declines to make. The scene must not admit it one layer up. */
static void test_refused_anchors_admit_no_windows(void)
{
    static const NowSceneAnchor refused[] = {
        kNowSceneAnchorNoPlane, kNowSceneAnchorNotFound,
        kNowSceneAnchorUnreadable, kNowSceneAnchorStub,
        kNowSceneAnchorAmbiguous, kNowSceneAnchorMismatch
    };
    unsigned i;

    for (i = 0; i < sizeof refused / sizeof refused[0]; ++i) {
        NowScene s;
        int p;

        begin(&s);
        p = now_scene_add_process(&s, 0, 100, "Ghost", 0x4D414353UL, 0,
                                  refused[i], 0);
        check(p == 0, "the process row is still carried");
        check(now_scene_add_window(&s, p, "Untitled", 20, 4, 200, 300, 1) == 0,
              "a refused anchor admits no window");
        check(s.window_count == 0, "and none is carried");
        check(now_scene_proc_error(&s.procs[p]) != NULL,
              "the refusal is reported, not swallowed");
    }
    check(now_scene_anchor_admits_windows(kNowSceneAnchorOk),
          "Ok admits windows");
    check(now_scene_anchor_admits_windows(kNowSceneAnchorNoWindows),
          "NoWindows admits (trivially - it IS the empty answer)");
}

/* An ambiguous process is not a process with zero windows, and the scene
   has to keep those two apart: same window count, different claim. */
static void test_ambiguous_is_not_empty(void)
{
    NowScene s;
    int amb, none;

    begin(&s);
    amb = now_scene_add_process(&s, 0, 11, "Ambiguous", 0, 0,
                                kNowSceneAnchorAmbiguous, 0);
    none = now_scene_add_process(&s, 0, 22, "Quiet", 0, 0,
                                 kNowSceneAnchorNoWindows, 9000);
    check(s.procs[amb].window_count == 0 && s.procs[none].window_count == 0,
          "both carry zero windows");
    check_str(now_scene_proc_error(&s.procs[amb]), "ax_oracle_ambiguous",
              "the ambiguous one says so");
    check(now_scene_proc_error(&s.procs[none]) == NULL,
          "the empty one claims nothing went wrong");
}

/* Stale is REPORTED, not refused: the windows are carried and the age is
   declared beside them (peek_oracle.h's own rule for the verdict). */
static void test_stale_is_reported_not_refused(void)
{
    NowScene s;
    int p;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 10000, 600);
    p = now_scene_add_process(&s, 0, 33, "Old", 0, 0, kNowSceneAnchorOk,
                              9000);            /* 1000 ticks of age */
    check(s.procs[p].stale, "1000 ticks past a 600-tick window is stale");
    check(now_scene_add_window(&s, p, "Doc", 20, 4, 200, 300, 1) == 1,
          "and its windows are still carried");
    check_str(now_scene_proc_error(&s.procs[p]), "ax_oracle_stale",
              "with the staleness declared");

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 10000, 600);
    p = now_scene_add_process(&s, 0, 33, "Edge", 0, 0, kNowSceneAnchorOk,
                              9400);            /* exactly 600 ticks */
    check(!s.procs[p].stale, "the window itself is not past the window");

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 10000, 0);
    p = now_scene_add_process(&s, 0, 33, "Ungated", 0, 0, kNowSceneAnchorOk,
                              1);
    check(!s.procs[p].stale, "a zero window disables the age gate");

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 10000, 600);
    p = now_scene_add_process(&s, 0, 33, "Future", 0, 0, kNowSceneAnchorOk,
                              50000);
    check(!s.procs[p].stale,
          "a stamp in the future is a moved clock, not an old anchor");
}

/* z is the stacking index WITHIN a process - the chain order, which is
   the only stacking NOW can honestly assert - and front is the front
   process's frontmost window and nothing else. */
static void test_z_and_front(void)
{
    NowScene s;
    int front, back;

    begin(&s);
    front = now_scene_add_process(&s, 0, 1, "Finder", 0x4D414353UL, 1,
                                  kNowSceneAnchorOk, 9999);
    back = now_scene_add_process(&s, 0, 2, "SimpleText", 0x74747874UL, 0,
                                 kNowSceneAnchorOk, 9999);
    check(now_scene_add_window(&s, front, "Macintosh HD", 20, 4, 200, 300, 1),
          "front app window 0");
    check(now_scene_add_window(&s, front, "Trash", 40, 40, 220, 340, 1),
          "front app window 1");
    check(now_scene_add_window(&s, back, "untitled", 60, 60, 300, 400, 1),
          "back app window 0");

    check(s.window_count == 3, "three windows");
    check(s.windows[0].z == 0 && s.windows[1].z == 1 && s.windows[2].z == 0,
          "z counts within its own process");
    check(s.windows[0].front, "the front app's first window is front");
    check(!s.windows[1].front, "its second window is not");
    check(!s.windows[2].front,
          "and no window of a background app is ever front");
    check_str(s.windows[0].id, "0.1/Macintosh HD#0", "upstream's id form");
    check_str(s.windows[2].id, "0.2/untitled#0", "id is per-process indexed");
}

/* More machine than the scene carries is a fact about the read, and it
   has to be visible: a truncated walk delivered as a whole one is the
   defect a scene must never commit. */
static void test_truncation_is_recorded(void)
{
    NowScene s;
    int i;
    int p;

    begin(&s);
    for (i = 0; i < kNowSceneMaxProcs; ++i) {
        check(now_scene_add_process(&s, 0, (unsigned long)i, "P", 0, 0,
                                    kNowSceneAnchorNoWindows, 0) == i,
              "process rows fill up to the cap");
    }
    check(!s.procs_truncated, "not truncated at exactly the cap");
    check(now_scene_add_process(&s, 0, 999, "Overflow", 0, 0,
                                kNowSceneAnchorNoWindows, 0) == -1,
          "the next one is refused");
    check(s.procs_truncated, "and the refusal is recorded");

    begin(&s);
    p = now_scene_add_process(&s, 0, 1, "Busy", 0, 1, kNowSceneAnchorOk, 0);
    for (i = 0; i < kNowSceneMaxWindows; ++i) {
        check(now_scene_add_window(&s, p, "W", 0, 0, 10, 10, 1) == 1,
              "window rows fill up to the cap");
    }
    check(!s.windows_truncated, "not truncated at exactly the cap");
    check(now_scene_add_window(&s, p, "W", 0, 0, 10, 10, 1) == 0,
          "the next one is refused");
    check(s.windows_truncated, "and the refusal is recorded");
    check(s.procs[p].window_count == kNowSceneMaxWindows,
          "the dropped window is not counted as carried");
}

/* Nothing is written through a bad index, and a NULL scene is inert
   rather than a crash - this code runs in an app that also holds a
   foreign-memory reader, and a wild write here would be indistinguishable
   from one there. */
static void test_bounds(void)
{
    NowScene s;

    begin(&s);
    check(now_scene_add_window(&s, 0, "X", 0, 0, 1, 1, 1) == 0,
          "no process 0 yet");
    check(now_scene_add_window(&s, -1, "X", 0, 0, 1, 1, 1) == 0,
          "negative index refused");
    check(now_scene_add_process(NULL, 0, 1, "X", 0, 0, kNowSceneAnchorOk, 0)
          == -1, "a NULL scene takes no rows");
    check(now_scene_proc_error(NULL) == NULL, "a NULL row has no error");
}

/* A name or title longer than the row is truncated, never overrun. */
static void test_long_strings(void)
{
    NowScene s;
    char long_name[200];
    int p;

    memset(long_name, 'A', sizeof long_name - 1);
    long_name[sizeof long_name - 1] = '\0';
    begin(&s);
    p = now_scene_add_process(&s, 0, 1, long_name, 0, 1, kNowSceneAnchorOk, 0);
    check((long)strlen(s.procs[p].name) == kNowSceneNameMax - 1,
          "the name is bounded by its row");
    check(now_scene_add_window(&s, p, long_name, 0, 0, 1, 1, 1) == 1,
          "a long title is still a window");
    check((long)strlen(s.windows[0].title) == kNowSceneTitleMax - 1,
          "the title is bounded by its row");
    check(strlen(s.windows[0].id) < kNowSceneIdMax, "and the id fits");
}

int main(void)
{
    test_version_stamp();
    test_verdict_tokens();
    test_refused_anchors_admit_no_windows();
    test_ambiguous_is_not_empty();
    test_stale_is_reported_not_refused();
    test_z_and_front();
    test_truncation_is_recorded();
    test_bounds();
    test_long_strings();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("scene_build: ok\n");
    return 0;
}
