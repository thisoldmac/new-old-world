/* Native test for the ported window/control walk.

       cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek \
          axwalk_test.c ../src/axwalk/axwalk.c ../src/peek/peek_validate.c \
          -o axwalk_test && ./axwalk_test

   This is the first automated coverage this archaeology has ever had.
   Upstream proved the offsets on a real machine and had no host test;
   the port's job is to keep the numbers and add the gate, so what is
   checked here is deliberately split in two:

   1. THE OFFSETS ARE PINNED. Each field is written at exactly one
      address in a synthetic record and read back by value. Change any
      constant in axwalk.c and a named check here goes red - which is
      the only mechanism, short of a PowerBook, that can tell a faithful
      port from a plausible one.

   2. THE BOUNDARY IS EXERCISED. Every pointer the walk follows is
      pushed outside the readable zones, made odd, and zeroed, and the
      walk is required to refuse rather than to read. The fixture's
      arena would have returned bytes for some of those addresses; the
      refusal has to come from the walker. */

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

/* Addresses chosen so that every one of them is even and inside the
   target arena, EXCEPT where a test deliberately moves one. */
enum {
    kWin = 0x00101000,
    kWinTitleH = 0x00102000,      /* StringHandle */
    kWinTitleP = 0x00102100,      /* its Pascal string */
    kRgnH = 0x00102200,           /* RgnHandle */
    kRgn = 0x00402000,            /* the Region itself, in the SYSTEM heap */
    kCtlH = 0x00103000,           /* ControlHandle */
    kCtl = 0x00103100,            /* the ControlRecord */
    kCtl2H = 0x00104000,
    kCtl2 = 0x00104100,
    kWin2 = 0x00105000,
    kStrucH = 0x00102300,         /* the OTHER region's handle */
    kStruc = 0x00402300           /* and the Region itself */
};

/* One window whose content region is (50,80)-(250,480) and whose
   portRect origin is (0,0), so a control's local rect and its global
   rect differ by exactly the content origin.
 *
 * Its STRUCTURE region is deliberately not the content region grown by
 * any round number: (31,77)-(252,483). A fixture where one could be
 * computed from the other would pass against a reader that returned the
 * same rectangle twice, which is the merge's whole failure mode. */
static void build_window(AxFixture *f, unsigned long win, const char *title,
                         unsigned long controls, unsigned long next)
{
    axfix_put16(f, win + 16, 0);          /* portRect.top  (local) */
    axfix_put16(f, win + 18, 0);          /* portRect.left (local) */
    axfix_put16(f, win + 108, 8);         /* windowKind: a document window */
    axfix_put8(f, win + 110, 1);          /* visible */
    axfix_put32(f, win + 114, kStrucH);   /* strucRgn */
    axfix_put32(f, win + 118, kRgnH);     /* contRgn */
    axfix_put32(f, win + 134, kWinTitleH);
    axfix_put32(f, win + 140, controls);
    axfix_put32(f, win + 144, next);

    axfix_put_handle(f, kRgnH, kRgn);
    axfix_put_region(f, kRgn, 50, 80, 250, 480);
    axfix_put_handle(f, kStrucH, kStruc);
    axfix_put_region(f, kStruc, 31, 77, 252, 483);
    axfix_put_handle(f, kWinTitleH, kWinTitleP);
    axfix_put_pstr(f, kWinTitleP, title);
}

static void build_control(AxFixture *f, unsigned long handle,
                          unsigned long record, const char *title,
                          unsigned long next)
{
    axfix_put32(f, record + 0, next);
    axfix_put16(f, record + 8, 10);       /* contrlRect, LOCAL */
    axfix_put16(f, record + 10, 20);
    axfix_put16(f, record + 12, 30);
    axfix_put16(f, record + 14, 100);
    axfix_put8(f, record + 16, 255);      /* contrlVis: nonzero = visible */
    axfix_put8(f, record + 17, 0);        /* contrlHilite: 0 = active */
    axfix_put16(f, record + 18, 1);       /* contrlValue */
    axfix_put16(f, record + 20, 0);       /* contrlMin */
    axfix_put16(f, record + 22, 1);       /* contrlMax */
    axfix_put_pstr(f, record + 40, title);
    axfix_put_handle(f, handle, record);
}

static void window_fields(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;

    axfix_init(&f, &m);
    build_window(&f, kWin, "Untitled 1", kCtlH, kWin2);

    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk, "window reads");
    check(w.address == kWin, "window address echoed");
    check(w.kind == 8, "windowKind @108");
    check(w.visible == 1, "visible @110");
    check(w.control_list == kCtlH, "controlList @140");
    check(w.next_window == kWin2, "nextWindow @144");
    check(w.title_len == 10 && strcmp(w.title, "Untitled 1") == 0,
          "titleHandle @134 -> Pascal string");
    check(w.top == 50 && w.left == 80 && w.bottom == 250 && w.right == 480,
          "contRgn @118 -> rgnBBox");
    check(w.struc_top == 31 && w.struc_left == 77
              && w.struc_bottom == 252 && w.struc_right == 483,
          "strucRgn @114 -> rgnBBox");
    check(w.origin_top == 50 && w.origin_left == 80,
          "content origin = rgnBBox - portRect origin");
}

