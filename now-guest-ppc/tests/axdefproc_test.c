/* Native test for the standard-versus-custom split of a foreign control.
 *
 *     cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek \
 *        axdefproc_test.c ../src/axwalk/axwalk.c \
 *        ../src/peek/peek_validate.c -o axdefproc_test && ./axdefproc_test
 *
 * Slice 6 opens by asking how much of the 190 undetermined controls is a
 * producer bug and how much is genuinely custom drawing. The answer this
 * classifier gives is WHERE a control's definition function lives, which
 * is a strictly weaker claim than what the control IS - and the test's
 * main job is to hold that line, because every previous attempt to say
 * something about a foreign control has failed by saying too much.
 *
 * Three things are checked and they are not the same thing:
 *
 * 1. THE OFFSET IS PINNED. contrlDefProc is at 24 in a ControlRecord
 *    (Controls.h, between contrlMax at 22 and contrlData at 28). Its
 *    neighbours are written with distinct values, so reading 22 or 28 by
 *    mistake produces a named failure rather than a plausible address.
 *
 * 2. EVERY BRANCH IS DRIVEN, including the two that say nothing. A
 *    classifier whose refusal path is untested is a classifier that has
 *    only ever been asked easy questions.
 *
 * 3. NOTHING IS MASKED. The classic Control Manager keeps a variation
 *    code for every control, and if it rides in this field's high byte
 *    then the raw longword is not an address. The required behaviour is
 *    Indeterminate - say nothing - and NOT to strip the byte and carry
 *    on, because a 24-bit mask on a 32-bit-clean machine would turn a
 *    layout question into a confidently wrong histogram. That case has
 *    its own check here, and it is the one most likely to fire first
 *    against a real Macintosh. */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kWin = 0x00101000,
    kWinTitleH = 0x00102000,
    kWinTitleP = 0x00102100,
    kRgnH = 0x00102200,
    kRgn = 0x00402000,            /* the Region itself, in the SYSTEM heap */
    kCtlH = 0x00103000,           /* ControlHandle */
    kCtl = 0x00103100,            /* the ControlRecord */

    /* Two plausible CDEF handles, one per heap. The system one stands
       for a System-file CDEF, which carries `sysheap` and so loads once
       into the system heap where every process's controls share it; the
       application one stands for a CDEF in the owning application's own
       resource fork, which loads into that application's partition. */
    kSysDefProc = 0x00401800,
    kAppDefProc = 0x0010A000,

    /* A second home for the window's content region. The default one
       lives in the system heap because that is where regions really
       live, which means a test that takes the system bounds away loses
       the whole window with them; that test supplies this instead so it
       is measuring the classifier and not the boundary. */
    kRgnInTarget = 0x00106000
};

static void build_window(AxFixture *f, unsigned long region)
{
    axfix_put16(f, kWin + 16, 0);         /* portRect origin (0,0) */
    axfix_put16(f, kWin + 18, 0);
    axfix_put8(f, kWin + 108, 8);         /* windowKind: an application's */
    axfix_put8(f, kWin + 110, 255);       /* visible */
    /* Both regions on one handle: these fixtures are not about the
       frame, and axwalk_test is where the two are pinned apart. */
    axfix_put32(f, kWin + 114, kRgnH);    /* structure region */
    axfix_put32(f, kWin + 118, kRgnH);    /* content region */
    axfix_put32(f, kWin + 134, kWinTitleH);
    axfix_put32(f, kWin + 140, kCtlH);
    axfix_put32(f, kWin + 144, 0);
    axfix_put_handle(f, kRgnH, region);
    axfix_put_region(f, region, 50, 80, 250, 480);
    axfix_put_handle(f, kWinTitleH, kWinTitleP);
    axfix_put_pstr(f, kWinTitleP, "Panel");
}

/* One control whose defProc field is whatever the caller wants to try.
   contrlMax (22) and contrlData (28) are given values that could never
   be mistaken for the defProc under test, so an off-by-one read of the
   offset fails loudly instead of returning something address-shaped. */
