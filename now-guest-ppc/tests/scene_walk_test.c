/* Native test for the walk-to-scene bridge (src/scene/scene_walk.c).
 *
 *     cc -Wall -Wextra -Werror -I ../src/scene -I ../src/axwalk \
 *        -I ../src/peek -I . scene_walk_test.c ../src/scene/scene_walk.c \
 *        ../src/scene/scene_build.c ../src/axwalk/axwalk.c \
 *        ../src/axwalk/axmenu.c ../src/axwalk/axtext.c \
 *        ../src/peek/peek_validate.c -o scene_walk_test && ./scene_walk_test
 *
 * THIS IS THE TEST THE WIRING EXISTS FOR. The ported walk had automated
 * coverage of its PARSERS from the day it landed; what had none was the
 * layer that decides what a scene CLAIMS from what the parsers return -
 * and that layer is where an honest producer and a lying one look
 * identical from the parser's side. Every case below is one of those
 * decisions:
 *
 *   - a complete chain becomes a `controls` array;
 *   - a chain that is *complete and empty* becomes `[]`, which asserts
 *     something true, and is not the same document as no key at all;
 *   - a chain that stopped early - bound, cycle, or a pointer that
 *     failed validation - becomes NO KEY, plus a notice. A short array
 *     reads as a complete one and there is nowhere beside it to say
 *     otherwise, so it is retracted rather than shipped;
 *   - a menu bar under a refused anchor is never opened at all.
 *
 * The seam is the axwalk fixture's synthetic big-endian arena, so a
 * "process" here is bytes at chosen addresses and the boundary can be
 * crossed on purpose. No Macintosh is in the loop and none is needed:
 * everything under test takes its memory as an argument.
 */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "obsresolve.h"
#include "scene_walk.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kWin = 0x00101000UL,          /* a WindowRecord */
    kWinTitleH = 0x00101400UL,
    kWinTitle = 0x00101410UL,
    kContRgnH = 0x00101500UL,
    kContRgn = 0x00101510UL,
    kCtl1H = 0x00102000UL,        /* ControlHandle 1 */
    kCtl1 = 0x00102100UL,
    kCtl2H = 0x00102400UL,
    kCtl2 = 0x00102500UL,
    kCtl3H = 0x00102600UL,
    kCtl3 = 0x00102700UL,
    kCtl4H = 0x00102800UL,
    kCtl4 = 0x00102900UL,
    kTeH = 0x00103000UL,
    kTe = 0x00103100UL,
    kTextH = 0x00103200UL,
    kText = 0x00103210UL,
    kDitlH = 0x00103400UL,
    kDitl = 0x00103500UL,
    kItemTextH = 0x00103600UL,
    kItemText = 0x00103620UL,
    kStaticTextH = 0x00103700UL,
    kStaticText = 0x00103720UL,
    kListH = 0x00104000UL,
    kList = 0x00104100UL,
    kMenuH0 = 0x00105000UL,
    kMenu0 = 0x00105100UL,
    kMenuH1 = 0x00106000UL,
    kMenu1 = 0x00106100UL,

    /* Outside both arenas: the address a validated read must refuse. */
    kOutside = 0x00900000UL
};

static unsigned long put_ditem(AxFixture *f, unsigned long at,
                               unsigned long handle, int type,
                               int t, int l, int b, int r,
                               const char *text)
{
    size_t n = strlen(text);
    size_t i;
    unsigned long total;

    axfix_put32(f, at, handle);
    axfix_put16(f, at + 4, t);
    axfix_put16(f, at + 6, l);
    axfix_put16(f, at + 8, b);
    axfix_put16(f, at + 10, r);
    axfix_put8(f, at + 12, (unsigned)type);
    axfix_put8(f, at + 13, (unsigned)n);
    for (i = 0; i < n; ++i) {
        axfix_put8(f, at + 14 + (unsigned long)i, (unsigned char)text[i]);
    }
    total = 14 + (unsigned long)n;
    if (total & 1UL) {
        axfix_put8(f, at + total, 0);
        ++total;
    }
    return at + total;
}

/* The WindowRecord fields this walk reads, at the classic offsets
   axwalk.c reads them from. portRect's origin plus the content region's
   global box are what turn a control's LOCAL rect into a global one. */
static void build_window(AxFixture *f, int kind, unsigned long controls,
                         int port_top, int port_left,
                         int t, int l, int b, int r)
{
    axfix_put16(f, kWin + 16, port_top);      /* portRect.top  (local) */
    axfix_put16(f, kWin + 18, port_left);     /* portRect.left (local) */
    axfix_put16(f, kWin + 108, kind);         /* windowKind */
    axfix_put8(f, kWin + 110, 1);             /* visible */
    /* Both regions on one handle: this fixture is not about the frame,
       and axwalk_test is where the two are pinned apart. */
    axfix_put32(f, kWin + 114, kContRgnH);    /* structure region */
    axfix_put32(f, kWin + 118, kContRgnH);    /* content region handle */
    axfix_put32(f, kWin + 134, kWinTitleH);   /* title handle */
    axfix_put32(f, kWin + 140, controls);     /* control list */
    axfix_put32(f, kWin + 144, 0);            /* nextWindow */
    axfix_put_handle(f, kContRgnH, kContRgn);
    axfix_put_region(f, kContRgn, t, l, b, r);
    axfix_put_handle(f, kWinTitleH, kWinTitle);
    axfix_put_pstr(f, kWinTitle, "Save As");
}

