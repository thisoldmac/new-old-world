#ifndef NOW_NET_FACTS_H
#define NOW_NET_FACTS_H

/* What this Mac can say about its own networking, as a value.
   ------------------------------------------------------------------
   Toolbox-free by construction, so the same file compiles under the
   host's cc for the native test (now-guest-ppc/tests/net_facts_test.c) -
   the pattern peek_oracle.c and diag_layout.c set. The Open Transport
   calls that FILL this live in net_probe.c; everything about how a fact
   is rendered, and about what its absence means, lives here where a test
   can reach it without a Macintosh.

   The survey behind this file is docs/ot-networking-surface.md. Its
   result, in one line: Open Transport tells us a great deal about ports
   and interfaces, something about the link driver, and NOTHING about the
   machine's connection table. This header encodes that boundary as a
   type rather than as a comment, so a plane we cannot serve cannot be
   accidentally rendered as empty.

   PROVENANCE. Every constant and call cited here is P-DOC against
   Universal Interfaces 3.4 (OpenTransport.h, OpenTptInternet.h,
   OpenTransportProviders.h). Nothing here is derived from a disassembly
   or from anyone else's source, and nothing is a guess: a value we did
   not obtain is an ABSENT field, never a plausible fill. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

enum {
    kNetMaxPorts = 8,          /* ports rendered; classic Macs have 1-3 */
    kNetNameMax = 48,          /* OT port names are short */
    kNetAddrMax = 24           /* "255.255.255.255" and room to spare */
};

/* Why a fact is missing, which is a different question from what it is.
   Absence is a value here on purpose: this project's rule is that an
   unknown is an absent key rather than a zero, and a networking page is
   exactly where a zero reads as a real measurement. */
typedef enum {
    kNetFactPresent = 0,
    /* Open Transport is not there at all - CarbonLib < 1.4, or a system
       without it. The page says so once, at the top, rather than
       repeating it in every row. */
    kNetFactNoOT,
    /* OT is present and the call refused. The reason travels with it. */
    kNetFactRefused,
    /* This plane is not served by this build. Distinct from refused:
       nothing was asked, so nothing was denied. */
    kNetFactNotServed,
    /* OT has no documented call that answers this. NOT a failure, and
       the distinction is the whole point of the survey: a connection
       table is unreachable from the documented client API, and saying
       "unavailable" would imply a machine that could not answer rather
       than an API that does not ask. */
    kNetFactUndocumented
} NetFactState;

/* One network port, as OTGetIndexedPort reports it. This is the
   MACHINE'S port list rather than ours - the documented call enumerates
   what the Mac has, which is most of "networking hardware as a
   first-class thing" for the price of one loop. */
typedef struct NetPort {
    char name[kNetNameMax];        /* fPortName, e.g. "enet" */
    char device[kNetNameMax];      /* fModuleName */
    char slot[16];                 /* fSlotID - where the card physically is */
    unsigned long ref;             /* OTPortRef, opaque, for correlation */
    unsigned long capabilities;    /* fCapabilities, rendered by the module */
    Boolean active;
} NetPort;

/* The IP configuration of the default interface, from
   OTInetGetInterfaceInfo. Every field is independently absent-able
   because a machine can have an address and no gateway, or an address
   and no name server, and both are ordinary rather than broken. */
typedef struct NetInterface {
    NetFactState state;
    char address[kNetAddrMax];
    char netmask[kNetAddrMax];
    char broadcast[kNetAddrMax];
    char gateway[kNetAddrMax];     /* empty when there is none */
    char dns[kNetAddrMax];         /* empty when there is none */
    /* The hardware address and MTU come from InetInterfaceInfo's
       fHWAddr/fHWAddrLen and fIfMTU - the ORDINARY client call, not
       DLPI. The survey had these filed under a driver-facing rung; they
       are not, and that is a strictly better answer (see the correction
       in docs/ot-networking-surface.md). */
    char hw_address[kNetNameMax];  /* "00:05:02:1a:2b:3c", empty if none */
    unsigned long mtu;
    char domain[kNetNameMax];      /* fDomainName, empty when unset */
    Boolean has_gateway;
    Boolean has_dns;
    Boolean has_hw;
    Boolean has_mtu;
} NetInterface;

/* What the CONNECTION we are already on is doing. This is the one part
   of the page that needs no new API at all: NOW has a live endpoint, so
   its peer, its uptime and its counters are facts we already hold.
   Deliberately first in the UI for that reason - the page's resting
   state should be a real measurement rather than an empty table. */
typedef struct NetLink {
    NetFactState state;
    char peer[kNetAddrMax];
    unsigned long port;
    unsigned long up_ticks;        /* TickCount since the link came up */
    unsigned long bytes_in;
    unsigned long bytes_out;
    unsigned long resets;
} NetLink;

/* The whole picture, assembled by net_probe.c and rendered by the
   module. `ot` is the one state that gates everything: when OT is
   absent, no per-fact reason is worth printing. */
typedef struct NetFacts {
    NetFactState ot;
    char ot_reason[kNetNameMax];

    NetLink link;
    NetInterface inet;

    NetFactState ports_state;
    short port_count;
    NetPort ports[kNetMaxPorts];

    /* The connection table, which we cannot serve. Always
       kNetFactUndocumented on this build; carried as a field rather
       than omitted so the page can say WHY in the place a person looks
       for it, instead of leaving a hole they read as a bug. */
    NetFactState connections;
} NetFacts;

/* Zero every field to its honest absent value. A NetFacts that has not
   been probed must not read as a machine with no network. */
void now_net_facts_clear(NetFacts *out);

/* The sentence a person reads for a missing fact. Never NULL, never
   allocates, and never says "error" for kNetFactUndocumented - which is
   a statement about Open Transport rather than about this Mac. */
const char *now_net_state_sentence(NetFactState state);

/* A short lowercase token for the wire and the log. Stable: the host
   matches on these. */
const char *now_net_state_token(NetFactState state);

/* Dotted-quad an IP address into `out`. Returns the length written.
   Present here rather than in the probe because it is pure arithmetic
   and it is exactly the kind of thing that is wrong by one byte order
   on the first try. */
long now_net_format_ip(unsigned long addr, char *out, long cap);

/* Ticks to a short human duration ("3m", "2h 14m"). The link's uptime is
   the page's one continuously-changing number, so its formatting is
   pinned by test rather than eyeballed. */
void now_net_format_uptime(unsigned long ticks, char *out, long cap);

/* Colon-separated hex for a hardware address of `len` bytes. OT gives
   fHWAddrLen alongside the pointer and does NOT promise six, so the
   length is an argument rather than an assumption - a Mac with a
   non-Ethernet link is the case that would otherwise read six bytes off
   the end of a four-byte address. Writes "" when len is 0 or the buffer
   cannot hold the result. */
void now_net_format_hw(const unsigned char *addr, long len,
                       char *out, long cap);

#endif /* NOW_NET_FACTS_H */
