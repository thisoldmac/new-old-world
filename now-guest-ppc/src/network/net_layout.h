#ifndef NOW_NET_LAYOUT_H
#define NOW_NET_LAYOUT_H

#include "net_facts.h"

/* Rectangle arithmetic and sentence choice for the Networking page. No
   Toolbox calls, so this compiles under the host's cc for
   now-guest-ppc/tests/net_layout_test.c - the pattern diag_layout.c set.

   FOUR SECTIONS, ORDERED BY WHAT IS CERTAIN. The order is the design:

     1. This connection   always a real measurement - NOW holds the
                          endpoint, so peer and uptime need no probe and
                          no Open Transport. The page's resting state is
                          therefore a fact rather than an empty table.
     2. TCP/IP            address, netmask, gateway, DNS, hardware
                          address, MTU. One documented call.
     3. Ports            the MACHINE'S network ports, with slots. One
                          documented walk.
     4. Connections      what we cannot list, and why. Present as a
                          section rather than omitted, because a person
                          looking for a connection list needs to find the
                          answer where they looked for the thing.

   Section 4 is the one this page exists to get right. Leaving it out
   would be honest about our capability and useless to the person; an
   empty table would be a lie. It renders one sentence that blames Open
   Transport and exonerates the Mac. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
#endif

typedef enum {
    kNetSectionLink = 0,
    kNetSectionInet,
    kNetSectionPorts,
    kNetSectionConnections,
    kNetSectionCount
} NetSection;

enum {
    kNetMargin = 12,
    kNetScrollBarWidth = 16,
    kNetSectionGap = 10,
    kNetCardInset = 10,
    kNetTitleHeight = 17,
    kNetRowHeight = 14,
    kNetLineHeight = 15,
    kNetLabelWidth = 124,
    kNetButtonWidth = 74,
    kNetButtonHeight = 20,
    /* The most rows any one section draws. Ports is the variable one and
       it is already capped at kNetMaxPorts; TCP/IP has a fixed field
       list. */
    kNetMaxRows = 12
};

typedef struct NetSectionLayout {
    Rect card;
    Rect title;
    Rect button;      /* all zero when the section has no control */
    Rect body;        /* rows or sentences draw from here down */
} NetSectionLayout;

typedef struct NetLayout {
    Rect canvas;
    Rect scrollbar;
    NetSectionLayout sections[kNetSectionCount];
    short content_height;
} NetLayout;

/* How many rows a section will draw, given the facts. Pure: the module
   asks this rather than counting as it draws, so the layout and the
   drawing cannot disagree about how tall a card is. */
short now_net_section_rows(NetSection section, const NetFacts *facts);

/* Rectangles in CONTENT coordinates - subtract the scroll offset. */
void now_net_layout_compute(const Rect *body, const NetFacts *facts,
                            NetLayout *out);

const char *now_net_section_title(NetSection section);

/* The section's own explanatory line, shown under the title. */
const char *now_net_section_blurb(NetSection section);

/* The button's word for this section in this state, or NULL when it has
   no control. A section that cannot act must not present a dead button -
   the rule the Diagnostics page established. */
const char *now_net_button_title(NetSection section, const NetFacts *facts);

/* Row `index` of a section as a label/value pair. Returns 0 when there is
   no such row. Values are already formatted; absent facts yield a value
   the caller prints verbatim rather than a blank. */
int now_net_row(NetSection section, const NetFacts *facts, short index,
                char *label, long label_cap, char *value, long value_cap);

/* The bottom placard. */
void now_net_status_text(const NetFacts *facts, char *out, long cap);

#endif /* NOW_NET_LAYOUT_H */
