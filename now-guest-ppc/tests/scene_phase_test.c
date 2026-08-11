/* The scene's phase breakdown, where its arithmetic is testable without
   a Macintosh.
 *
 *   cc -Wall -Wextra -Werror -I ../src/scene scene_phase_test.c \
 *      ../src/scene/scene_phase.c -o /tmp/scene_phase_test
 *
 * scripts/test-native runs it; the manifest there is what makes that
 * true, and a test missing from it does not count.
 *
 * WHAT IS WORTH TESTING HERE is not "does a timer add up". It is the
 * three properties the breakdown's honesty rests on, none of which a
 * Macintosh is needed to break:
 *
 *   - phases DO NOT OVERLAP, so their sum can be compared with the walk.
 *     A nested phase must be charged to itself and NOT also to its
 *     parent, which is the single arithmetic mistake that would make
 *     every future perf conclusion drawn from this file wrong in the
 *     same direction it was already wrong once today.
 *   - a producer with no clock reports NOTHING, because absence is the
 *     claim "this producer does not report phases" and eight zeroes
 *     would be a measurement.
 *   - the counter WRAPS. Microseconds' low word rolls over about every
 *     71 minutes, and a scene that straddles the roll must produce its
 *     real duration rather than four billion microseconds.
 *
 * The clock is injected precisely so these can be stated rather than
 * waited for. */

#include "scene_phase.h"

#include <stdio.h>
#include <string.h>

static int failures;

static unsigned long g_fake_now;
static unsigned long g_fake_step;      /* what each read costs the clock */
static unsigned long g_fake_reads;

static unsigned long fake_clock(void)
{
    unsigned long v = g_fake_now;

    ++g_fake_reads;
    g_fake_now += g_fake_step;
    return v;
}

static void tick(unsigned long us)
{
    g_fake_now += us;
}

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        ++failures;
    }
}

static void check_us(int phase, unsigned long want, const char *what)
{
    unsigned long got = now_scene_phase_us(phase);

    if (got != want) {
        printf("FAIL: %s: %s = %lu us, wanted %lu\n",
               what, now_scene_phase_name(phase), got, want);
        ++failures;
    }
}

static void begin(unsigned long step)
{
    g_fake_now = 1000;
    g_fake_step = step;
    g_fake_reads = 0;
    now_scene_phase_set_clock(fake_clock);
    now_scene_phase_reset();
}

/* A clock that costs nothing to read isolates the WORK from the
   measurement, which is what every case below except the last wants. */
static void test_flat_phases(void)
{
    begin(0);
    now_scene_phase_enter(kNowScenePhaseEnumerate);
    tick(500);
    now_scene_phase_leave(kNowScenePhaseEnumerate);
    tick(9999);                        /* outside every phase: charged to none */
    now_scene_phase_enter(kNowScenePhaseMenubar);
    tick(120);
    now_scene_phase_leave(kNowScenePhaseMenubar);

    check_us(kNowScenePhaseEnumerate, 500, "flat");
    check_us(kNowScenePhaseMenubar, 120, "flat");
    check_us(kNowScenePhaseBind, 0, "flat: an untouched phase stays zero");
    check(now_scene_phase_faults() == 0, "flat: no seam faults");
    check(now_scene_phase_clock_reads() == 4, "flat: two reads per phase");
}

/* THE PROPERTY THE WHOLE FILE EXISTS FOR. `controls` nested inside
   `windows` is charged to `controls` alone; `windows` keeps only the
   time it spent outside its child. Get this wrong and every parent
   double-counts its children, the sum exceeds the walk, and the
   breakdown says the most expensive thing is whatever contains the
   expensive thing - which is exactly the class of wrong answer this
   file was written to stop. */
