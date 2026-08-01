/* The Mirror page's Toolbox-free half: where its two controls sit, which
 * sentence it says about each state, and - the part worth a test - that
 * the two buttons are never both live and never lie about what pressing
 * them would do.
 *
 *     cd now-guest-ppc/tests
 *     cc -Wall -Wextra -Werror -I ../src mirror_layout_test.c \
 *        ../src/mirror/mirror_layout.c -o /tmp/t && /tmp/t
 *
 * What is NOT covered, and needs a Macintosh: that Gestalt answers for a
 * loaded extension at all, that the Process Manager reports the agent's
 * FSSpec the way mirror_probe.c matches on it, and that
 * LaunchApplication and the quit Apple Event reach a faceless background
 * application. Every one of those is a fact about a machine, and this
 * file has none.
 */

#include <stdio.h>
#include <string.h>

#include "mirror_layout.h"

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

/* A machine with everything Mirror needs, as a starting point that each
   test then breaks in one specific way. */
static void healthy(MirrorFacts *facts)
{
    int i;

    memset(facts, 0, sizeof *facts);
    for (i = 0; i < kMirrorExtCount; ++i) {
        facts->ext_state[i] = kMirrorExtResident;
    }
    facts->ext_version[kMirrorExtAX] = 4;
    facts->ext_version[kMirrorExtQD] = 1;
    facts->ext_version[kMirrorExtPortal] = 4;
    facts->agent = kMirrorAgentRunning;
    strcpy(facts->agent_path, "Macintosh HD:TimBotTu:mirror-dev:mirror-agent");
    strcpy(facts->agent_sig, "????");
}

static void test_layout_order(void)
{
    MirrorLayout lay;
    Rect body;
    int i;

    body_rect(&body);
    now_mirror_layout_compute(&body, &lay);

    check(lay.ext_heading.left > body.left, "heading inset from the body");
    check(lay.ext_heading.right < body.right, "heading inset on the right");

    /* Reading order, top to bottom, nothing overlapping. Click and draw
       read these same numbers, so an overlap is two rows fighting over
       one strip of pixels. */
    check(lay.ext_heading.bottom <= lay.ext_rows[0].top,
          "heading above the first extension row");
    for (i = 1; i < kMirrorExtCount; ++i) {
        check(lay.ext_rows[i - 1].bottom <= lay.ext_rows[i].top,
              "extension rows do not overlap");
    }
    check(lay.ext_rows[kMirrorExtCount - 1].bottom <= lay.ext_note[0].top,
          "the why-no-switch note sits under the rows it explains");
    check(lay.ext_note[0].bottom <= lay.ext_note[1].top,
          "note lines do not overlap");
    check(lay.ext_note[kMirrorExtNoteLines - 1].bottom
              <= lay.agent_heading.top,
          "the agent half starts below the extension half");
    for (i = 1; i < kMirrorAgentRows; ++i) {
        check(lay.agent_rows[i - 1].bottom <= lay.agent_rows[i].top,
              "agent rows do not overlap");
    }
    check(lay.agent_rows[kMirrorAgentRows - 1].bottom <= lay.enable.top,
          "the buttons sit under the rows they act on");

    /* Two real push buttons, side by side, at Control Manager metrics -
       the layout gives them a size rather than stretching them. */
    check(lay.enable.right - lay.enable.left == kMirrorButtonWidth,
          "Enable is a push button's width");
    check(lay.enable.bottom - lay.enable.top == kMirrorButtonHeight,
          "Enable is a push button's height");
    check(lay.disable.left >= lay.enable.right, "Disable is right of Enable");
    check(lay.enable.top == lay.disable.top, "the buttons share a baseline");
    check(lay.enable.bottom <= lay.note[0].top,
          "the outcome note is below the buttons that cause it");
    check(lay.note[kMirrorNoteLines - 1].bottom <= body.bottom,
          "the whole page fits a standard window");
}

/* The narrowest window the Workshop allows. A page that only fits the
   standard size is a page that breaks on a 640x480 screen. */
static void test_layout_at_minimum(void)
{
    MirrorLayout lay;
    Rect body;

    body.left = 128;
    body.top = 38;
    body.right = 620;
    body.bottom = 407;
    now_mirror_layout_compute(&body, &lay);

    check(lay.note[kMirrorNoteLines - 1].bottom <= body.bottom,
          "the page still fits the minimum window");
    check(lay.disable.right < body.right,
          "both buttons stay inside a narrow pane");
    check(lay.ext_rows[0].right > lay.ext_rows[0].left + kMirrorLabelWidth,
          "the value column survives a narrow pane");
}

