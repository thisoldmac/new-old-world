/* The Mirror page's Toolbox-free half: where its two controls sit, which
 * sentence it says about each state, and - the part worth a test - that
 * the two buttons are never both live and never lie about what pressing
 * them would do.
 *
 *     cd now-guest-ppc/tests
 *     cc -Wall -Wextra -Werror -I ../src mirror_layout_test.c \
 *        ../src/mirror/mirror_layout.c -o /tmp/t && /tmp/t
 *
 * Since 2026-08-02 it also covers the second fact this page used to
 * conflate with the first: a process EXISTING is not a process SERVING.
 * Mirror's agent learns its TCP port from a `mirror.port` file beside it,
 * and a guest whose file named a stale port had a live agent, a State row
 * saying "Running", and a host whose every connection was reset. The
 * sentences that make the port visible - and the refusal that stops
 * Enable manufacturing that state on purpose - are asserted here.
 *
 * What is NOT covered, and needs a Macintosh: that Gestalt answers for a
 * loaded extension at all, that the Process Manager reports the agent's
 * FSSpec the way mirror_probe.c matches on it, that FSpOpenDF/FSRead read
 * mirror.port out of the folder the catalog walk resolved, and that
 * LaunchApplication and the quit Apple Event reach a faceless background
 * application. Every one of those is a fact about a machine, and this
 * file has none. Nor can it see the port the RUNNING process actually
 * bound - that was read at its launch, and only a socket could answer it.
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
    strcpy(facts->agent_path, "Macintosh HD:Applications:mirror-agent");
    strcpy(facts->agent_sig, "????");
    facts->port_state = kMirrorPortNamed;
    facts->port = kMirrorAgentPort;
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
    check(strstr(value, "Running") != NULL, "running says running");

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
    now_mirror_agent_row(&facts, 2, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(label, "Program") == 0, "row 2 is the program row");
    /* THAT it is shown, not WHERE. This asserted "mirror-dev" until
       2026-08-02, which pinned a lab folder - the parent project's
       scratch directory - into a test, so the placement rule could not
       be changed without a test telling you that you had broken it. The
       rule is now "beside the application"; the row's job is to name
       wherever it looked, whatever that is. */
    check(value[0] != '\0',
          "the location is shown for a missing agent");

    facts.agent = kMirrorAgentRunning;
    now_mirror_agent_row(&facts, 3, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(label, "Signature") == 0, "row 3 is the signature row");
    check(strstr(value, "????") != NULL, "the signature is reported");
    facts.agent = kMirrorAgentStopped;
    now_mirror_agent_row(&facts, 3, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(value, "-") == 0,
          "no signature is claimed for a process that is not there");

    check(now_mirror_agent_row(&facts, kMirrorAgentRows, label,
                               (long)sizeof label, value,
                               (long)sizeof value) == 0,
          "there is no row past the last one");
}

/* RUNNING AND SERVING. Measured on a live guest 2026-08-02: the agent was
   there, this row said "Running", and it was bound to a stale port from
   the base image's own mirror.port - so every connection from a host
   Mirror was reset by a forward with nothing behind it. The row was true
   and useless. These are the sentences that make the second fact
   visible. */
static void test_state_carries_the_port(void)
{
    MirrorFacts facts;
    char label[32];
    char value[200];

    healthy(&facts);
    now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "Running") != NULL, "a served agent still runs");
    check(strstr(value, "1420") != NULL,
          "a running agent's State row names the port it was told to "
          "serve - the whole point of this row");

    /* THE MUTATION-WATCHED ONE. Running with nothing beside it naming a
       port must not read as a plain "Running": the number is a property
       of a binary nobody here can inspect, so the row has to say the
       port is unknown rather than imply the usual one. */
    facts.port_state = kMirrorPortAbsent;
    facts.port = 0;
    now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(value, "Running") != 0,
          "running with no mirror.port must not read as a bare Running");
    check(strstr(value, "mirror.port") != NULL,
          "running with no port file names the file that is missing");
    /* Was: "says the port is unknown" and "claims no port number". It is
       not unknown - read_port falls back to the compiled-in default, so
       naming that number is the accurate answer and withholding it was
       the page being vague about something it knew. */
    check(strstr(value, "1420") != NULL,
          "running with no port file names the default the agent takes");
    check(strstr(value, "default") != NULL,
          "and says the number came from the default, not from a file");

    facts.port_state = kMirrorPortUnusable;
    now_mirror_agent_row(&facts, 0, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "Running") != NULL,
          "a bad port file does not stop the process existing");
    check(strstr(value, "no usable port") != NULL,
          "a bad port file is reported as one, not as an absent file");
}

