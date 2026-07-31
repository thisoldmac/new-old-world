/* The Diagnostics page's Toolbox-free half: how tall a card is in each
 * state, which probes this guest serves, and the two absences the page
 * exists to render honestly - a probe this Mac does not answer, and a
 * putstat that has no transfer to describe.
 *
 *     cd now-guest-ppc/tests
 *     cc -Wall -Wextra -Werror -I ../src diag_layout_test.c \
 *        ../src/diagnostics/diag_layout.c -o /tmp/t && /tmp/t
 *
 * What is NOT covered: the probes themselves. now_vprobe_run times real
 * framebuffer reads and now_files_receive_stats reads counters a transfer
 * filled in; neither exists off a Mac. What is covered is every decision
 * the page makes ABOUT their answers.
 */

#include <stdio.h>
#include <string.h>

#include "diag_layout.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("  FAIL %s\n", what);
        ++failures;
    }
}

static void body_rect(Rect *r)
{
    r->left = 160;
    r->top = 38;
    r->right = 744;
    r->bottom = 455;
}

static void compute(DiagLayout *lay, DiagCardState a, DiagCardState b,
                    DiagCardState c, short rows_a, short rows_c)
{
    Rect body;
    DiagCardState states[kDiagProbeCount];
    short rows[kDiagProbeCount];

    body_rect(&body);
    states[kDiagVProbe] = a;
    states[kDiagShotDiag] = b;
    states[kDiagPutStat] = c;
    rows[kDiagVProbe] = rows_a;
    rows[kDiagShotDiag] = 0;
    rows[kDiagPutStat] = rows_c;
    diag_layout_compute(&body, states, rows, lay);
}

static void test_served(void)
{
    /* This guest's own command table, which is what the page renders.
       shotdiag belongs to the 68K sibling and always will. */
    check(diag_probe_served(kDiagVProbe), "this guest serves vprobe");
    check(diag_probe_served(kDiagPutStat), "this guest serves putstat");
    check(!diag_probe_served(kDiagShotDiag),
          "this guest does not serve shotdiag");
}

static void test_absent_card_has_no_control(void)
{
    DiagLayout lay;
    char line[192];

    compute(&lay, kDiagReady, kDiagAbsent, kDiagReady, 0, 0);

    /* The defect this page exists to avoid: a button that does nothing.
       An absent probe gets no rectangle at all, so the view has nothing
       to create. */
    check(diag_button_title(kDiagShotDiag, kDiagAbsent) == NULL,
          "an absent probe has no button title");
    check(lay.cards[kDiagShotDiag].button.right
              == lay.cards[kDiagShotDiag].button.left,
          "an absent probe has no button rectangle");
    check(diag_button_title(kDiagVProbe, kDiagReady) != NULL,
          "a served probe does have one");
    check(lay.cards[kDiagVProbe].button.right
              > lay.cards[kDiagVProbe].button.left,
          "and a rectangle for it");

    check(diag_body_line(kDiagShotDiag, kDiagAbsent, 0, line,
                         (long)sizeof line) > 0,
          "the absent card says so");
    check(strstr(line, "shotdiag") != NULL, "and names the verb");
    check(diag_body_line(kDiagShotDiag, kDiagAbsent, 1, line,
                         (long)sizeof line) > 0,
          "and gives a second line");
    /* Absence is a fact about which guest this is, never about the
       machine's health, and the sentence has to say that outright. */
    check(strstr(line, "Nothing is wrong") != NULL,
          "the absent card exonerates the machine");
    check(strstr(line, "68K") != NULL, "and names the sibling that serves it");

    /* A probe both guests serve, absent anyway, must not be blamed on the
       68K guest - that would be a confident wrong answer. */
    check(diag_body_line(kDiagVProbe, kDiagAbsent, 1, line,
                         (long)sizeof line) > 0,
          "an absent vprobe still explains itself");
    check(strstr(line, "68K") == NULL,
          "but does not blame the wrong guest");
}

static void test_never_run_putstat(void)
{
    DiagPutStat stats;
    DiagRow rows[kDiagMaxRows];
    char line[192];

    memset(&stats, 0, sizeof stats);
    check(!diag_putstat_has_run(&stats),
          "all-zero counters mean nothing has arrived");

    /* Every one of these on its own is proof a transfer happened. */
    stats.chunks = 1;
    check(diag_putstat_has_run(&stats), "a chunk counts");
    memset(&stats, 0, sizeof stats);
    stats.bytes = 1;
    check(diag_putstat_has_run(&stats), "a byte counts");
    memset(&stats, 0, sizeof stats);
    stats.writes = 1;
    check(diag_putstat_has_run(&stats), "a write counts");
    memset(&stats, 0, sizeof stats);
    stats.us_total = 1;
    check(diag_putstat_has_run(&stats), "time in the receive path counts");

    /* A resumed transfer that then received nothing is still not a
       measurement of anything, so resumed_from alone does not flip it. */
    memset(&stats, 0, sizeof stats);
    stats.resumed_from = 4096;
    check(!diag_putstat_has_run(&stats),
          "a resume offset alone is not an arrival");

    check(diag_body_line(kDiagPutStat, kDiagNothingYet, 0, line,
                         (long)sizeof line) > 0,
          "the never-run card says so");
    check(strstr(line, "no transfer") != NULL,
          "and says there is nothing to describe");
    check(diag_body_line(kDiagPutStat, kDiagNothingYet, 1, line,
                         (long)sizeof line) > 0,
          "and says what would change that");

    memset(&stats, 0, sizeof stats);
    stats.bytes = 108000;
    stats.chunks = 14;
    stats.writes = 4;
    stats.us_write = 250000;
    stats.us_total = 990000;
    stats.crc = 0x1234abcdUL;
    check(diag_putstat_rows(&stats, rows, kDiagMaxRows) == 7,
          "a real transfer renders seven rows");
    check(strcmp(rows[0].label, "Bytes") == 0, "bytes first");
    check(strcmp(rows[0].value, "108000") == 0, "the byte count");
    check(strcmp(rows[3].value, "250 ms") == 0, "FSWrite in milliseconds");
    check(strcmp(rows[6].value, "1234abcd") == 0, "the CRC, zero-padded");
    check(diag_putstat_rows(&stats, rows, 3) == 0,
          "a caller with no room gets nothing, not a truncated table");
}

