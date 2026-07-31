#ifndef NOW_MCP_LAYOUT_H
#define NOW_MCP_LAYOUT_H

/* Rectangle arithmetic and sentence choice for the MCP page. No Toolbox
   calls live here, so the same file compiles under the host's cc for the
   native test (now-guest-ppc/tests/mcp_layout_test.c) - the pattern
   software_layout.c set.

   The page is deliberately small. The host owns the MCP server, its
   endpoint and its lifecycle; this Mac owns one fact - whether an agent
   may drive it, and how far - and the page is the control for that fact
   plus an honest account of what has been said about it. Everything a
   person might expect here and not find (who is attached, what they have
   done) is knowledge this side does not have, which is a sentence rather
   than an empty table. */

#include "agent_access.h"

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
#endif

enum {
    kMcpMargin = 14,
    kMcpBoxTop = 12,
    kMcpBoxLabelHeight = 22,  /* group-box title band, above the radios */
    kMcpRadioHeight = 18,
    kMcpRadioPitch = 21,
    kMcpRadioInset = 16,      /* box edge to a radio's left */
    kMcpBoxBottomPad = 12,
    kMcpAnswerGap = 18,       /* box bottom to the account below it */
    kMcpHeadingHeight = 16,
    kMcpLineHeight = 15,
    kMcpAnswerLines = 4,
    kMcpTierCount = 3
};

typedef struct McpLayout {
    Rect access_box;                    /* group box around the choices */
    Rect radios[kMcpTierCount];         /* disabled / read-only / full */
    Rect answer_heading;
    Rect answer_lines[kMcpAnswerLines];
} McpLayout;

void mcp_layout_compute(const Rect *body, McpLayout *out);

/* The wire token for a tier - the one `hello.agent` carries. Spelled once,
   here, because agent_access.c and this page must not be able to disagree
   about what "read only" is called on the wire. */
const char *mcp_tier_token(AgentAccessTier tier);

/* A tier read from an untrusted source (the preferences file) or -1 when
   the value is not one of the three. Absent and corrupt both mean "this
   file does not say", which is the caller's default, never a guess. */
int mcp_tier_from_short(short value);

/* The radio button's own words. Ordered least to most, so the control
   reads as a ladder and a refusal is the first thing on it rather than an
   unchecked box at the bottom. */
const char *mcp_tier_label(AgentAccessTier tier);

/* What this Mac has actually said, and to whom. `sent` is the tier the
   last hello of this launch carried; the guest sends hello once per
   connection and nothing revises it, so a tier changed since then is not
   yet anybody's understanding but this Mac's. */
typedef struct McpAnswer {
    AgentAccessTier tier;      /* what this Mac would say now */
    Boolean connected;
    Boolean sent_known;        /* a hello has gone out this launch */
    AgentAccessTier sent;      /* the tier that hello carried */
    char peer[40];             /* empty when the peer has no name yet */
} McpAnswer;

/* Fills line `index` (0..kMcpAnswerLines-1) and returns its length, or 0
   when this state has no such line - a page with nothing to report draws
   fewer lines rather than a blank one, and never a counter. */
long mcp_answer_line(const McpAnswer *answer, int index, char *out,
                     long cap);

/* The bottom placard's one line. */
void mcp_status_text(const McpAnswer *answer, char *out, long cap);

#endif /* NOW_MCP_LAYOUT_H */