static void test_nesting_does_not_double_count(void)
{
    begin(0);
    now_scene_phase_enter(kNowScenePhaseWindows);
    tick(10);
    now_scene_phase_enter(kNowScenePhaseControls);
    tick(700);
    now_scene_phase_leave(kNowScenePhaseControls);
    tick(5);
    now_scene_phase_enter(kNowScenePhaseRefs);
    tick(30);
    now_scene_phase_leave(kNowScenePhaseRefs);
    tick(2);
    now_scene_phase_leave(kNowScenePhaseWindows);

    check_us(kNowScenePhaseControls, 700, "nested");
    check_us(kNowScenePhaseRefs, 30, "nested");
    check_us(kNowScenePhaseWindows, 17, "nested: parent keeps only its own");
    check(now_scene_phase_us(kNowScenePhaseWindows)
              + now_scene_phase_us(kNowScenePhaseControls)
              + now_scene_phase_us(kNowScenePhaseRefs) == 747,
          "nested: the sum is the span, not more");
}

/* Re-entering a phase accumulates. Every seam in the collector is
   entered once per process or once per window, so this is the normal
   case rather than an edge one. */
static void test_repeated_entries_accumulate(void)
{
    int i;

    begin(0);
    for (i = 0; i < 5; ++i) {
        now_scene_phase_enter(kNowScenePhaseBind);
        tick(40);
        now_scene_phase_leave(kNowScenePhaseBind);
        tick(1000);                    /* between processes: charged to none */
    }
    check_us(kNowScenePhaseBind, 200, "repeated");
}

/* Microseconds' low word wraps about every 71 minutes. A span that
   straddles the roll is short; unsigned subtraction says so, and a
   signed or widened one would report an hour and a quarter. */
static void test_counter_wrap(void)
{
    begin(0);
    g_fake_now = 0xFFFFFF00UL;
    now_scene_phase_enter(kNowScenePhaseEncode);
    tick(0x300);                       /* past the top of the word */
    now_scene_phase_leave(kNowScenePhaseEncode);
    check_us(kNowScenePhaseEncode, 0x300, "wrap: the span, not the rollover");
}

/* No clock, no claim. This is the wire's absence rule made mechanical:
   a producer that cannot measure emits no `phases` key at all, and the
   encoder asks exactly this function. */
static void test_no_clock_reports_nothing(void)
{
    now_scene_phase_set_clock(NULL);
    now_scene_phase_reset();
    now_scene_phase_enter(kNowScenePhaseWindows);
    now_scene_phase_leave(kNowScenePhaseWindows);
    check(!now_scene_phase_reporting(), "no clock: reports nothing");
    check_us(kNowScenePhaseWindows, 0, "no clock");

    begin(0);
    check(!now_scene_phase_reporting(),
          "a scene that measured nothing yet reports nothing");
    now_scene_phase_enter(kNowScenePhaseWindows);
    now_scene_phase_leave(kNowScenePhaseWindows);
    check(now_scene_phase_reporting(), "one measured phase is enough");
}

/* An unbalanced seam is a programming error, and the module's job is to
   survive it visibly: the fault is counted, the other phases stay right,
   and the wire carries the count so a reader knows one number is
   suspect. */
static void test_seam_faults_are_reported(void)
{
    begin(0);
    now_scene_phase_enter(kNowScenePhaseWindows);
    tick(100);
    now_scene_phase_leave(kNowScenePhaseControls);   /* not what is on top */
    tick(50);
    now_scene_phase_leave(kNowScenePhaseWindows);
    check(now_scene_phase_faults() == 1, "faults: the mismatch is counted");
    check_us(kNowScenePhaseWindows, 150, "faults: the stack was not unwound");
}

/* Deeper than the stack holds. The over-deep enter is dropped and its
   leave is swallowed, so the phases either side of it stay correct -
   a dropped number is survivable, a misfiled one is not. */
static void test_overflow_pops_symmetrically(void)
{
    int i;

    begin(0);
    for (i = 0; i < kNowScenePhaseDepthMax; ++i) {
        now_scene_phase_enter(kNowScenePhaseWindows);
    }
    now_scene_phase_enter(kNowScenePhaseControls);   /* no room */
    tick(400);
    now_scene_phase_leave(kNowScenePhaseControls);
    tick(60);
    for (i = 0; i < kNowScenePhaseDepthMax; ++i) {
        now_scene_phase_leave(kNowScenePhaseWindows);
    }
    check(now_scene_phase_faults() == 1, "overflow: counted");
    check_us(kNowScenePhaseControls, 0, "overflow: the dropped phase is zero");
    check_us(kNowScenePhaseWindows, 460,
             "overflow: the stack recovered exactly");
}