static void build_control(AxFixture *f, unsigned long def_proc)
{
    axfix_put32(f, kCtl + 0, 0);          /* contrlNext */
    axfix_put16(f, kCtl + 8, 10);         /* contrlRect, LOCAL */
    axfix_put16(f, kCtl + 10, 20);
    axfix_put16(f, kCtl + 12, 30);
    axfix_put16(f, kCtl + 14, 100);
    axfix_put8(f, kCtl + 16, 255);        /* contrlVis */
    axfix_put8(f, kCtl + 17, 0);          /* contrlHilite */
    axfix_put16(f, kCtl + 18, 1);         /* contrlValue */
    axfix_put16(f, kCtl + 20, 0);         /* contrlMin */
    axfix_put16(f, kCtl + 22, 0x0BAD);    /* contrlMax - a NEIGHBOUR */
    axfix_put32(f, kCtl + 24, def_proc);  /* contrlDefProc - under test */
    axfix_put32(f, kCtl + 28, 0xDEADBEEF);/* contrlData - the other one */
    axfix_put_pstr(f, kCtl + 40, "Show:");
    axfix_put_handle(f, kCtlH, kCtl);
}

/* Reads one control with the given defProc and hands back what the walk
   made of it. `m` is passed in so a test can narrow a zone first. */
static int classify_via(AxFixture *f, NowAxMemory *m, unsigned long region,
                        unsigned long def_proc, NowAxControl *out)
{
    NowAxWindow w;

    build_window(f, region);
    build_control(f, def_proc);
    if (now_ax_read_window(m, kWin, &w) != kNowAxOk) {
        return 0;
    }
    return now_ax_read_control(m, &w, kCtlH, out) == kNowAxOk;
}

static int classify(AxFixture *f, NowAxMemory *m, unsigned long def_proc,
                    NowAxControl *out)
{
    return classify_via(f, m, kRgn, def_proc, out);
}

static void offset_is_pinned(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    check(classify(&f, &m, kSysDefProc, &c), "control reads");
    check(c.def_proc == kSysDefProc, "contrlDefProc @24 read by value");
    check(c.max == 0x0BAD, "contrlMax @22 is untouched by the new read");
    /* If the reader had taken 28 it would have got contrlData; if it had
       taken 22 it would have got a halfword pair straddling max. Both
       are address-shaped enough to look fine in a histogram. */
    check(c.def_proc != 0xDEADBEEFUL, "defProc is not contrlData @28");
}

