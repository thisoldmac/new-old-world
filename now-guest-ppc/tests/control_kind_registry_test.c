/* The registry that replaced a 3,724-point FindControl sweep.
 *
 * `scene_self.c` used to discover this application's own controls by
 * probing a grid over the window - the only public question available,
 * because nothing here calls CreateRootControl so GetRootControl fails.
 * It cost ~240us a point on an ACTIVE window (1.2-1.9s on the scene where
 * a person clicked into NOW) and answered NOTHING on an inactive one, so
 * a backgrounded NOW mirrored its own window as empty.
 *
 * It is now a lookup, because an application does not have to discover
 * the controls it MADE. That moves the whole risk onto this table's
 * bookkeeping, and onto one property in particular: **a ControlRef the
 * table hands out is dereferenced.** A disposal it did not see is a read
 * of freed memory, not a missing row. So the cases below are mostly about
 * forgetting, not remembering.
 *
 *     cc -Wall -Wextra -Werror \
 *        -I now-guest-ppc/tests/toolbox_shim \
 *        -I now-guest-ppc/src/workshop \
 *        now-guest-ppc/tests/control_kind_registry_test.c \
 *        now-guest-ppc/src/workshop/control_kind.c -o /tmp/t && /tmp/t
 */
#include "control_kind.h"

#include <ControlDefinitions.h>

#include <stdio.h>
#include <string.h>

static int g_failures;

#define CHECK(cond, what)                                                  \
    do {                                                                   \
        if (!(cond)) {                                                     \
            printf("FAIL %s (%s:%d)\n", (what), __FILE__, __LINE__);       \
            ++g_failures;                                                  \
        }                                                                  \
    } while (0)

/* --- the fake Toolbox ---------------------------------------------------
   NewControl hands back whatever the test queued, so a case can talk about
   identity; the dispose calls only count, because what is under test is
   the table, not the Control Manager. */

static ControlRef g_next_control;
static int g_disposed_controls;
static int g_disposed_windows;
static int g_disposed_dialogs;

ControlRef NewControl(WindowRef window, const Rect *bounds,
                      ConstStr255Param title, Boolean visible,
                      short value, short min, short max,
                      short procID, long refCon)
{
    (void)window; (void)bounds; (void)title; (void)visible;
    (void)value; (void)min; (void)max; (void)procID; (void)refCon;
    return g_next_control;
}

void DisposeControl(ControlRef control) { (void)control; ++g_disposed_controls; }
void DisposeWindow(WindowRef window) { (void)window; ++g_disposed_windows; }
void DisposeDialog(DialogRef dialog) { (void)dialog; ++g_disposed_dialogs; }

static WindowRef g_dialog_window;
WindowRef GetDialogWindow(DialogRef dialog) { (void)dialog; return g_dialog_window; }

/* Distinct non-NULL cookies. Nothing dereferences them - the shim's
   ControlRef is opaque - so their addresses are the whole content. */
static char g_cookies[64];
static ControlRef ctl(int n) { return (ControlRef)&g_cookies[n]; }
static WindowRef win(int n) { return (WindowRef)&g_cookies[32 + n]; }

static Rect g_bounds = { 0, 0, 20, 100 };

/* An empty Pascal string: one length byte, zero. */
static const unsigned char kEmptyTitle[] = { 0 };

static ControlRef make(WindowRef window, ControlRef which, short procID)
{
    g_next_control = which;
    return now_control_new(window, &g_bounds, kEmptyTitle, 1,
                           0, 0, 1, procID, 0);
}

/* Is `control` somewhere in `window`'s list? The scene asks by index, so
   this is the question it actually poses. */
static int listed(WindowRef window, ControlRef control)
{
    short i;
    short n = now_control_count(window);

    for (i = 0; i < n; ++i) {
        if (now_control_indexed(window, i) == control) {
            return 1;
        }
    }
    return 0;
}

/* A window's controls are listed, and only that window's. Two windows
   sharing one table is the case that made a per-window key necessary at
   all: NOW has the Workshop and a modal confirm sheet open at once. */
static void test_lists_per_window(void)
{
    ControlRef a = make(win(0), ctl(0), pushButProc);
    ControlRef b = make(win(0), ctl(1), checkBoxProc);
    ControlRef c = make(win(1), ctl(2), scrollBarProc);

    CHECK(now_control_count(win(0)) == 2, "two controls in the first window");
    CHECK(now_control_count(win(1)) == 1, "one in the second");
    CHECK(listed(win(0), a) && listed(win(0), b), "both listed where made");
    CHECK(listed(win(1), c), "the third listed in its own window");
    CHECK(!listed(win(0), c), "a window does not list another's controls");
    CHECK(now_control_indexed(win(0), 2) == NULL, "past the end is NULL");
    CHECK(now_control_indexed(win(0), -1) == NULL, "before the start is NULL");
    CHECK(now_control_count(NULL) == 0, "no window, no controls");
}

/* THE ONE THAT MATTERS. A disposed control must leave the list in the
   same call, because the scene dereferences what this hands it. */
static void test_disposal_removes(void)
{
    ControlRef a = make(win(2), ctl(3), pushButProc);
    ControlRef b = make(win(2), ctl(4), pushButProc);
    int before = g_disposed_controls;

    now_control_dispose(a);
    CHECK(g_disposed_controls == before + 1, "DisposeControl was called");
    CHECK(!listed(win(2), a), "a disposed control is gone from the list");
    CHECK(listed(win(2), b), "and its neighbour is not");
    CHECK(now_control_count(win(2)) == 1, "the count follows");
    CHECK(strcmp(now_control_role(a), "") == 0,
          "a disposed control has no role either");

    now_control_dispose(NULL);
    CHECK(g_disposed_controls == before + 1, "disposing nothing does nothing");
}