/* A ControlRecord: next, rect at 8 (LOCAL), visible/hilite at 16/17,
   value/min/max at 18/20/22, a Str255 title at 40. */
static void build_control(AxFixture *f, unsigned long handle,
                          unsigned long record, unsigned long next,
                          const char *title, int t, int l, int b, int r,
                          int hilite, int value)
{
    axfix_put_handle(f, handle, record);
    axfix_put32(f, record + 0, next);
    axfix_put16(f, record + 8, t);
    axfix_put16(f, record + 10, l);
    axfix_put16(f, record + 12, b);
    axfix_put16(f, record + 14, r);
    axfix_put8(f, record + 16, 1);            /* visible */
    axfix_put8(f, record + 17, (unsigned)hilite);
    axfix_put16(f, record + 18, value);
    axfix_put16(f, record + 20, 0);           /* min */
    axfix_put16(f, record + 22, 1);           /* max */
    axfix_put_pstr(f, record + 40, title);
}

/* A scene with one process and one window already admitted, which is
   the state the collector hands the bridge. */
static int one_window(NowScene *s, NowSceneAnchor anchor)
{
    int p;

    now_scene_begin(s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(s, 0, 7, "SimpleText", 0x74747874UL, 1,
                              anchor, 0);
    (void)now_scene_add_window(s, p, "Save As", 40, 60, 200, 400, 1);
    return p;
}

static void controls_complete(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    /* Content box at (40,60); portRect origin (0,0), so a control at
       local (10,20) is global (50,80). The translation is the walk's,
       and getting it wrong puts every button in the wrong place on a
       consumer's screen.

       WHICH SPACE THE SCENE CARRIES is the whole question here, and this
       test asserted the wrong answer until 2026-08-02. now_ax_read_control
       returns GLOBAL, because the act plane clicks somewhere on a screen.
       The scene is a different consumer: IR v1 documents Control.rect as
       content-relative, Mirror's own SceneBuilder subtracts the content
       origin to make one, and MirrorKit's hit tester subtracts it from
       the click before comparing. Feed it global rects and nothing
       errors - every control is simply tested against a box displaced by
       its own window's origin, so a person clicks one control and
       actuates a neighbour. Four honest integers either way, which is
       why only an assertion naming the SPACE can hold it. */
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "OK", 10, 20, 30, 90, 0, 1);
    build_control(&f, kCtl2H, kCtl2, 0, "Cancel", 10, 100, 30, 170, 255, 0);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].kind_known && s.windows[0].kind == 8,
          "windowKind reaches the row");
    check(s.windows[0].controls_present, "the control plane is present");
    check(s.windows[0].control_count == 2, "both controls are carried");
    check(s.control_count == 2, "and both are in the pool");
    check(strcmp(s.controls[0].title, "OK") == 0, "the first control's title");
    check(s.controls[0].rect.t == 10 && s.controls[0].rect.l == 20,
          "a control's rect reaches the scene content-relative, which is "
          "the space IR v1 names (global would be 50,80)");
    check(s.controls[0].enabled == 1, "hilite 0 is enabled");
    check(s.controls[1].enabled == 0, "hilite 255 is disabled");
    check(s.controls[0].value == 1 && s.controls[0].max == 1,
          "value and max come across");
    check(s.controls_truncated == 0, "and nothing was retracted");
}

/* The distinction the whole plane rests on: a window with a null control
   list is reported as HAVING NO CONTROLS, which is a claim, and is a
   different document from a window this producer did not walk. */
static void empty_is_not_absent(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene walked;
    NowScene unwalked;

    axfix_init(&f, &m);
    build_window(&f, 8, 0, 0, 0, 40, 60, 200, 400);

    one_window(&walked, kNowSceneAnchorOk);
    now_scene_walk_window(&walked, 0, &m, kWin, NULL);
    check(walked.windows[0].controls_present,
          "a null control list still opens the plane");
    check(walked.windows[0].control_count == 0, "with zero controls");

    one_window(&unwalked, kNowSceneAnchorOk);
    check(unwalked.windows[0].controls_present == 0,
          "a window nobody walked reports no control plane at all");
    check(unwalked.windows[0].kind_known == 0,
          "and no kind, because 0 is a legal kind and cannot mean absent");
}

/* A chain that stops early. All three ways of stopping produce the same
   document - no key, plus a notice - because a caller cannot tell a
   short list from a complete one and must not be given the chance. */
static void a_broken_chain_is_retracted(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    /* The second control's handle points outside both arenas. */
    build_control(&f, kCtl1H, kCtl1, kOutside, "OK", 10, 20, 30, 90, 0, 1);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(s.windows[0].controls_present == 0,
          "one unreadable link retracts the whole control plane");
    check(s.control_count == 0, "and returns its entries to the pool");
    check(s.controls_truncated == 1, "the drop is recorded, never silent");
    /* The kind survives: it was read from a record that DID validate,
       and retracting the controls is not a reason to unsay it. */
    check(s.windows[0].kind_known == 1, "the kind it did read still stands");
}