/* THE BREAKDOWN'S OWN WEIGHT, which is the thing it must never lie
   about. With a clock that costs 3 us a read, four reads must show up as
   twelve - and the phases themselves absorb that cost rather than
   hiding it, because a real clock is read INSIDE the span it closes. */
static void test_clock_cost_is_published(void)
{
    begin(3);
    now_scene_phase_calibrate();
    check(now_scene_phase_clock_us() == 0,
          "calibration is not charged to a scene");

    now_scene_phase_reset();
    now_scene_phase_enter(kNowScenePhaseEnumerate);
    tick(100);
    now_scene_phase_leave(kNowScenePhaseEnumerate);
    now_scene_phase_enter(kNowScenePhaseEncode);
    tick(100);
    now_scene_phase_leave(kNowScenePhaseEncode);

    check(now_scene_phase_clock_reads() == 4, "cost: four reads");
    check(now_scene_phase_clock_us() == 12, "cost: 4 reads at 3 us");
    /* Each phase carries the one read that closed it, which is where the
       overhead actually lands and is why clockUs is worth printing. */
    check_us(kNowScenePhaseEnumerate, 103, "cost: measured from inside");
}

/* Names are the wire's keys. They are pinned here because renaming one
   silently retires every measurement taken under the old name. */
static void test_names_are_stable(void)
{
    check(strcmp(now_scene_phase_name(kNowScenePhaseEnumerate),
                 "enumerate") == 0, "name enumerate");
    check(strcmp(now_scene_phase_name(kNowScenePhaseBind), "bind") == 0,
          "name bind");
    check(strcmp(now_scene_phase_name(kNowScenePhaseWindows),
                 "windows") == 0, "name windows");
    check(strcmp(now_scene_phase_name(kNowScenePhaseControls),
                 "controls") == 0, "name controls");
    check(strcmp(now_scene_phase_name(kNowScenePhaseMenubar),
                 "menubar") == 0, "name menubar");
    check(strcmp(now_scene_phase_name(kNowScenePhaseSemantics),
                 "semantics") == 0, "name semantics");
    check(strcmp(now_scene_phase_name(kNowScenePhaseRefs), "refs") == 0,
          "name refs");
    check(strcmp(now_scene_phase_name(kNowScenePhaseEncode),
                 "encode") == 0, "name encode");
    check(now_scene_phase_name(kNowScenePhaseCount)[0] == '\0',
          "an out-of-range phase has no name");
}

/* A reset must leave nothing of the previous scene behind - not a
   number, not a half-open stack. A phase left open by a scene that
   failed mid-walk would otherwise charge its whole gap to the next one. */
static void test_reset_clears_a_broken_scene(void)
{
    begin(0);
    now_scene_phase_enter(kNowScenePhaseWindows);
    tick(5000);                        /* and never left: the walk gave up */

    now_scene_phase_reset();
    check_us(kNowScenePhaseWindows, 0, "reset: nothing carried over");
    check(now_scene_phase_clock_reads() == 0, "reset: reads cleared");
    now_scene_phase_enter(kNowScenePhaseBind);
    tick(7);
    now_scene_phase_leave(kNowScenePhaseBind);
    check_us(kNowScenePhaseBind, 7, "reset: the new scene is clean");
    check_us(kNowScenePhaseWindows, 0,
             "reset: the abandoned phase claims nothing");
}

int main(void)
{
    test_flat_phases();
    test_nesting_does_not_double_count();
    test_repeated_entries_accumulate();
    test_counter_wrap();
    test_no_clock_reports_nothing();
    test_seam_faults_are_reported();
    test_overflow_pops_symmetrically();
    test_clock_cost_is_published();
    test_names_are_stable();
    test_reset_clears_a_broken_scene();

    if (failures != 0) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("scene_phase: all checks passed\n");
    return 0;
}
