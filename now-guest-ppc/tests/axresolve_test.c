/* Native test for the ported resolver: bounds, cycles, duplicate-title
   occurrences and the staleness fingerprint.

       cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek -I . \
          axresolve_test.c ../src/axwalk/axresolve.c ../src/axwalk/axwalk.c \
          ../src/peek/peek_validate.c -o axresolve_test && ./axresolve_test

   The interesting cases here are the ones that are NOT "it found it":
   two buttons with the same label, a window chain that loops, a chain
   longer than the bound, and a reference whose title still matches
   something that is no longer the same element. Each of those has a
   wrong answer that looks exactly like a right one, which is why the
   policy lives in one place rather than in each consumer. */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "axresolve.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kRgnH = 0x0010F000,
    kRgn = 0x00402000,
    kPsnHi = 0,
    kPsnLo = 0x12345
};

/* Windows and controls are laid out on fixed strides so a test can name
   the Nth of either without arithmetic at the call site. */
static unsigned long win_at(int i)
{
    return 0x00101000UL + (unsigned long)i * 0x400UL;
}

static unsigned long ctl_handle(int w, int c)
{
    return 0x00108000UL + (unsigned long)w * 0x400UL
        + (unsigned long)c * 0x10UL;
}

static unsigned long ctl_record(int w, int c)
{
    return 0x0010C000UL + (unsigned long)w * 0x800UL
        + (unsigned long)c * 0x200UL;
}

static void build_window(AxFixture *f, unsigned long win, const char *title,
                         int visible, unsigned long controls,
                         unsigned long next)
{
    unsigned long title_h = win + 0x200;
    unsigned long title_p = win + 0x220;

    axfix_put16(f, win + 16, 0);
    axfix_put16(f, win + 18, 0);
    axfix_put16(f, win + 108, 8);
    axfix_put8(f, win + 110, visible ? 1 : 0);
    axfix_put32(f, win + 118, kRgnH);
    axfix_put32(f, win + 134, title_h);
    axfix_put32(f, win + 140, controls);
    axfix_put32(f, win + 144, next);
    axfix_put_handle(f, title_h, title_p);
    axfix_put_pstr(f, title_p, title);
    axfix_put_handle(f, kRgnH, kRgn);
    axfix_put_region(f, kRgn, 0, 0, 200, 300);
}

static void build_control(AxFixture *f, unsigned long handle,
                          unsigned long record, const char *title,
                          unsigned long next)
{
    axfix_put32(f, record + 0, next);
    axfix_put16(f, record + 8, 0);
    axfix_put16(f, record + 10, 0);
    axfix_put16(f, record + 12, 20);
    axfix_put16(f, record + 14, 80);
    axfix_put8(f, record + 16, 1);
    axfix_put8(f, record + 17, 0);
    axfix_put_pstr(f, record + 40, title);
    axfix_put_handle(f, handle, record);
}

static void ref_for(NowAxRef *ref, const char *win_title, unsigned int win_n,
                    const char *ctl_title, unsigned int ctl_n,
                    unsigned long window_address, unsigned long control)
{
    memset(ref, 0, sizeof(*ref));
    ref->psn_hi = kPsnHi;
    ref->psn_lo = kPsnLo;
    strcpy((char *)ref->window_title, win_title);
    ref->window_title_len = strlen(win_title);
    ref->window_occurrence = win_n;
    strcpy((char *)ref->control_title, ctl_title);
    ref->control_title_len = strlen(ctl_title);
    ref->control_occurrence = ctl_n;
    ref->node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo,
                                                   window_address, control);
}

/* Two windows, the second holding two buttons both called "OK". */
static void build_scene(AxFixture *f)
{
    build_window(f, win_at(0), "Finder", 1, 0, win_at(1));
    build_window(f, win_at(1), "Save", 1, ctl_handle(1, 0), 0);
    build_control(f, ctl_handle(1, 0), ctl_record(1, 0), "OK",
                  ctl_handle(1, 1));
    build_control(f, ctl_handle(1, 1), ctl_record(1, 1), "OK",
                  ctl_handle(1, 2));
    build_control(f, ctl_handle(1, 2), ctl_record(1, 2), "Cancel", 0);
}