static void a_cycle_is_retracted(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl1H, "Loop", 0, 0, 10, 10, 0, 0);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(s.windows[0].controls_present == 0,
          "a control chain that points at itself is bounded and retracted");
    check(s.control_count == 0, "the pool is returned");
    check(s.controls_truncated == 1, "and the bound is reported");
}

/* THE LENGTH, not just the fact of the bound.
 *
   A retracted plane that says only "our bound" leaves the next question
   open, and answering it by hand is what the Appearance investigation
   had to do. These three cases are the three answers a reader can act on
   differently: a chain that fits, one that is merely longer than the cap
   (raise it, and by this much), and one that never ends (raising it
   would reach nothing).

   Laid out in the fixture's own arena: records 384 bytes apart, because
   the control read validates 296 of them, and handles parked above the
   records so neither table walks into the other. */
enum {
    kLongCtlRec = 0x00102000UL,   /* record i at +i*0x180 */
    kLongCtlRecStride = 0x180UL,
    kLongCtlHandles = 0x0010E000UL, /* handle i at +i*4 */
    kLongChain = 120              /* comfortably past the carrying cap */
};

static void build_long_chain(AxFixture *f, int n, int cyclic)
{
    int i;

    for (i = 0; i < n; ++i) {
        unsigned long handle = kLongCtlHandles + (unsigned long)i * 4UL;
        unsigned long record = kLongCtlRec
                             + (unsigned long)i * kLongCtlRecStride;
        unsigned long next;

        if (i + 1 < n) {
            next = kLongCtlHandles + (unsigned long)(i + 1) * 4UL;
        } else {
            next = cyclic ? kLongCtlHandles : 0UL;
        }
        build_control(f, handle, record, next, "Tab", 0, 0, 10, 10, 0, 0);
    }
}

static void a_long_chain_reports_its_length(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, kLongCtlHandles, 0, 0, 40, 60, 200, 400);
    build_long_chain(&f, kLongChain, 0);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].controls_present == 0,
          "a chain past the cap is retracted, never shipped as a prefix");
    check(s.control_count == 0, "and the pool is returned");
    check(s.windows[0].walk_verdict == kNowSceneWalkControlsBound,
          "the verdict says the bound was ours");
    check(s.windows[0].control_chain_len == kLongChain,
          "and it says how long the chain actually was");
    check(s.windows[0].control_chain_len_exact == 1,
          "exactly, because the chain ended on its own sentinel");
}

static void a_cycle_is_not_a_long_chain(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, kLongCtlHandles, 0, 0, 40, 60, 200, 400);
    build_long_chain(&f, kLongChain, 1);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].walk_verdict == kNowSceneWalkControlsCyclic,
          "a chain that never terminates is cyclic, not merely long - "
          "reported as a bound it would argue forever for a bigger cap");
    check(s.windows[0].control_chain_len_exact == 0,
          "and its length is a floor, never a length");
}

static void a_complete_chain_reports_its_length_too(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "OK", 10, 20, 30, 90, 0, 1);
    build_control(&f, kCtl2H, kCtl2, 0, "Cancel", 10, 100, 30, 170, 255, 0);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].control_chain_len == 2,
          "the ordinary path records the length too, so a reader never "
          "has to infer it from the absence of a note");
    check(s.windows[0].control_chain_len_exact == 1, "and exactly");
}

/* A WINDOW THAT LOST THE POOL WAS NOT ASKED, and the walk has to say so
 * where the evidence is.
 *
 * The control pool is shared across every window in a scene. A window
 * walked after it filled is refused a SLOT and retracts - and every
 * other retraction in this file is a fact about the machine, so lumping
 * this one in with them published "we could not establish this window's
 * controls" for a window nobody had looked at yet. On the wire both
 * arrived as `controls: []`.
 *
 * Watched failing by mutation 2026-08-07: dropping the `pool_full`
 * branch in read_controls leaves the plain ControlsRetracted verdict,
 * and the first two checks below name it.
 */
static void a_window_that_lost_the_pool_was_not_asked(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    int i;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "OK", 10, 20, 30, 90, 0, 1);
    build_control(&f, kCtl2H, kCtl2, 0, "Cancel", 10, 100, 30, 170, 255, 0);

    one_window(&s, kNowSceneAnchorOk);
    /* Spend the whole pool before this window is reached - which is what
       an earlier, busier window in the same scene does. */
    (void)now_scene_open_controls(&s, 0);
    for (i = 0; i < kNowSceneMaxControls; ++i) {
        (void)now_scene_add_control(&s, 0, "spent", 0, 0, 9, 9, 1, 1, 0, 0, 1);
    }
    check(s.control_count == kNowSceneMaxControls,
          "the pool is spent before the walk");

    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].walk_verdict == kNowSceneWalkControlsPoolFull,
          "a window refused a SLOT says the pool ran out, not that its "
          "chain broke - the first is about us and the second is not");
    check(now_scene_controls_state(&s.windows[0])
          == kNowSceneControlsNotFetched,
          "and that reads as notFetched, never unknown");
    /* AND HOW LONG THE CHAIN WAS. One measured panel is not a
       distribution; this is how the windows that LOST get counted. */
    check(s.windows[0].control_chain_len == 2,
          "the chain it never recorded is measured anyway");
    check(s.windows[0].control_chain_len_exact == 1, "and exactly");
}