static void test_extension_states(void)
{
    MirrorFacts facts;
    char line[200];

    healthy(&facts);
    now_mirror_ext_value(&facts, kMirrorExtAX, line, (long)sizeof line);
    check(strstr(line, "Resident") != NULL, "resident says resident");
    check(strstr(line, "4") != NULL, "resident names the version");

    /* Loaded, and not a version this build knows. It must NOT read as
       absent: sending someone to reinstall a file that is already there
       is the whole reason this state exists. */
    facts.ext_state[kMirrorExtQD] = kMirrorExtOtherVersion;
    facts.ext_version[kMirrorExtQD] = 9;
    now_mirror_ext_value(&facts, kMirrorExtQD, line, (long)sizeof line);
    check(strstr(line, "Resident") != NULL,
          "an unknown version is still resident");
    check(strstr(line, "9") != NULL, "an unknown version is named");
    check(strstr(line, "Not loaded") == NULL,
          "an unknown version does not read as absent");

    facts.ext_state[kMirrorExtPortal] = kMirrorExtAbsent;
    facts.ext_version[kMirrorExtPortal] = 0;
    now_mirror_ext_value(&facts, kMirrorExtPortal, line, (long)sizeof line);
    check(strstr(line, "Not loaded") != NULL, "absent says not loaded");
    check(strstr(line, "version") == NULL,
          "an absent extension claims no version");
    check(strstr(line, "clicks") != NULL,
          "an absent row still says what stopped working");
}

/* The two lines are the page's argument, so they are asserted rather than
   left to whoever edits them next. */
static void test_extension_note(void)
{
    check(strstr(now_mirror_ext_note(0), "startup") != NULL,
          "the note says an extension loads at startup");
    check(strstr(now_mirror_ext_note(1), "restart") != NULL,
          "the note names the restart");
    check(strstr(now_mirror_ext_note(1), "switch") != NULL,
          "the note forecloses the switch the rows suggest");
    check(now_mirror_ext_note(kMirrorExtNoteLines)[0] == '\0',
          "there is no third line");
}

static void test_agent_rows(void)
{
    MirrorFacts facts;
    char label[32];
    char value[200];

    healthy(&facts);
    check(now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                               (long)sizeof value),
          "there is a state row");
    check(strcmp(value, "Running") == 0, "running says running");

    facts.agent = kMirrorAgentStopped;
    now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(value, "Not running") == 0, "stopped says not running");

    /* Not installed and not running want different things done about
       them, so they must not share a sentence. */
    facts.agent = kMirrorAgentNoFile;
    now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "Not installed") != NULL,
          "a missing agent says not installed");

    /* Where we looked is shown even when nothing was there. */
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "mirror-dev") != NULL,
          "the location is shown for a missing agent");

    facts.agent = kMirrorAgentRunning;
    now_mirror_agent_row(&facts, 2, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "????") != NULL, "the signature is reported");
    facts.agent = kMirrorAgentStopped;
    now_mirror_agent_row(&facts, 2, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(value, "-") == 0,
          "no signature is claimed for a process that is not there");

    check(now_mirror_agent_row(&facts, kMirrorAgentRows, label,
                               (long)sizeof label, value,
                               (long)sizeof value) == 0,
          "there is no row past the last one");
}

/* The heart of it. A button that offers to do what cannot be done, or
   refuses what can, is the failure this page was written to avoid. */
static void test_buttons_match_reality(void)
{
    MirrorFacts facts;

    healthy(&facts);
    check(!now_mirror_can_enable(&facts),
          "Enable is dead while the agent runs");
    check(now_mirror_can_disable(&facts),
          "Disable is live while the agent runs");

    facts.agent = kMirrorAgentStopped;
    check(now_mirror_can_enable(&facts),
          "Enable is live when the agent is stopped");
    check(!now_mirror_can_disable(&facts),
          "Disable is dead when the agent is stopped");

    /* Nothing to launch: Enable would fail, so it does not offer. */
    facts.agent = kMirrorAgentNoFile;
    check(!now_mirror_can_enable(&facts),
          "Enable is dead when there is no agent to launch");
    check(!now_mirror_can_disable(&facts),
          "Disable is dead when there is no agent at all");
}

