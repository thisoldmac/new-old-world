/* What Edit>Copy actually puts on the scrap.
 *
 * cc -Wall -Wextra -Werror -I ../src/workshop -o /tmp/t \
 *     workshop_scene_text_test.c ../src/workshop/workshop_scene_text.c && /tmp/t
 * (scripts/test-native runs it; it is in that script's manifest.)
 *
 * The sink is the whole of Copy's behaviour. A page's `copy_text` points
 * its own `describe_scene` at this instead of at the host, so everything
 * that decides what a person gets - which runs count as words, how two
 * runs on one line are joined, what happens at the cap - is decided
 * here, once, for every page. That is worth a test that does not need a
 * Macintosh.
 *
 * Three of these guard a specific way of being wrong rather than a
 * feature: a label and its value drawn as two runs on one line must not
 * arrive as two lines (that is copying something nobody is looking at), a
 * panel must contribute nothing (a region has no words in it, and an
 * empty line per card would be the visible shape of that mistake), and
 * the cap must truncate rather than overrun a caller's buffer.
 */
#include <stdio.h>
#include <string.h>

#include "workshop_scene_text.h"

static int failures;

static void check(const char *what, const char *got, const char *want)
{
    if (strcmp(got, want) != 0) {
        printf("FAIL %s\n  got  \"%s\"\n  want \"%s\"\n", what, got, want);
        ++failures;
    }
}

static void check_long(const char *what, long got, long want)
{
    if (got != want) {
        printf("FAIL %s: got %ld, want %ld\n", what, got, want);
        ++failures;
    }
}

static Rect at(short top, short left)
{
    Rect r;

    r.top = top;
    r.left = left;
    r.bottom = (short)(top + 12);
    r.right = (short)(left + 100);
    return r;
}

/* A label and its value are two runs on ONE line. Copying them as two
   lines would hand someone a shape that is on no screen. */
static void same_line_runs_join(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[128];
    Rect label = at(40, 10);
    Rect value = at(40, 120);
    Rect next = at(57, 10);

    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "Address:", &label, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "10.0.2.2", &value, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "Port:", &next, 1);
    check("label and value join", out, "Address:  10.0.2.2\rPort:");
    check_long("length reported", workshop_scene_text_end(&sink),
               (long)strlen("Address:  10.0.2.2\rPort:"));
}

/* A few pixels of drift within one line is still one line; a real line
   break is not. The slop has to discriminate both ways or it is not
   doing anything. */
static void near_baselines_join_far_ones_break(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[128];
    Rect a = at(40, 10);
    Rect near = at(43, 120);      /* 3px: the same line, drawn askew */
    Rect far = at(54, 10);        /* 11px: the next line */

    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "one", &a, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "two", &near, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "three", &far, 1);
    check("slop discriminates", out, "one  two\rthree");
}

/* Regions have no words. A panel per card would otherwise arrive as a
   blank line per card. */
static void regions_contribute_nothing(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[128];
    Rect card = at(30, 8);
    Rect line = at(50, 12);

    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    workshop_scene_add(&w, kWorkshopScenePanel, "TCP/IP", &card, 1);
    workshop_scene_add(&w, kWorkshopSceneIcon, "", &card, 1);
    workshop_scene_add(&w, kWorkshopSceneSelectionBand, "", &card, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "Router  10.0.2.2",
                       &line, 1);
    check("only words are copied", out, "Router  10.0.2.2");
}

/* A page with nothing on it reports 0, which the Workshop reads as
   "nothing to copy" and leaves the scrap alone. An empty string that
   cleared someone's clipboard would be a worse answer than silence. */
static void empty_page_reports_zero(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[32];
    Rect card = at(30, 8);

    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    workshop_scene_add(&w, kWorkshopScenePanel, "Empty", &card, 1);
    workshop_scene_add(&w, kWorkshopSceneStaticText, "", &card, 1);
    check_long("nothing to copy", workshop_scene_text_end(&sink), 0);
    check("buffer left empty", out, "");
}

/* The cap is the page's memory budget, not a suggestion: a console with
   two thousand lines of scrollback must truncate into the buffer it was
   given and stay terminated.
 *
 * The buffer size is chosen so the run that does not fit is PARTIALLY
 * written - 10 + separator = 11 of 16, leaving room for four characters
 * of the next one. An earlier version of this test used a size where the
 * overflowing run happened to have exactly zero room, so truncating and
 * refusing produced identical output and the assertion could not tell
 * them apart: it passed against a version that dropped whole runs. The
 * expected string below is what makes the difference visible.
 */
static void cap_truncates_and_terminates(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[16];
    Rect a = at(40, 10);
    Rect b = at(60, 10);
    int i;

    memset(out, 'X', sizeof out);
    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    for (i = 0; i < 20; ++i) {
        workshop_scene_add(&w, kWorkshopSceneStaticText, "0123456789",
                           i % 2 == 0 ? &a : &b, 1);
    }
    check("the overflowing run is truncated, not dropped", out,
          "0123456789\r0123");
    check_long("stops at cap - 1", workshop_scene_text_end(&sink),
               (long)sizeof out - 1);
    if (out[sizeof out - 1] != '\0') {
        printf("FAIL cap: buffer is not terminated\n");
        ++failures;
    }
    if (strlen(out) != sizeof out - 1) {
        printf("FAIL cap: wrote %lu bytes into an %lu byte buffer\n",
               (unsigned long)strlen(out), (unsigned long)sizeof out);
        ++failures;
    }
}

/* A hidden run is not on screen. The writer carries the flag; nothing
   that is invisible may reach a clipboard. */
static void hidden_runs_are_not_copied(void)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter w;
    char out[64];
    Rect a = at(40, 10);

    workshop_scene_text_begin(&sink, &w, out, (long)sizeof out);
    w.add(w.context, kWorkshopSceneStaticText, "hidden", &a, 1, 0);
    w.add(w.context, kWorkshopSceneStaticText, "shown", &a, 1, 1);
    check("hidden run skipped", out, "shown");
}

int main(void)
{
    same_line_runs_join();
    near_baselines_join_far_ones_break();
    regions_contribute_nothing();
    empty_page_reports_zero();
    cap_truncates_and_terminates();
    hidden_runs_are_not_copied();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
