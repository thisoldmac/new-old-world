#include "mcp_layout.h"

#include <stdio.h>
#include <string.h>

/* Plain field assignment throughout: SetRect is Toolbox, and this file
   also runs under the host's cc. */
static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void mcp_layout_compute(const Rect *body, McpLayout *out)
{
    short left = (short)(body->left + kMcpMargin);
    short right = (short)(body->right - kMcpMargin);
    short top = (short)(body->top + kMcpBoxTop);
    short row = (short)(top + kMcpBoxLabelHeight);
    short y;
    int i;

    for (i = 0; i < kMcpTierCount; ++i) {
        set_rect(&out->radios[i], (short)(left + kMcpRadioInset), row,
                 (short)(right - kMcpRadioInset),
                 (short)(row + kMcpRadioHeight));
        row = (short)(row + kMcpRadioPitch);
    }
    set_rect(&out->access_box, left, top, right,
             (short)(row - (kMcpRadioPitch - kMcpRadioHeight)
                     + kMcpBoxBottomPad));

    y = (short)(out->access_box.bottom + kMcpAnswerGap);
    set_rect(&out->answer_heading, left, y, right,
             (short)(y + kMcpHeadingHeight));
    y = out->answer_heading.bottom;
    for (i = 0; i < kMcpAnswerLines; ++i) {
        set_rect(&out->answer_lines[i], left, y, right,
                 (short)(y + kMcpLineHeight));
        y = (short)(y + kMcpLineHeight);
    }
}

const char *mcp_tier_token(AgentAccessTier tier)
{
    switch (tier) {
    case kAgentAccessDisabled:
        return "disabled";
    case kAgentAccessReadOnly:
        return "read-only";
    default:
        return "full";
    }
}

int mcp_tier_from_short(short value)
{
    if (value == (short)kAgentAccessDisabled
        || value == (short)kAgentAccessReadOnly
        || value == (short)kAgentAccessFull) {
        return (int)value;
    }
    return -1;
}

const char *mcp_tier_label(AgentAccessTier tier)
{
    switch (tier) {
    case kAgentAccessDisabled:
        /* First on the ladder and phrased as a decision, not as the
           absence of one: an owner who wants nothing to do with this
           should find a sentence that says so, not an empty checkbox. */
        return "No agent may drive this Mac";
    case kAgentAccessReadOnly:
        return "Read only - an agent may look, not change";
    default:
        return "Full access - an agent may act on this Mac";
    }
}

long mcp_answer_line(const McpAnswer *answer, int index, char *out,
                     long cap)
{
    out[0] = '\0';
    switch (index) {
    case 0:
        snprintf(out, (size_t)cap, "This Mac's answer is \"%s\".",
                 mcp_tier_token(answer->tier));
        break;
    case 1:
        if (!answer->connected) {
            /* The resting state, and the one this page spends most of its
               life in. It is a fact about the link, not a fault, so it
               reads as waiting rather than as failure. */
            strncpy(out, "Nothing is connected. This answer travels with "
                         "the next connection.", (size_t)cap - 1);
            out[cap - 1] = '\0';
        } else if (answer->peer[0] != '\0') {
            snprintf(out, (size_t)cap, "Connected to %.39s.", answer->peer);
        } else {
            strncpy(out, "Connected.", (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    case 2:
        if (!answer->connected) {
            break;
        }
        if (answer->sent_known && answer->sent == answer->tier) {
            /* The ordinary case now that `agent.access` revises the tier
               on the link already up. It says TOLD and stops there: no
               acknowledgement comes back, so "the host is enforcing this"
               is a claim this Mac is not in a position to make. */
            strncpy(out, "The Mac on the wire has been told.",
                    (size_t)cap - 1);
            out[cap - 1] = '\0';
        } else if (answer->sent_known) {
            /* A send that did not fit the control queue. Rare, and worth a
               line rather than a silence, because the gap between what
               this page shows and what the host is enforcing is the whole
               reason the message exists. */
            snprintf(out, (size_t)cap,
                     "The Mac on the wire was told \"%s\" and has not yet "
                     "heard this.", mcp_tier_token(answer->sent));
        } else {
            strncpy(out, "The Mac on the wire has not been told yet.",
                    (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    case 3:
        /* The counter that is not here, explained. An agent's comings and
           goings are the host's to know; a row of zeroes in their place
           would be the shape of something that failed to load. */
        strncpy(out, "Whether an agent is attached, and what it has done, "
                     "is the other Mac's to show.", (size_t)cap - 1);
        out[cap - 1] = '\0';
        break;
    default:
        break;
    }
    return (long)strlen(out);
}

void mcp_status_text(const McpAnswer *answer, char *out, long cap)
{
    if (answer->tier == kAgentAccessDisabled) {
        strncpy(out, "This Mac refuses agent control.", (size_t)cap - 1);
        out[cap - 1] = '\0';
        return;
    }
    snprintf(out, (size_t)cap, "Agent access: %s.",
             answer->tier == kAgentAccessReadOnly ? "read only"
                                                  : "full");
}