static void test_note_wrapping(void)
{
    MirrorFacts facts;
    char first[200];
    char second[200];

    healthy(&facts);
    check(now_mirror_note_line(&facts, 0, first, (long)sizeof first) == 0,
          "no note before anything has happened");

    strcpy(facts.note, "Started the Mirror agent.");
    check(now_mirror_note_line(&facts, 0, first, (long)sizeof first) > 0,
          "a short note lands on the first line");
    check(strcmp(first, "Started the Mirror agent.") == 0,
          "a short note is not broken up");
    check(now_mirror_note_line(&facts, 1, second, (long)sizeof second) == 0,
          "a short note leaves the second line empty");

    /* One of the real ones, and among the longest the probe emits. */
    strcpy(facts.note,
           "The Mac accepted the launch, but no such process is running. "
           "The agent quit at once, or it is not the application it "
           "appears to be.");
    now_mirror_note_line(&facts, 0, first, (long)sizeof first);
    now_mirror_note_line(&facts, 1, second, (long)sizeof second);
    check(strlen(first) > 0 && strlen(second) > 0,
          "a long note uses both lines");
    /* Broken at a space, not mid-word, and nothing lost across the seam. */
    check(first[strlen(first) - 1] != ' ', "no trailing space on line one");
    check(second[0] != ' ', "no leading space on line two");
    check(strncmp(facts.note, first, strlen(first)) == 0,
          "line one is the head of the note");
    check(strstr(facts.note, second) != NULL,
          "line two is the tail of the note");

    /* The buffer must not be able to hold more than the page can say. A
       failure message whose last clause fell off between the note and the
       screen would be a silence exactly where this page must speak, so
       the check is that the LAST line ends where the note ends. */
    {
        char full[kMirrorNoteMax];
        char last[kMirrorNoteMax];
        char line[kMirrorNoteMax];
        size_t tail;
        int i;

        memset(full, 'x', sizeof full - 1);
        full[sizeof full - 1] = '\0';
        for (i = 8; i < (int)(sizeof full - 1); i += 8) {
            full[i] = ' ';            /* breakable, so wrapping applies */
        }
        strcpy(facts.note, full);
        last[0] = '\0';
        for (i = 0; i < kMirrorNoteLines; ++i) {
            if (now_mirror_note_line(&facts, i, line, (long)sizeof line)
                > 0) {
                strcpy(last, line);
            }
        }
        tail = strlen(facts.note) - strlen(last);
        check(last[0] != '\0' && strlen(last) <= strlen(facts.note)
                  && strcmp(facts.note + tail, last) == 0,
              "a note that fills its buffer loses nothing off the end");
    }
}

static void test_status_text(void)
{
    MirrorFacts facts;
    char line[160];

    healthy(&facts);
    now_mirror_status_text(&facts, line, (long)sizeof line);
    check(strstr(line, "running") != NULL, "the placard reports the agent");
    check(strstr(line, "3 of 3") != NULL, "the placard counts extensions");

    /* Both halves, always: the agent answers Mirror's wire, the
       extensions are what it has to answer with, and either alone reads
       as a working Mirror when it is not. */
    facts.agent = kMirrorAgentStopped;
    facts.ext_state[kMirrorExtQD] = kMirrorExtAbsent;
    now_mirror_status_text(&facts, line, (long)sizeof line);
    check(strstr(line, "not running") != NULL,
          "the placard reports a stopped agent");
    check(strstr(line, "2 of 3") != NULL,
          "the placard counts what is actually loaded");

    /* An extension of an unknown version is LOADED. Counting it as absent
       would make a version mismatch look like a missing file. */
    facts.ext_state[kMirrorExtQD] = kMirrorExtOtherVersion;
    now_mirror_status_text(&facts, line, (long)sizeof line);
    check(strstr(line, "3 of 3") != NULL,
          "an unknown version counts as loaded");

    facts.agent = kMirrorAgentNoFile;
    now_mirror_status_text(&facts, line, (long)sizeof line);
    check(strstr(line, "not installed") != NULL,
          "the placard tells missing from stopped");
}

int main(void)
{
    printf("mirror_layout_test\n");
    test_layout_order();
    test_layout_at_minimum();
    test_extension_states();
    test_extension_note();
    test_agent_rows();
    test_buttons_match_reality();
    test_note_wrapping();
    test_status_text();
    if (failures != 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