static void the_two_heaps_are_told_apart(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    check(classify(&f, &m, kSysDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcSystem,
          "a defProc in the system heap is a system definition");

    axfix_init(&f, &m);
    check(classify(&f, &m, kAppDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcApplication,
          "a defProc in the target's partition is an application one");
}

static void silence_has_its_own_answers(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    check(classify(&f, &m, 0, &c)
          && c.def_proc_origin == kNowAxDefProcAbsent,
          "a zero defProc is Absent, not a wild address in zone zero");

    /* Outside both arenas. The fixture would refuse to serve bytes here
       too, but the classification never reads through the handle - it
       compares - so this proves the COMPARE refuses, not the seam. */
    axfix_init(&f, &m);
    check(classify(&f, &m, 0x00900000UL, &c)
          && c.def_proc_origin == kNowAxDefProcIndeterminate,
          "a defProc in neither heap is Indeterminate");
    check(f.refused == 0, "the classification never entered the seam");

    axfix_init(&f, &m);
    check(classify(&f, &m, kSysDefProc + 1, &c)
          && c.def_proc_origin == kNowAxDefProcIndeterminate,
          "an odd defProc is not a handle, whatever else it is");
}

/* THE ONE MOST LIKELY TO FIRE ON A REAL MACINTOSH.
 *
 * If a control's variation code rides in the high byte of contrlDefProc,
 * then a scroll bar's field reads 0x10401800 where the handle is
 * 0x00401800. The required answer is Indeterminate. Stripping the byte
 * would produce `system` here and would ALSO produce `system` for any
 * unrelated garbage whose low 24 bits happen to land in the system heap,
 * so the mask cannot be added later on the strength of this test - it
 * would need its own evidence from a machine. */
static void a_variant_byte_is_not_stripped(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    check(classify(&f, &m, 0x10000000UL | kSysDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcIndeterminate,
          "a high byte over a system handle is Indeterminate, not masked");
    check(c.def_proc == (0x10000000UL | kSysDefProc),
          "the raw field is kept whole, so the layout stays diagnosable");
}

/* A zone the walk was never given bounds for must claim nothing. On the
   machine this is the case where LMGetSysZone answered NULL: the honest
   result is that no control can be called system-defined, not that every
   control becomes the application's. */
static void an_unset_zone_claims_nothing(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    m.system_lo = 0;
    m.system_hi = 0;
    check(classify_via(&f, &m, kRgnInTarget, kAppDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcApplication,
          "an unset system zone does not disturb the partition answer");
    check(classify_via(&f, &m, kRgnInTarget, kSysDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcIndeterminate,
          "and a system-heap handle becomes Indeterminate, never the app's");

    /* The system arena still holds the region this window points at, so
       the read itself has to fail rather than silently reclassify. That
       is the walk's existing boundary doing its job, and it is checked
       here so this test cannot be read as "system bounds are optional". */
    check(!classify(&f, &m, kSysDefProc, &c),
          "without system bounds the window's own region is unreadable");
}

/* Order, and it is load-bearing. A target partition is carved out of the
   same address space as the system heap; if a caller ever hands over
   bounds that overlap, a shared CDEF must not be relabelled as the
   application's private one. System is tested first for that reason. */
static void the_system_heap_wins_an_overlap(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl c;

    axfix_init(&f, &m);
    m.target_lo = AXFIX_TARGET_BASE;
    m.target_hi = AXFIX_SYSTEM_BASE + AXFIX_SYSTEM_SIZE;  /* swallows both */
    check(classify(&f, &m, kSysDefProc, &c)
          && c.def_proc_origin == kNowAxDefProcSystem,
          "an overlapping partition does not steal a system definition");
}

/* The line this whole exercise exists to hold: an origin is not a kind.
 * `system` means a documented answer EXISTS somewhere; it does not say
 * button rather than scroll bar, and the walk must not start filling in
 * a title-and-shape guess because it now knows the Toolbox drew it. */
static void an_origin_is_not_a_kind(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowAxControl sys, app;

    axfix_init(&f, &m);
    check(classify(&f, &m, kSysDefProc, &sys), "system-defined control reads");
    axfix_init(&f, &m);
    check(classify(&f, &m, kAppDefProc, &app), "app-defined control reads");

    /* Same title, same rect, same value range - the two records differ in
       exactly one field, and every OTHER field the scene reports has to
       come back identical. If knowing the origin ever starts changing
       what else the walk says, this is where it shows up. */
    check(strcmp(sys.title, app.title) == 0
          && sys.top == app.top && sys.left == app.left
          && sys.bottom == app.bottom && sys.right == app.right
          && sys.value == app.value && sys.min == app.min
          && sys.max == app.max && sys.enabled == app.enabled
          && sys.visible == app.visible,
          "the origin changes nothing else the control reports");
    check(sys.def_proc_origin != app.def_proc_origin,
          "and the origin itself is the one field that differs");
}

int main(void)
{
    offset_is_pinned();
    the_two_heaps_are_told_apart();
    silence_has_its_own_answers();
    a_variant_byte_is_not_stripped();
    an_unset_zone_claims_nothing();
    the_system_heap_wins_an_overlap();
    an_origin_is_not_a_kind();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axdefproc_test: ok\n");
    return 0;
}