/* An unreadable window record claims NOTHING. The row keeps exactly what
   peek_read.c established for it. */
static void an_unreadable_record_claims_nothing(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kOutside, NULL);
    check(s.windows[0].kind_known == 0, "no kind");
    check(s.windows[0].controls_present == 0, "no control plane");
    check(s.windows[0].text < 0, "no text");
    check(s.controls_truncated == 0,
          "and no retraction notice - nothing was ever opened");
}

/* A TERec, and the kind gate in front of it. */
static void dialog_text(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 2, 0, 0, 0, 40, 60, 200, 400);   /* dialogKind */
    axfix_put32(&f, kWin + 160, kTeH);
    axfix_put_handle(&f, kTeH, kTe);
    axfix_put16(&f, kTe + 32, 2);                     /* selStart */
    axfix_put16(&f, kTe + 34, 5);                     /* selEnd */
    axfix_put16(&f, kTe + 36, 1);                     /* active */
    axfix_put16(&f, kTe + 60, 8);                     /* teLength */
    axfix_put32(&f, kTe + 62, kTextH);
    axfix_put_handle(&f, kTextH, kText);
    {
        const char *t = "Untitled";
        int i;

        for (i = 0; i < 8; ++i) {
            axfix_put8(&f, kText + (unsigned long)i, (unsigned char)t[i]);
        }
    }

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(s.windows[0].text == 0, "the dialog's text row is attached");
    check(s.text_count == 1, "and is in the pool");
    check(strcmp(s.texts[0].content, "Untitled") == 0, "the content");
    check(s.texts[0].active == 1, "and its active flag");
    check(s.texts[0].truncated == 0, "which fit, so nothing is claimed cut");
}

static void dialog_items_are_guest_semantics(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    unsigned long at;

    axfix_init(&f, &m);
    build_window(&f, 2, kCtl1H, 0, 0, 40, 60, 300, 500);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "Custom", 10, 20, 30, 160,
                  0, 2);
    build_control(&f, kCtl2H, kCtl2, kCtl3H, "Leading zero", 80, 20, 96,
                  180, 0, 1);
    build_control(&f, kCtl3H, kCtl3, kCtl4H, "Off", 105, 20, 121, 80,
                  0, 1);
    build_control(&f, kCtl4H, kCtl4, 0, "OK", 150, 300, 170, 380, 0, 0);

    axfix_put32(&f, kWin + 156, kDitlH);
    axfix_put_handle(&f, kDitlH, kDitl);
    axfix_put16(&f, kDitl, 5);              /* six items, count minus one */
    at = kDitl + 2;
    at = put_ditem(&f, at, kCtl1H, 7, 10, 20, 30, 160, "");
    at = put_ditem(&f, at, kItemTextH, 16, 40, 20, 60, 80, "old");
    at = put_ditem(&f, at, kStaticTextH, 8, 40, 90, 60, 150, "Old:");
    at = put_ditem(&f, at, kCtl2H, 5, 80, 20, 96, 180,
                   "Leading zero");
    at = put_ditem(&f, at, kCtl3H, 6, 105, 20, 121, 80, "Off");
    (void)put_ditem(&f, at, kCtl4H, 4, 150, 300, 170, 380, "OK");
    axfix_put16(&f, kWin + 164, 1);          /* item 2 focused, zero-based */
    axfix_put16(&f, kWin + 168, 6);          /* item 6 is default */

    axfix_put32(&f, kWin + 160, kTeH);
    axfix_put_handle(&f, kTeH, kTe);
    axfix_put16(&f, kTe + 32, 0);
    axfix_put16(&f, kTe + 34, 1);
    axfix_put16(&f, kTe + 36, 1);
    axfix_put16(&f, kTe + 60, 1);
    axfix_put32(&f, kTe + 62, kTextH);
    axfix_put_handle(&f, kTextH, kText);
    axfix_put8(&f, kText, '9');

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].dialog_items_present,
          "a validated live DITL opens the dialog-item plane");
    check(s.windows[0].dialog_item_count == 6,
          "every dialog item is preserved, including non-controls");
    check(s.dialog_items[0].kind == kNowSceneSemanticUnknown
          && !s.dialog_items[0].value_known,
          "a resource control stays unknown without a proven CDEF kind");
    check(s.dialog_items[1].kind == kNowSceneSemanticEditText
          && strcmp(s.dialog_items[1].value, "9") == 0
          && s.dialog_items[1].focused
          && s.dialog_items[1].selection_start == 0
          && s.dialog_items[1].selection_end == 1,
          "edit text carries focus, value and validated selection");
    check(s.dialog_items[2].kind == kNowSceneSemanticStaticText
          && strcmp(s.dialog_items[2].title, "Old:") == 0
          && !s.dialog_items[2].value_known,
          "static text keeps its DITL value without misreading its live handle");
    check(s.dialog_items[3].kind == kNowSceneSemanticCheckBox
          && s.dialog_items[3].state_known && s.dialog_items[3].state_on,
          "checkbox state comes from its matched live ControlRecord");
    check(s.dialog_items[4].kind == kNowSceneSemanticRadioButton,
          "radio and checkbox types stay distinct");
    check(s.dialog_items[5].default_known
          && s.dialog_items[5].is_default,
          "the DialogRecord's default item reaches the exact button");
    check(!s.dialog_items[0].default_known,
          "defaultness applies to push buttons, not resource controls");
}

