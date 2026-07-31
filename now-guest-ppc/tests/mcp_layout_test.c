/* The MCP page's Toolbox-free half: where its controls sit, and which
 * sentence it says about what this Mac has told the other one.
 *
 *     cd now-guest-ppc/tests
 *     cc -Wall -Wextra -Werror -I ../src mcp_layout_test.c \
 *        ../src/mcp/mcp_layout.c -o /tmp/t && /tmp/t
 *
 * What is NOT covered: the controls themselves, and the fact that
 * agent_access.c reads and writes the same tier this page shows. That
 * seam is one function on each side and needs a Mac.
 */

#include <stdio.h>
#include <string.h>

#include "mcp_layout.h"

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

static void test_layout_order(void)
{
    McpLayout lay;
    Rect body;
    int i;

    body_rect(&body);
    mcp_layout_compute(&body, &lay);

    check(lay.access_box.left > body.left, "box inset from the body");
    check(lay.access_box.right < body.right, "box inset on the right");
    for (i = 0; i < kMcpTierCount; ++i) {
        check(lay.radios[i].left > lay.access_box.left,
              "radio inset inside the box");
        check(lay.radios[i].right <= lay.access_box.right,
              "radio inside the box on the right");
        check(lay.radios[i].top >= lay.access_box.top,
              "radio below the box top");
        check(lay.radios[i].bottom <= lay.access_box.bottom,
              "radio above the box bottom");
    }
    /* The ladder reads top to bottom in tier order, refusal first. */
    check(lay.radios[0].top < lay.radios[1].top, "disabled above read-only");
    check(lay.radios[1].top < lay.radios[2].top, "read-only above full");
    check(lay.radios[0].bottom <= lay.radios[1].top, "radios do not overlap");

    check(lay.answer_heading.top >= lay.access_box.bottom,
          "the account sits below the box");
    for (i = 0; i < kMcpAnswerLines; ++i) {
        check(lay.answer_lines[i].top >= lay.answer_heading.bottom,
              "account lines below their heading");
        check(lay.answer_lines[i].bottom <= body.bottom,
              "account lines inside the body");
        if (i > 0) {
            check(lay.answer_lines[i].top >= lay.answer_lines[i - 1].bottom,
                  "account lines do not overlap");
        }
    }
}

static void test_tokens(void)
{
    check(strcmp(mcp_tier_token(kAgentAccessDisabled), "disabled") == 0,
          "disabled token");
    check(strcmp(mcp_tier_token(kAgentAccessReadOnly), "read-only") == 0,
          "read-only token");
    check(strcmp(mcp_tier_token(kAgentAccessFull), "full") == 0,
          "full token");

    check(mcp_tier_from_short(0) == 0, "0 is disabled");
    check(mcp_tier_from_short(2) == 2, "2 is full");
    /* An unreadable answer is not consent and not a refusal - it is the
       caller's default, which is why this reports rather than guesses. */
    check(mcp_tier_from_short(3) == -1, "3 is not a tier");
    check(mcp_tier_from_short(-1) == -1, "-1 is not a tier");
    check(mcp_tier_from_short(9999) == -1, "9999 is not a tier");

    check(mcp_tier_label(kAgentAccessDisabled) != NULL, "disabled label");
    check(strcmp(mcp_tier_label(kAgentAccessDisabled),
                 mcp_tier_label(kAgentAccessFull)) != 0,
          "the ends of the ladder read differently");
}

static void test_resting_state(void)
{
    McpAnswer answer;
    char line[160];

    memset(&answer, 0, sizeof answer);
    answer.tier = kAgentAccessFull;
    answer.connected = 0;

    check(mcp_answer_line(&answer, 0, line, (long)sizeof line) > 0,
          "line 0 always says what this Mac would say");
    check(strstr(line, "full") != NULL, "line 0 carries the wire token");

    check(mcp_answer_line(&answer, 1, line, (long)sizeof line) > 0,
          "line 1 speaks when nothing is connected");
    /* The resting state on nearly every machine. It has to read as
       waiting, so it says what happens next rather than what is absent. */
    check(strstr(line, "next connection") != NULL,
          "the resting line points forward");

    /* No live link, so nothing has been misinformed and there is no
       third line - a blank one would be a counter with no number. */
    check(mcp_answer_line(&answer, 2, line, (long)sizeof line) == 0,
          "no stale-answer line without a link");

    check(mcp_answer_line(&answer, 3, line, (long)sizeof line) > 0,
          "the page says what it cannot know");
    check(strstr(line, "other Mac") != NULL,
          "and names who does know it");
}

static void test_pending_change(void)
{
    McpAnswer answer;
    char line[160];

    memset(&answer, 0, sizeof answer);
    answer.tier = kAgentAccessDisabled;
    answer.connected = 1;
    answer.sent_known = 1;
    answer.sent = kAgentAccessFull;
    strcpy(answer.peer, "Ada");

    check(mcp_answer_line(&answer, 1, line, (long)sizeof line) > 0,
          "a connected page names the peer");
    check(strstr(line, "Ada") != NULL, "the peer's name is the peer's");

    /* The stale case, which `agent.access` now makes rare rather than
       routine: the announcement did not fit the control queue, so what the
       host is enforcing and what this page shows have parted company. That
       gap is the whole reason the message exists, so it gets a line. */
    check(mcp_answer_line(&answer, 2, line, (long)sizeof line) > 0,
          "a tier the wire has not carried is reported");
    check(strstr(line, "full") != NULL,
          "and says what the other Mac still believes");

    /* Up to date, and it SAYS so. This reverses the older page, where
       agreement showed no line at all on the grounds that it was a counter
       of zero. That reading held while the switch could not take effect
       until the next connection - the person had nothing to be reassured
       about. Now that it does take effect, the affirmative sentence is the
       reassurance this whole change exists to deliver, and its absence
       would read as "nothing happened". */
    answer.sent = kAgentAccessDisabled;
    check(mcp_answer_line(&answer, 2, line, (long)sizeof line) > 0,
          "agreement is stated, not left to silence");
    check(strstr(line, "told") != NULL,
          "and it claims only that the host was TOLD");
    /* Deliberately absent: nothing acknowledges `agent.access`, so this Mac
       cannot say the host is enforcing it. Claiming so would be the same
       class of false comfort the message was added to remove. */
    check(strstr(line, "enforc") == NULL,
          "never a claim about what the host then did");

    /* Connected, but the wire reports having told this link nothing. The
       page must not fill that in from the tier it can see. */
    answer.sent_known = 0;
    answer.sent = kAgentAccessFull;
    check(mcp_answer_line(&answer, 2, line, (long)sizeof line) > 0,
          "an untold link says so");
    check(strstr(line, "not been told") != NULL,
          "and does not pass silence off as agreement");
}

static void test_status_text(void)
{
    McpAnswer answer;
    char line[120];

    memset(&answer, 0, sizeof answer);
    answer.tier = kAgentAccessDisabled;
    mcp_status_text(&answer, line, (long)sizeof line);
    check(strstr(line, "refuses") != NULL, "a refusal says so plainly");

    answer.tier = kAgentAccessReadOnly;
    mcp_status_text(&answer, line, (long)sizeof line);
    check(strstr(line, "read only") != NULL, "read only in the placard");

    answer.tier = kAgentAccessFull;
    mcp_status_text(&answer, line, (long)sizeof line);
    check(strstr(line, "full") != NULL, "full access in the placard");
}

int main(void)
{
    printf("mcp_layout_test\n");
    test_layout_order();
    test_tokens();
    test_resting_state();
    test_pending_change();
    test_status_text();
    if (failures != 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