static void resolves_by_title(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxRef ref;
    NowAxResolved got;

    axfix_init(&f, &m);
    build_scene(&f);

    ref_for(&ref, "Save", 0, "Cancel", 0, win_at(1), ctl_handle(1, 2));
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got) == kNowAxResolveOk,
          "a unique title resolves");
    check(got.window_address == win_at(1), "to the right window");
    check(got.control_handle == ctl_handle(1, 2), "and the right control");
    check(got.window_z == 1, "z is its index in the chain");
    check(got.visible_window_z == 1, "visible z counts only visible windows");
    check(strcmp(got.control.title, "Cancel") == 0,
          "the resolved control's own fields come back too");
}

/* The whole reason occurrences exist. */
static void duplicate_titles(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxRef ref;
    NowAxResolved got;

    axfix_init(&f, &m);
    build_scene(&f);

    ref_for(&ref, "Save", 0, "OK", 0, win_at(1), ctl_handle(1, 0));
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got) == kNowAxResolveOk
          && got.control_handle == ctl_handle(1, 0),
          "occurrence 0 is the first OK");

    ref_for(&ref, "Save", 0, "OK", 1, win_at(1), ctl_handle(1, 1));
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got) == kNowAxResolveOk
          && got.control_handle == ctl_handle(1, 1),
          "occurrence 1 is the SECOND OK, not the first again");

    ref_for(&ref, "Save", 0, "OK", 2, win_at(1), ctl_handle(1, 1));
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveNotFound,
          "a third OK does not exist and is not invented");
}

/* Found by name, but the addresses moved: the title is still there and
   the thing behind it is not. */
static void stale_reference(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxRef ref;
    NowAxResolved got;

    axfix_init(&f, &m);
    build_scene(&f);

    ref_for(&ref, "Save", 0, "Cancel", 0, win_at(1), ctl_handle(1, 2));
    ref.node_fingerprint ^= 1UL;      /* minted against something else */
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveStale,
          "a fingerprint that no longer matches is Stale, not Ok");
    check(got.control_handle == ctl_handle(1, 2),
          "and the result is still filled, so a caller can see what moved");
}

static void cycles_and_bounds(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxRef ref;
    NowAxResolved got;
    int i;

    /* A window chain that points back at its own head. */
    axfix_init(&f, &m);
    build_window(&f, win_at(0), "A", 1, 0, win_at(1));
    build_window(&f, win_at(1), "B", 1, 0, win_at(0));
    ref_for(&ref, "Z", 0, "Z", 0, 0, 0);
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveCycle,
          "a looping window chain is Cycle, not an infinite walk");

    /* A control chain that loops inside the matched window. */
    axfix_init(&f, &m);
    build_window(&f, win_at(0), "W", 1, ctl_handle(0, 0), 0);
    build_control(&f, ctl_handle(0, 0), ctl_record(0, 0), "a",
                  ctl_handle(0, 1));
    build_control(&f, ctl_handle(0, 1), ctl_record(0, 1), "b",
                  ctl_handle(0, 0));
    ref_for(&ref, "W", 0, "zzz", 0, 0, 0);
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveCycle,
          "a looping control chain is Cycle");

    /* More windows than the bound, none of them the one asked for. */
    axfix_init(&f, &m);
    for (i = 0; i < kNowAxResolveMaxWindows + 2; i++) {
        build_window(&f, win_at(i), "W", 0, 0,
                     i + 1 < kNowAxResolveMaxWindows + 2 ? win_at(i + 1) : 0);
    }
    ref_for(&ref, "nope", 0, "nope", 0, 0, 0);
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveNotFound,
          "a chain past the window bound stops at NotFound");

    check(now_ax_resolve_ref(&m, 0, &ref, &got) == kNowAxResolveNotFound,
          "an empty window list resolves to nothing");
    check(now_ax_resolve_ref(&m, win_at(0), NULL, &got) == kNowAxInvalid,
          "a null reference is refused");
}