/* The Port row. It exists so the number can be compared against the port
   the host is dialling, which is the one comparison neither machine makes
   for itself. */
static void test_port_row(void)
{
    MirrorFacts facts;
    char label[32];
    char value[200];

    healthy(&facts);
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(label, "Port") == 0, "row 1 is the port row");
    check(strstr(value, "1420") != NULL, "the port row names the port");
    check(strstr(value, "mirror.port") != NULL,
          "the port row says where its number came from");

    /* A port that is not Mirror's own is the SIGNATURE of the live
       defect: every forward in this tree is wired to 1420, so a file
       naming anything else is the thing to notice. */
    facts.port = 1913;
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "1913") != NULL, "an unusual port is still named");
    check(strstr(value, "not") != NULL && strstr(value, "1420") != NULL,
          "a port that is not Mirror's own is flagged against 1420");

    facts.port_state = kMirrorPortAbsent;
    facts.port = 0;
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    /* The absence is still stated - but beside the port that absence
       PRODUCES, which is the fact somebody needs to point a mirror at
       this machine. */
    check(strstr(value, "mirror.port") != NULL,
          "an absent port file is still named as absent");
    check(strstr(value, "1420") != NULL,
          "and the port the agent will actually serve is given");

    facts.port_state = kMirrorPortUnusable;
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strstr(value, "1024") != NULL && strstr(value, "65535") != NULL,
          "an unusable port file names the range the agent will take");

    /* Nothing was looked at, so nothing is claimed. */
    facts.port_state = kMirrorPortUnknown;
    now_mirror_agent_row(&facts, 1, label, (long)sizeof label, value,
                         (long)sizeof value);
    check(strcmp(value, "-") == 0,
          "a port nobody looked for is a dash, not a guess");
}

/* THE OTHER MUTATION-WATCHED ONE. Enable must not start a process this
   page will then describe as "Running" while nothing can reach it. */
static void test_enable_refusal(void)
{
    MirrorFacts facts;
    char why[kMirrorNoteMax];

    healthy(&facts);
    facts.agent = kMirrorAgentStopped;
    check(!now_mirror_enable_refusal(&facts, why, (long)sizeof why),
          "Enable does not refuse when the port file names a port");
    check(why[0] == '\0', "a refusal that did not happen says nothing");

    /* NO PORT-BASED REFUSAL, and this block used to assert the opposite.
       It required Enable to refuse when mirror.port was missing, on the
       theory that the port would then be unknowable. Mirror's own
       read_port says otherwise: a MISSING file returns the compiled-in
       default, and a file naming anything outside 1024..65535 returns it
       too. There is no input for which the agent binds something this
       side cannot name - and kMirrorAgentPort is that number, read from
       Mirror's sources.

       So the old refusal stopped a launch that would have worked, in
       front of somebody who had just put the agent beside the
       application. The port row carries the honesty instead: it reports
       the port the agent WILL serve and whether that came from the file
       or from the default. */
    facts.port_state = kMirrorPortAbsent;
    facts.port = 0;
    check(!now_mirror_enable_refusal(&facts, why, (long)sizeof why),
          "a missing mirror.port does NOT refuse the launch - the agent "
          "takes its own default and this side knows what that is");

    facts.port_state = kMirrorPortUnusable;
    check(!now_mirror_enable_refusal(&facts, why, (long)sizeof why),
          "an unusable mirror.port does not refuse either - read_port "
          "ignores it and falls back to the same default");

    facts.port_state = kMirrorPortUnknown;
    check(!now_mirror_enable_refusal(&facts, why, (long)sizeof why),
          "an unresolved folder is not a port refusal");
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

    /* A missing port file does NOT dim Enable. The refusal is a sentence,
       and a dimmed button cannot be pressed to hear one - the page would
       know the cure and have nowhere to say it. */
    facts.agent = kMirrorAgentStopped;
    facts.port_state = kMirrorPortAbsent;
    facts.port = 0;
    check(now_mirror_can_enable(&facts),
          "Enable stays live with no port file, so its refusal can be "
          "heard");
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
    /* The placard is what a person reads without opening the page, so
       "running" alone here is the same true-and-useless sentence the
       State row was corrected for. */
    check(strstr(line, "1420") != NULL,
          "the placard carries the port a running agent was told to "
          "serve");

    facts.port_state = kMirrorPortAbsent;
    facts.port = 0;
    now_mirror_status_text(&facts, line, (long)sizeof line);
    check(strstr(line, "port unknown") != NULL,
          "the placard says so when the port is unknown");
    healthy(&facts);

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
    test_state_carries_the_port();
    test_port_row();
    test_enable_refusal();
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