/* THE TWO WALKS MUST NOT CONTRADICT EACH OTHER.
 *
 * Mail's Internet-setup alert, as sweep A found it on 2026-08-07: the
 * control walk reported Yes / No / Set Up Now and the dialog-item walk
 * reported OK / Cancel / Don't Save - the same three refs, the same
 * three rects, three different names. A DITL carries the RESOURCE's
 * title, frozen when the dialog was built; SetControlTitle writes to the
 * ControlRecord and never back. So both walks were reporting honestly
 * from two different moments, and a driving agent reading one label and
 * clicking the other control is the worst outcome this surface has.
 *
 * The fixture arranges exactly that divergence and asserts there is one
 * answer. It is also the reason the last case exists: a live control
 * with NO title must not fall back to the resource's text, or the
 * contradiction returns from the other side. */
static void the_two_walks_agree_on_a_shared_ref(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    unsigned long at;

    axfix_init(&f, &m);
    build_window(&f, 2, kCtl1H, 0, 0, 40, 60, 300, 500);
    /* What the machine says NOW. */
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "Yes", 150, 300, 170, 380,
                  0, 0);
    build_control(&f, kCtl2H, kCtl2, kCtl3H, "Set Up Now", 150, 100, 170,
                  260, 0, 0);
    build_control(&f, kCtl3H, kCtl3, 0, "", 180, 100, 200, 260, 0, 0);

    axfix_put32(&f, kWin + 156, kDitlH);
    axfix_put_handle(&f, kDitlH, kDitl);
    axfix_put16(&f, kDitl, 2);               /* three items */
    at = kDitl + 2;
    /* What the RESOURCE said when the dialog was built. */
    at = put_ditem(&f, at, kCtl1H, 4, 150, 300, 170, 380, "OK");
    at = put_ditem(&f, at, kCtl2H, 4, 150, 100, 170, 260, "Don't Save");
    (void)put_ditem(&f, at, kCtl3H, 4, 180, 100, 200, 260, "Cancel");
    axfix_put16(&f, kWin + 164, -1);
    axfix_put16(&f, kWin + 168, 1);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);

    check(s.windows[0].dialog_item_count == 3, "three items reach the scene");
    check(strcmp(s.dialog_items[0].title, "Yes") == 0,
          "the live control wins over the DITL's stale 'OK'");
    check(strcmp(s.dialog_items[1].title, "Set Up Now") == 0,
          "...and over 'Don't Save'");
    check(strcmp(s.dialog_items[2].title, "") == 0,
          "a live control with no title publishes none, rather than "
          "reinstating the resource's 'Cancel'");
    check(strcmp(s.controls[0].title, "Yes") == 0
          && strcmp(s.controls[1].title, "Set Up Now") == 0,
          "and the control walk says the same thing it always did");
}

static void malformed_ditl_retracts_the_plane(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    unsigned long tail = AXFIX_TARGET_BASE + AXFIX_TARGET_SIZE - 4;

    axfix_init(&f, &m);
    build_window(&f, 2, 0, 0, 0, 40, 60, 200, 400);
    axfix_put32(&f, kWin + 156, kDitlH);
    axfix_put_handle(&f, kDitlH, tail);
    axfix_put16(&f, tail, 0);                 /* one item, no room for it */
    axfix_put16(&f, kWin + 164, -1);
    axfix_put16(&f, kWin + 168, 0);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(!s.windows[0].dialog_items_present,
          "a malformed DITL emits no plausible prefix");
    check(s.dialog_item_count == 0 && s.dialog_items_truncated,
          "the affected plane retracts and records the failure");
}

/* The gate is safety, not tidiness: offset 160 is past the end of a
   plain WindowRecord, so an ordinary window's text read would interpret
   whatever follows it. */
static void text_is_gated_on_the_kind(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_window(&f, 8, 0, 0, 0, 40, 60, 200, 400);   /* documentKind */
    axfix_put32(&f, kWin + 160, kTeH);                /* a plausible handle */
    axfix_put_handle(&f, kTeH, kTe);
    axfix_put16(&f, kTe + 60, 4);
    axfix_put32(&f, kTe + 62, kTextH);
    axfix_put_handle(&f, kTextH, kText);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(s.windows[0].text < 0,
          "a non-dialog window reports no text even when the bytes after "
          "its record would parse as a TextEdit handle");
}

/* --- the menu bar ------------------------------------------------------ */

static unsigned long build_menu(AxFixture *f, unsigned long handle,
                                unsigned long record, int id,
                                const char *title, unsigned long flags)
{
    size_t n = strlen(title);

    axfix_put_handle(f, handle, record);
    axfix_put16(f, record + 0, id);
    axfix_put16(f, record + 2, 60);
    axfix_put16(f, record + 4, 100);
    axfix_put32(f, record + 6, 0);
    axfix_put32(f, record + 10, flags);
    axfix_put_pstr(f, record + 14, title);
    return record + 14 + 1 + n;
}