/* BOTH REGIONS, NEITHER UNDER THE OTHER'S NAME.
 *
 * Until 2026-08-07 this reader returned the content region and
 * peek_read.c returned the structure region, and the scene consumed
 * both under one field - so `windows[].rect` meant different things on
 * different rows and no consumer could ask which. One reader now returns
 * both, and what pins it is that the two rectangles here CANNOT be
 * derived from each other: a reader that read one handle twice, or read
 * the wrong offset, produces two identical rects or two swapped ones and
 * this fails either way.
 *
 * The offsets are the point too: 114 is strucRgn and 118 is contRgn, and
 * a reader that transposed them would still answer plausibly-shaped
 * rectangles for every window on the machine. */
static void both_regions_read_and_not_confused(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0, 0);

    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk, "window reads");
    check(w.top == 50 && w.left == 80,
          "the content rect comes from contRgn @118");
    check(w.struc_top == 31 && w.struc_left == 77,
          "the structure rect comes from strucRgn @114");
    check(!(w.top == w.struc_top && w.left == w.struc_left),
          "the two regions are two readings, not one read twice");
    /* And the structure region is NOT the content region shifted by any
       one constant, which is what the scene used to substitute for
       reading it. */
    check((w.top - w.struc_top) != (w.left - w.struc_left),
          "no single constant relates the two regions");
}

/* A window whose STRUCTURE region cannot be read is refused whole, the
   same policy this file already applied to an unreadable content
   region. The alternative - reporting the window with the content rect
   in both fields - is a plausible rectangle about twenty pixels out,
   which is the class of defect that survives every gate. */
static void an_unreadable_structure_region_refuses_the_window(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0, 0);
    axfix_put32(&f, kWin + 114, 0);       /* no structure region */
    check(now_ax_read_window(&m, kWin, &w) != kNowAxOk,
          "a window with no strucRgn is refused");

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0, 0);
    axfix_put32(&f, kWin + 114, 0x00900000UL);   /* outside both arenas */
    check(now_ax_read_window(&m, kWin, &w) != kNowAxOk,
          "a strucRgn outside the readable zones is refused");
}

static void window_no_title(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;

    axfix_init(&f, &m);
    build_window(&f, kWin, "x", 0, 0);
    axfix_put32(&f, kWin + 134, 0);       /* no title handle at all */

    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk,
          "a titleless window is not a failure");
    check(w.title_len == 0 && w.title[0] == '\0', "title is empty");
}

static void window_refusals(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, kWin2);
    check(now_ax_read_window(&m, kWin + 1, &w) == kNowAxInvalid,
          "an odd window pointer is refused");
    check(now_ax_read_window(&m, 0, &w) == kNowAxInvalid,
          "a null window pointer is refused");
    check(now_ax_read_window(&m, 0x00200000UL, &w) == kNowAxInvalid,
          "a window outside both zones is refused");
    check(f.refused == 0, "the walker refused before the seam was entered");

    /* A poisoned nextWindow refuses the WHOLE record, not just the link. */
    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, 0x00900000UL);
    check(now_ax_read_window(&m, kWin, &w) == kNowAxInvalid,
          "an out-of-zone nextWindow refuses the window");

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0x00101001UL, kWin2);
    check(now_ax_read_window(&m, kWin, &w) == kNowAxInvalid,
          "an odd controlList refuses the window");

    /* No content region, or one whose rgnSize is too small to be one. */
    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0, 0);
    axfix_put32(&f, kWin + 118, 0);
    check(now_ax_read_window(&m, kWin, &w) == kNowAxInvalid,
          "a window with no content region is refused");

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", 0, 0);
    axfix_put16(&f, kRgn, 8);
    check(now_ax_read_window(&m, kWin, &w) == kNowAxInvalid,
          "rgnSize under the header size is not a Region");
}

static void control_fields(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;
    NowAxControl c;

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, 0);
    build_control(&f, kCtlH, kCtl, "OK", kCtl2H);

    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk, "window reads");
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxOk,
          "control reads");
    check(c.address == kCtlH && c.record == kCtl,
          "handle and dereferenced record both reported");
    check(c.next_control == kCtl2H, "contrlNext @0");
    check(c.visible == 1, "contrlVis @16");
    check(c.enabled == 1, "contrlHilite @17 (255 = disabled)");
    check(c.value == 1 && c.min == 0 && c.max == 1,
          "contrlValue/Min/Max @18/20/22");
    check(c.title_len == 2 && strcmp(c.title, "OK") == 0,
          "contrlTitle @40, in-record Str255");
    /* local (10,20,30,100) + content origin (50,80) */
    check(c.top == 60 && c.left == 100 && c.bottom == 80 && c.right == 180,
          "control rect @8 translated to global by the window origin");

    axfix_put8(&f, kCtl + 17, 255);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxOk
          && c.enabled == 0, "hilite 255 reads as disabled");
    axfix_put8(&f, kCtl + 16, 0);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxOk
          && c.visible == 0, "contrlVis 0 reads as invisible");
}