static void test_card_heights(void)
{
    DiagLayout ready;
    DiagLayout with_rows;
    DiagLayout absent;
    short ready_h;
    short rows_h;
    short absent_h;
    int i;

    compute(&ready, kDiagReady, kDiagAbsent, kDiagReady, 0, 0);
    compute(&with_rows, kDiagRows, kDiagAbsent, kDiagReady, 14, 0);
    compute(&absent, kDiagAbsent, kDiagAbsent, kDiagAbsent, 0, 0);

    ready_h = (short)(ready.cards[kDiagVProbe].card.bottom
                      - ready.cards[kDiagVProbe].card.top);
    rows_h = (short)(with_rows.cards[kDiagVProbe].card.bottom
                     - with_rows.cards[kDiagVProbe].card.top);
    absent_h = (short)(absent.cards[kDiagVProbe].card.bottom
                       - absent.cards[kDiagVProbe].card.top);
    check(rows_h > ready_h, "results make a card taller");
    check(absent_h > 0, "an absent card is still a card");

    /* Cards stack in order and never overlap; content_height covers the
       last one, which is what the scroll bar's maximum is derived from. */
    for (i = 1; i < kDiagProbeCount; ++i) {
        check(with_rows.cards[i].card.top
                  >= with_rows.cards[i - 1].card.bottom,
              "cards stack without overlapping");
    }
    check(with_rows.content_height
              >= with_rows.cards[kDiagProbeCount - 1].card.bottom,
          "content height reaches the last card");
    check(with_rows.content_height > ready.content_height,
          "a page with results is taller than one without");

    /* Fourteen rows of vprobe do not fit a standard body: the page has to
       be able to say so, which is what the scroll bar is for. */
    check(with_rows.content_height
              > (short)(with_rows.canvas.bottom - with_rows.canvas.top),
          "a full vprobe result overflows the viewport");

    for (i = 0; i < kDiagProbeCount; ++i) {
        check(with_rows.cards[i].body.top >= with_rows.cards[i].cost.bottom,
              "the body sits under the cost line");
        check(with_rows.cards[i].card.right <= with_rows.canvas.right,
              "cards stay inside the canvas");
    }
    check(with_rows.scrollbar.left >= with_rows.canvas.right - 1,
          "the scroll bar is outside the canvas");
}

static void test_cost_is_stated(void)
{
    /* The three seconds vprobe costs are announced before the button is
       pressed, not explained after the screen has frozen. */
    check(strstr(diag_probe_cost(kDiagVProbe), "three seconds") != NULL,
          "vprobe's cost is on the card");
    check(diag_probe_measures(kDiagPutStat) != NULL, "putstat measures");
    check(strcmp(diag_probe_verb(kDiagVProbe), "vprobe") == 0,
          "the verb is the one a person types");
}

static void test_status_text(void)
{
    DiagCardState states[kDiagProbeCount];
    char line[120];

    states[kDiagVProbe] = kDiagReady;
    states[kDiagShotDiag] = kDiagAbsent;
    states[kDiagPutStat] = kDiagReady;
    diag_status_text(states, line, (long)sizeof line);
    check(strstr(line, "2 of 3") != NULL,
          "the placard counts what this Mac serves");

    /* A run in progress does NOT get its own placard line: the probes are
       synchronous, so nothing repaints the placard between the press and
       the answer. The card paints its own running line instead, which is
       the one a person can actually see. */
    states[kDiagVProbe] = kDiagRunning;
    diag_status_text(states, line, (long)sizeof line);
    check(strstr(line, "2 of 3") != NULL,
          "a running probe changes nothing the placard can show");
    check(diag_body_line(kDiagVProbe, kDiagRunning, 0, line,
                         (long)sizeof line) > 0,
          "the card is where a run in progress is said");
}

int main(void)
{
    printf("diag_layout_test\n");
    test_served();
    test_absent_card_has_no_control();
    test_never_run_putstat();
    test_card_heights();
    test_cost_is_stated();
    test_status_text();
    if (failures != 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