/* DisposeWindow destroys the window's controls and tells nobody - which
   is why it is wrapped. A window taken down while its controls are still
   in the table would leave every one of them dangling. */
static void test_window_disposal_forgets_all(void)
{
    make(win(3), ctl(5), pushButProc);
    make(win(3), ctl(6), pushButProc);
    make(win(4), ctl(7), pushButProc);
    CHECK(now_control_count(win(3)) == 2, "two before");

    now_control_dispose_window(win(3));
    CHECK(g_disposed_windows == 1, "DisposeWindow was called");
    CHECK(now_control_count(win(3)) == 0, "the window's controls are gone");
    CHECK(now_control_count(win(4)) == 1, "another window is untouched");
}

static void test_dialog_disposal_forgets_all(void)
{
    make(win(5), ctl(8), pushButProc);
    g_dialog_window = win(5);

    now_control_dispose_dialog((DialogRef)&g_cookies[63]);
    CHECK(g_disposed_dialogs == 1, "DisposeDialog was called");
    CHECK(now_control_count(win(5)) == 0, "the dialog's controls are gone");
}

/* A control made by a constructor with no procID - CreateDataBrowserControl
   is the only one - is handed over afterwards. Before that it was invisible
   to this table, which was harmless when the table only answered "what
   kind"; it is a missing row now that the table answers "what exists". */
static void test_adopt(void)
{
    ControlRef browser = ctl(9);

    now_control_adopt(win(6), browser, kNowControlProcDataBrowser);
    CHECK(listed(win(6), browser), "an adopted control is listed");
    CHECK(strcmp(now_control_role(browser), "dataBrowser") == 0,
          "and reports the role its sentinel names");

    now_control_adopt(win(6), NULL, kNowControlProcDataBrowser);
    CHECK(now_control_count(win(6)) == 1, "adopting nothing adds nothing");
}

/* Roles, by NAME - which is how control_kind.c writes them, so this holds
   whatever the numbers are. The numbers only have to be distinct, and two
   of them colliding is a duplicate `case` the real cross-build refuses. */
static void test_roles(void)
{
    struct { short procID; const char *role; } cases[] = {
        { pushButProc,                   "button" },
        { kControlPushButtonProc,        "button" },
        { kControlPushButLeftIconProc,   "button" },
        { checkBoxProc,                  "checkbox" },
        { radioButProc,                  "radio" },
        { popupMenuProc,                 "popup" },
        { scrollBarProc,                 "scrollbar" },
        { kControlScrollBarLiveProc,     "scrollbar" },
        { kControlGroupBoxTextTitleProc, "group" },
        { kControlProgressBarProc,       "progress" },
        { kControlTriangleAutoToggleProc,"triangle" },
        { 4321,                          "" }
    };
    size_t i;

    for (i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        ControlRef c = make(win(7), ctl(10 + (int)i), cases[i].procID);

        CHECK(strcmp(now_control_role(c), cases[i].role) == 0,
              "the role the procID names");
    }
    CHECK(strcmp(now_control_role(NULL), "") == 0, "no control, no role");
}

/* A creation that fails is not a control, and must not become a row. */
static void test_failed_creation(void)
{
    ControlRef none = make(win(8), NULL, pushButProc);

    CHECK(none == NULL, "the failure is passed through");
    CHECK(now_control_count(win(8)) == 0, "and nothing was recorded");
}

/* The generation is what tells the scene the interface may differ from
   the one it described last time. Both directions have to move it: a
   creation the scene misses is a control it never mentions, and a
   disposal it misses is a read of freed memory. */
static void test_generation_moves_both_ways(void)
{
    unsigned long start = now_control_generation();
    ControlRef c;
    unsigned long after_new;

    c = make(win(9), ctl(24), pushButProc);
    after_new = now_control_generation();
    CHECK(after_new != start, "creation moves it");

    now_control_dispose(c);
    CHECK(now_control_generation() != after_new, "disposal moves it too");
}

/* Filling the table with LIVE controls. The old table wrapped at 192 and
   let a new control claim whichever slot came next, which was fine when a
   lost entry cost a role; now it would hand the scene a ControlRef whose
   control had been disposed. So the new one drops the control it cannot
   record and says the list is no longer complete - a short list that
   announces itself, rather than a wrong one that does not. */
static void test_overflow_is_announced(void)
{
    int i;

    CHECK(now_control_registry_complete(), "complete until it is not");
    /* Cookies are scarce here, so reuse one address per iteration is not
       possible - the table keys on identity. Offsetting into a large
       static gives 512 distinct refs, which is past the 256 slots. */
    for (i = 0; i < 512; ++i) {
        static char sink[512];

        g_next_control = (ControlRef)&sink[i];
        (void)now_control_new(win(10), &g_bounds, kEmptyTitle, 1,
                              0, 0, 1, pushButProc, 0);
    }
    CHECK(!now_control_registry_complete(),
          "a table that could not record everything says so");
}

int main(void)
{
    test_lists_per_window();
    test_disposal_removes();
    test_window_disposal_forgets_all();
    test_dialog_disposal_forgets_all();
    test_adopt();
    test_roles();
    test_failed_creation();
    test_generation_moves_both_ways();
    /* Last: it deliberately exhausts the table. */
    test_overflow_is_announced();

    if (g_failures != 0) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