static unsigned long put_item(AxFixture *f, unsigned long at,
                              const char *text, unsigned cmd, unsigned mark)
{
    size_t len = strlen(text);
    size_t i;

    axfix_put8(f, at, (unsigned)len);
    for (i = 0; i < len; i++) {
        axfix_put8(f, at + 1 + i, (unsigned char)text[i]);
    }
    axfix_put8(f, at + 1 + len, 0);           /* icon */
    axfix_put8(f, at + 2 + len, cmd);
    axfix_put8(f, at + 3 + len, mark);
    axfix_put8(f, at + 4 + len, 0);           /* style */
    return at + 5 + len;
}

static unsigned long put_prefixed_item(AxFixture *f, unsigned long at,
                                       const char *text)
{
    size_t len = strlen(text);
    size_t i;

    axfix_put8(f, at, (unsigned)(len + 2));
    axfix_put8(f, at + 1, 0);
    axfix_put8(f, at + 2, 0);
    for (i = 0; i < len; ++i) {
        axfix_put8(f, at + 3 + i, (unsigned char)text[i]);
    }
    axfix_put8(f, at + 3 + len, 0);           /* icon */
    axfix_put8(f, at + 4 + len, 0);           /* command */
    axfix_put8(f, at + 5 + len, 0);           /* mark */
    axfix_put8(f, at + 6 + len, 0);           /* style */
    return at + 7 + len;
}

static void build_bar(AxFixture *f)
{
    unsigned long items;

    axfix_put_handle(f, kListH, kList);
    axfix_put16(f, kList, 2 * 6);             /* two menus */
    axfix_put32(f, kList + 6, kMenuH0);
    axfix_put16(f, kList + 10, 0);
    axfix_put32(f, kList + 12, kMenuH1);
    axfix_put16(f, kList + 16, 44);

    items = build_menu(f, kMenuH0, kMenu0, 129, "File", 0xFFFFFFFFUL);
    items = put_item(f, items, "New", 'N', 0);
    items = put_item(f, items, "-", 0, 0);    /* the separator convention */
    items = put_item(f, items, "Quit", 'Q', 0);
    axfix_put8(f, items, 0);                  /* the list's sentinel */

    items = build_menu(f, kMenuH1, kMenu1, 130, "Edit", 0xFFFFFFFDUL);
    items = put_item(f, items, "Undo", 'Z', 0);
    /* cmdChar 0x1B is the Menu Manager's HIERARCHICAL-MENU marker, not a
       command key. Reporting it as one would put a control character in
       front of a person as a keyboard shortcut. */
    items = put_item(f, items, "Recent", 0x1B, 0x12);
    axfix_put8(f, items, 0);
}

static void menubar_complete(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    build_bar(&f);
    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_menubar(&s, 0, &m, kListH);

    check(s.menubar_present, "the menu bar plane opens");
    check(s.menubar_proc == 0, "attributed to the front process");
    check(s.menu_count == 2, "two menus");
    check(strcmp(s.menus[0].title, "File") == 0, "the first menu's title");
    check(s.menus[0].id == 129 && s.menus[1].left == 44,
          "its id and the second's left edge");
    check(s.menus[0].items_present && s.menus[0].item_count == 3,
          "the first menu's items");
    check(s.menus[1].items_present && s.menus[1].item_count == 2,
          "and the second's, in its own block");
    check(strcmp(s.menu_items[s.menus[1].first_item].title, "Undo") == 0,
          "each menu's items are indexed from its own first_item");
    check(s.menu_items[1].separator == 1, "a lone hyphen is a separator");
    check(s.menu_items[0].separator == 0, "and an ordinary item is not");
    check(s.menu_items[0].cmd == 'N', "a command key comes across");
    check(s.menu_items[1].cmd == '\0', "and an item without one carries none");
    /* Edit's flags clear bit 1, so item 1 is disabled while the menu is
       enabled - the Menu Manager's own rule, arriving intact. */
    check(s.menu_items[s.menus[1].first_item].enabled == 0,
          "a per-item enable bit survives the bridge");
    check(s.menu_items[s.menus[1].first_item + 1].cmd == '\0',
          "a cmdChar marker byte is NOT reported as a command key");
    check(s.menu_items[s.menus[1].first_item + 1].mark == 1,
          "but its mark character is a mark");
    check(s.menubar_refused == 0, "nothing was dropped");
}