/* The named window exists and does not hold the named control: the
   answer is NotFound, and the search does NOT continue into later
   windows. Resolving "the OK in the Save dialog" against a button in
   some other window would be the worst kind of near-miss. */
static void does_not_fall_through(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxRef ref;
    NowAxResolved got;

    axfix_init(&f, &m);
    build_window(&f, win_at(0), "Save", 1, 0, win_at(1));
    build_window(&f, win_at(1), "Other", 1, ctl_handle(1, 0), 0);
    build_control(&f, ctl_handle(1, 0), ctl_record(1, 0), "OK", 0);

    ref_for(&ref, "Save", 0, "OK", 0, win_at(0), ctl_handle(1, 0));
    check(now_ax_resolve_ref(&m, win_at(0), &ref, &got)
          == kNowAxResolveNotFound,
          "the matched window's absence of the control ends the search");
}

static void title_counter(void)
{
    NowAxTitleEntry entries[4];
    NowAxTitleCounter counter;
    unsigned int n;

    now_ax_title_counter_reset(&counter, entries, 4);
    check(now_ax_title_counter_next(&counter, "OK", 2, &n) == kNowAxOk
          && n == 0, "first OK is occurrence 0");
    check(now_ax_title_counter_next(&counter, "Cancel", 6, &n) == kNowAxOk
          && n == 0, "a different title starts its own count");
    check(now_ax_title_counter_next(&counter, "OK", 2, &n) == kNowAxOk
          && n == 1, "second OK is occurrence 1");
    check(now_ax_title_counter_next(&counter, "", 0, &n) == kNowAxOk
          && n == 0, "an empty title is a title too");

    /* Capacity is a refusal, not a silent reuse: a counter that wrapped
       would hand two different elements the same occurrence. */
    check(now_ax_title_counter_next(&counter, "d", 1, &n) == kNowAxOk,
          "the fourth distinct title fits");
    check(now_ax_title_counter_next(&counter, "e", 1, &n) == kNowAxInvalid,
          "the fifth is refused rather than colliding");
    check(now_ax_title_counter_next(&counter, "OK", 2, &n) == kNowAxOk
          && n == 2, "an already-known title still counts when full");
}

/* The fingerprint is a change detector: same inputs, same value; any
   input different, different value. Its exact byte order matters
   because both sides of the port must agree on it. */
static void fingerprint(void)
{
    unsigned long a = now_ax_ref_fingerprint(0, 0x12345, 0x1000, 0x2000);

    check(a == now_ax_ref_fingerprint(0, 0x12345, 0x1000, 0x2000),
          "the fingerprint is stable");
    check(a != now_ax_ref_fingerprint(0, 0x12345, 0x1004, 0x2000),
          "a moved window changes it");
    check(a != now_ax_ref_fingerprint(0, 0x12345, 0x1000, 0x2004),
          "a moved control changes it");
    check(a != now_ax_ref_fingerprint(0, 0x12346, 0x1000, 0x2000),
          "a different process changes it");
    check(a <= 0xFFFFFFFFUL, "it stays a 32-bit value on a 64-bit host");
    /* FNV-1a with the documented feed order, computed independently. */
    check(now_ax_ref_fingerprint(0, 0, 0, 0) == 0x69691905UL,
          "the exact FNV-1a value for four zero words");
}

int main(void)
{
    resolves_by_title();
    duplicate_titles();
    stale_reference();
    cycles_and_bounds();
    does_not_fall_through();
    title_counter();
    fingerprint();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axresolve_test: ok\n");
    return 0;
}