static void control_refusals(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;
    NowAxControl c;

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, 0);
    build_control(&f, kCtlH, kCtl, "OK", 0);
    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk, "window reads");

    check(now_ax_read_control(&m, &w, 0, &c) == kNowAxInvalid,
          "a null ControlHandle is refused");
    check(now_ax_read_control(&m, &w, kCtlH + 1, &c) == kNowAxInvalid,
          "an odd ControlHandle is refused");
    check(now_ax_read_control(&m, NULL, kCtlH, &c) == kNowAxInvalid,
          "a control without its window is refused");

    axfix_put_handle(&f, kCtlH, 0x00901000UL);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxInvalid,
          "a record outside both zones is refused");

    /* A record that starts inside the arena but whose 296 bytes would
       run past its end. The arena would happily clamp; the walker must
       not ask. */
    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, 0);
    (void)now_ax_read_window(&m, kWin, &w);
    axfix_put_handle(&f, kCtlH,
                     AXFIX_TARGET_BASE + AXFIX_TARGET_SIZE - 16);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxInvalid,
          "a record straddling the end of the partition is refused");
    check(f.refused == 0, "no straddling read reached the seam");
}

/* The chain a caller walks: window -> nextWindow, control -> next. The
   walk itself has no loop - bounding it is axresolve's job - but the
   links have to survive the crossing intact or nothing above can. */
static void chains_link_up(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;
    NowAxControl c1;
    NowAxControl c2;

    axfix_init(&f, &m);
    build_window(&f, kWin, "First", kCtlH, kWin2);
    build_control(&f, kCtlH, kCtl, "One", kCtl2H);
    build_control(&f, kCtl2H, kCtl2, "Two", 0);
    /* kWin2 must be a real window or the link check refuses kWin. */
    axfix_put16(&f, kWin2 + 108, 8);
    axfix_put8(&f, kWin2 + 110, 1);
    axfix_put32(&f, kWin2 + 114, kStrucH);
    axfix_put32(&f, kWin2 + 118, kRgnH);
    axfix_put32(&f, kWin2 + 134, 0);
    axfix_put32(&f, kWin2 + 140, 0);
    axfix_put32(&f, kWin2 + 144, 0);

    check(now_ax_read_window(&m, kWin, &w) == kNowAxOk, "first window");
    check(now_ax_read_control(&m, &w, w.control_list, &c1) == kNowAxOk
          && strcmp(c1.title, "One") == 0, "first control");
    check(now_ax_read_control(&m, &w, c1.next_control, &c2) == kNowAxOk
          && strcmp(c2.title, "Two") == 0, "second control via next");
    check(c2.next_control == 0, "the control chain terminates");

    check(now_ax_read_window(&m, w.next_window, &w) == kNowAxOk,
          "second window via nextWindow");
    check(w.next_window == 0, "the window chain terminates");
}

/* The two READ WIDTHS, pinned against the end of the partition. Nothing
   else in this file can see them: everywhere but the boundary, reading
   148 bytes and reading 156 look identical. Here they do not - a record
   that ends exactly at the partition's last byte must read, and one four
   bytes further along must be refused. A widened constant fails the
   first check; a narrowed one fails the second, which is the case that
   matters most, because a walk that reads past a partition is the bus
   error this whole layer exists to prevent. */
static void record_widths(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxWindow w;
    NowAxControl c;
    const unsigned long end = AXFIX_TARGET_BASE + AXFIX_TARGET_SIZE;
    unsigned long win;

    axfix_init(&f, &m);
    win = end - 148;
    build_window(&f, win, "Edge", 0, 0);
    check(now_ax_read_window(&m, win, &w) == kNowAxOk,
          "a window whose last used byte is the partition's last reads");
    axfix_init(&f, &m);
    win = end - 144;
    build_window(&f, win, "Over", 0, 0);
    check(now_ax_read_window(&m, win, &w) == kNowAxInvalid,
          "a window needing four bytes more than remain is refused");

    axfix_init(&f, &m);
    build_window(&f, kWin, "W", kCtlH, 0);
    (void)now_ax_read_window(&m, kWin, &w);
    build_control(&f, kCtlH, end - 296, "Edge", 0);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxOk,
          "a control record ending at the partition's last byte reads");
    build_control(&f, kCtlH, end - 292, "Over", 0);
    check(now_ax_read_control(&m, &w, kCtlH, &c) == kNowAxInvalid,
          "a control record needing four bytes more is refused");
    check(f.refused == 0, "every refusal came before the seam");
}

int main(void)
{
    window_fields();
    both_regions_read_and_not_confused();
    an_unreadable_structure_region_refuses_the_window();
    window_no_title();
    window_refusals();
    control_fields();
    control_refusals();
    chains_link_up();
    record_widths();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axwalk_test: ok\n");
    return 0;
}