static void blank_self_apple_uses_only_guest_system_rows(void)
{
    static const char *rows[16] = {
        "Apple System Profiler", "Calculator", "Chooser",
        "Control Panels", "Find File", "Key Caps", "Network Browser",
        "Note Pad", "Recent Applications", "Recent Documents",
        "Recent Servers", "Scrapbook", "Sherlock 2", "SimpleSound",
        "Stickies", "System Preferences"
    };
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    unsigned long items;
    int p;
    int menu;
    int i;

    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    axfix_put16(&f, kList, 6);                /* one menu */
    axfix_put32(&f, kList + 6, kMenuH0);
    axfix_put16(&f, kList + 10, 0);
    items = build_menu(&f, kMenuH0, kMenu0, 256, "\024",
                       0xFFFFFFFFUL);
    items = put_item(&f, items, "About This Computer", 0, 0);
    items = put_item(&f, items, "-", 0, 0);
    for (i = 0; i < 16; ++i) {
        items = put_prefixed_item(&f, items, rows[i]);
    }
    axfix_put8(&f, items, 0);

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 7, "New Old World", 0x4E4F576FUL,
                              1, kNowSceneAnchorOk, 0);
    check(now_scene_open_menubar(&s, p), "self menubar opens");
    menu = now_scene_add_menu(&s, "\024", -16383, 10);
    for (i = 1; i <= 16; ++i) {
        check(now_scene_add_menu_item(&s, menu, "", (short)i,
                                      0, 1, 0, '\0'),
              "the system shell row is represented");
    }

    check(now_scene_fill_blank_system_apple(&s, &m, kListH),
          "a validated guest system menu fills the blank self shell");
    check(strcmp(s.menu_items[s.menus[menu].first_item].title,
                 "Apple System Profiler") == 0,
          "the Finder-specific About and separator prefix are not copied");
    check(strcmp(s.menu_items[s.menus[menu].first_item + 15].title,
                 "System Preferences") == 0,
          "all sixteen guest Apple Menu Items rows survive");
    check(s.menu_items[s.menus[menu].first_item].index == 1
          && s.menu_items[s.menus[menu].first_item + 15].index == 16,
          "the current menu's MenuSelect indices remain authoritative");
}

/* A process with no menu bar: the plane opens and carries zero menus,
   which is an ANSWER. Refusing here would say "not reported" about
   something that was. */
static void a_null_menu_list_is_an_empty_answer(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_menubar(&s, 0, &m, 0);
    check(s.menubar_present, "a null menu list still opens the plane");
    check(s.menu_count == 0, "with no menus in it");
    check(s.menubar_refused == 0, "and nothing is reported as dropped");
}

static void an_unparsable_list_retracts_the_plane(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;

    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    /* A header word that is not a multiple of the entry stride is not a
       MenuList. axmenu.c refuses it; the bridge must not turn that into
       "this application has no menus". */
    axfix_put16(&f, kList, 7);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_menubar(&s, 0, &m, kListH);
    check(s.menubar_present == 0, "an unparsable list leaves NO menubar key");
    check(s.menubar_refused == 1, "and says so, rather than dropping it "
          "silently");
}

/* The independent refusal. Assembly declines the plane for a process
   whose anchor does not admit data, one layer above the code that
   declined to make the walk - the same rule now_scene_add_window
   enforces for windows. */
static void a_refused_anchor_never_opens_the_bar(void)
{
    AxFixture f;
    NowAxMemory m;
    NowScene s;
    NowSceneAnchor refused[4];
    int i;

    axfix_init(&f, &m);
    build_bar(&f);
    refused[0] = kNowSceneAnchorAmbiguous;
    refused[1] = kNowSceneAnchorMismatch;
    refused[2] = kNowSceneAnchorNotFound;
    refused[3] = kNowSceneAnchorUnreadable;

    for (i = 0; i < 4; ++i) {
        one_window(&s, refused[i]);
        now_scene_walk_menubar(&s, 0, &m, kListH);
        check(s.menubar_present == 0,
              "a refused anchor admits no menu bar");
        check(s.menu_count == 0, "and no menus leak into the pool");
        check(s.menubar_refused == 0,
              "a bar that was never opened is not a bar that was dropped");
    }
}

/* --- the reference plane ------------------------------------------------

   THE ONLY QUESTION WORTH ASKING of a scene's `ref` is whether it
   RESOLVES. A well-formed token that names nothing is worse than an
   absent one: the renderer draws a clickable button, the person presses
   it, and the act is refused - which is the exact state this whole
   change is against. So the assertions below take the string OUT of the
   encoded scene's row and hand it to the resolver the act plane calls,
   against the same arena, and check which element comes back.

   The two controls carry the same shape of failure the duplicate-title
   case does one level down: if the walk filed a reference against the
   wrong row index, both rows would still look complete and Cancel would
   act for OK. */

enum {
    kRefPsnLo = 0x4321,
    kRefFingerprint = 0x0FEEDBAC
};

static void ref_live(NowObsLive *live, const NowAxMemory *m)
{
    memset(live, 0, sizeof(*live));
    live->bind = kNowObsBindOk;
    live->process_fingerprint = kRefFingerprint;
    live->window_list = kWin;
    live->memory = m;
}

static void references_resolve(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowScene         s;
    NowObsRegistry   registry;
    NowObsWalk       refs;
    NowObsLive       live;
    NowObsResolution resolution;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "OK", 10, 20, 30, 90, 0, 1);
    build_control(&f, kCtl2H, kCtl2, 0, "Cancel", 10, 100, 30, 170, 255, 0);

    now_obs_registry_init(&registry, 0xC0FFEEUL, 0x0DDBA11UL);
    now_obs_walk_begin(&refs, &registry);
    now_obs_walk_aim(&refs, &m, kWin, 0, kRefPsnLo, kRefFingerprint, 900);
    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, &refs);
    now_obs_walk_end(&refs);
    ref_live(&live, &m);

    check(s.windows[0].ref[0] != '\0', "the window row carries a reference");
    now_obs_resolve(&registry, kNowObsKindWindow, s.windows[0].ref,
                    strlen(s.windows[0].ref), &live, &resolution);
    check(resolution.verdict == kNowObsOk,
          "and it resolves through the act plane's resolver");
    check(resolution.resolved.window_address == kWin,
          "to the window the scene reported");

    check(s.controls[0].ref[0] != '\0' && s.controls[1].ref[0] != '\0',
          "both control rows carry references");
    check(strcmp(s.controls[0].ref, s.controls[1].ref) != 0,
          "and they are two different references");
    now_obs_resolve(&registry, kNowObsKindElement, s.controls[0].ref,
                    strlen(s.controls[0].ref), &live, &resolution);
    check(resolution.verdict == kNowObsOk
          && resolution.resolved.control_handle == kCtl1H,
          "the row titled OK resolves to the OK control");
    now_obs_resolve(&registry, kNowObsKindElement, s.controls[1].ref,
                    strlen(s.controls[1].ref), &live, &resolution);
    check(resolution.verdict == kNowObsOk
          && resolution.resolved.control_handle == kCtl2H,
          "and the row titled Cancel to the Cancel control - the reference "
          "is filed against the row it names");
}

/* Fetch twice, as a person pressing refresh does. The references must
   not change: the scene the person is looking at when they click is the
   one from the PREVIOUS fetch, so a producer that renamed everything on
   every walk would make a rendered scene actable only until it
   refreshed. */
static void a_refetch_keeps_its_references(void)
{
    AxFixture      f;
    NowAxMemory    m;
    NowScene       first;
    NowScene       second;
    NowObsRegistry registry;
    NowObsWalk     refs;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, kCtl2H, "OK", 10, 20, 30, 90, 0, 1);
    build_control(&f, kCtl2H, kCtl2, 0, "Cancel", 10, 100, 30, 170, 255, 0);
    now_obs_registry_init(&registry, 0x515EUL, 0x0BUL);

    now_obs_walk_begin(&refs, &registry);
    now_obs_walk_aim(&refs, &m, kWin, 0, kRefPsnLo, kRefFingerprint, 900);
    one_window(&first, kNowSceneAnchorOk);
    now_scene_walk_window(&first, 0, &m, kWin, &refs);
    now_obs_walk_end(&refs);

    now_obs_walk_begin(&refs, &registry);
    /* A later walk reads a later clock, which must not be part of what a
       reference means. */
    now_obs_walk_aim(&refs, &m, kWin, 0, kRefPsnLo, kRefFingerprint, 4500);
    one_window(&second, kNowSceneAnchorOk);
    now_scene_walk_window(&second, 0, &m, kWin, &refs);
    now_obs_walk_end(&refs);

    check(strcmp(first.windows[0].ref, second.windows[0].ref) == 0,
          "the window keeps its reference across a refetch");
    check(strcmp(first.controls[0].ref, second.controls[0].ref) == 0
          && strcmp(first.controls[1].ref, second.controls[1].ref) == 0,
          "and so does every control");
    check(registry.minted == 3 && registry.reused == 3,
          "the second fetch interned rather than grew the registry");
}

/* No seam, no references - and every other claim in the row unchanged. A
   producer without a reference layer emits a scene that draws correctly
   and admits it can name nothing, which is the honest shape. */
static void no_seam_means_no_references(void)
{
    AxFixture   f;
    NowAxMemory m;
    NowScene    s;

    axfix_init(&f, &m);
    build_window(&f, 8, kCtl1H, 0, 0, 40, 60, 200, 400);
    build_control(&f, kCtl1H, kCtl1, 0, "OK", 10, 20, 30, 90, 0, 1);

    one_window(&s, kNowSceneAnchorOk);
    now_scene_walk_window(&s, 0, &m, kWin, NULL);
    check(s.windows[0].ref[0] == '\0', "no window reference");
    check(s.controls[0].ref[0] == '\0', "no control reference");
    check(s.windows[0].control_count == 1 && s.windows[0].controls_present,
          "and the control plane is reported exactly as before");
}

int main(void)
{
    controls_complete();
    empty_is_not_absent();
    a_broken_chain_is_retracted();
    a_cycle_is_retracted();
    a_long_chain_reports_its_length();
    a_cycle_is_not_a_long_chain();
    a_complete_chain_reports_its_length_too();
    a_window_that_lost_the_pool_was_not_asked();
    an_unreadable_record_claims_nothing();
    dialog_text();
    dialog_items_are_guest_semantics();
    the_two_walks_agree_on_a_shared_ref();
    malformed_ditl_retracts_the_plane();
    text_is_gated_on_the_kind();
    menubar_complete();
    blank_self_apple_uses_only_guest_system_rows();
    a_null_menu_list_is_an_empty_answer();
    an_unparsable_list_retracts_the_plane();
    a_refused_anchor_never_opens_the_bar();

    references_resolve();
    a_refetch_keeps_its_references();
    no_seam_means_no_references();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("scene_walk: ok\n");
    return 0;
}
